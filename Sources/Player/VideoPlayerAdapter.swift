import SwiftUI
import AVFoundation
import Combine
import KSPlayer

/// 播放引擎适配层。
///
/// 设计约束（不可放宽）：
/// - **只有一个内核**：KSMEPlayer（FFmpeg）。不保留 AVFoundation 运行路径，
///   因为它无法处理自签名证书，留着的唯一结果就是一条注定失败的隐式回退。
/// - **不代理**：交给 FFmpeg 的永远是原始 URL，字节不经过任何中间层。
/// - **不回退**：任一环节失败即 `.failed(message)`，message 为底层原始错误。
@MainActor
public final class VideoPlayerController: ObservableObject {
    // MARK: 对外状态

    @Published public private(set) var phase: PlaybackPhase = .idle
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentPositionMs: Int64 = 0
    @Published public private(set) var durationMs: Int64 = 0
    @Published public private(set) var bufferedPositionMs: Int64 = 0
    @Published public var playbackSpeed: Double = 1.0
    @Published public var isAspectFill: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var subtitleText: String?
    @Published public private(set) var volume: Double = 1.0

    /// 交给 SwiftUI 的渲染图层参数。
    @Published public private(set) var ksOptions: KSOptions?
    @Published public private(set) var playbackURL: URL?

    public var onPlaybackEnded: (() -> Void)?

    public var isReady: Bool { phase == .ready }

    // MARK: 内部

    public let ksCoordinator = KSVideoPlayer.Coordinator()

    private var selectedSubtitleFileURL: URL?
    private var setupResumeMs: Int64 = 0
    private var pipStateCancellable: AnyCancellable?
    private weak var boundPiPLayer: KSPlayerLayer?

    private var connectTimeoutTask: Task<Void, Never>?
    /// 证书问题的可操作提示。失败时附加到 FFmpeg 的原始错误后面，
    /// 避免只看到一个无从下手的 "avformat can't open input"。
    private var trustHint: String?
    /// 诊断节流：上次记录过的播放秒数。
    private var lastDiagnosticSecond: Int64 = -1

    private static let connectTimeoutSeconds: UInt64 = 20

    public init() {}

    /// 由上层在进入引擎之前就发现的问题（例如服务端返回的 URL 无法解析）上报。
    /// 与其它失败一样，走同一条 `.failed` 通道，不另设标志位。
    public func reportUnplayableSource(_ reason: String) {
        resetState()
        fail(reason)
    }

    // MARK: - 装载

    /// 建立证书固定关系、组装选项、创建图层。整个过程是确定的单行道。
    public func load(_ request: PlaybackRequest) async {
        D.log("engine", "load \(request.url.absoluteString.prefix(110)) resumeMs=\(request.resumeMs) cacheMb=\(request.cacheLimitMb)")

        resetState()
        phase = .resolving

        // 1. 证书固定（仅 https）
        trustHint = nil
        if request.url.scheme?.lowercased() == "https" {
            let host = request.url.host ?? ""
            let hostKey = TLSTrustStore.hostKey(host: host, port: request.url.port)
            phase = .pinning(hostKey: hostKey)
            do {
                let pin = try await SecurityPolicy.ensurePinned(for: request.url)
                if let pin, pin.chainUsable == false {
                    trustHint = "服务器证书未绑定该地址（缺少 subjectAltName），"
                        + "无法进行证书链校验。请为证书添加 SAN=IP:\(host) 或改用域名后重新连接。"
                }
            } catch {
                fail(error.localizedDescription)
                return
            }
        }

        // 2. 选项
        let options: KSOptions
        do {
            options = try MediaTransport.makeOptions(for: request)
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard !Task.isCancelled else { return }

        // 3. 重建图层
        if let oldLayer = ksCoordinator.playerLayer, oldLayer.isPipActive {
            oldLayer.isPipActive = false
        }
        pipStateCancellable?.cancel()
        pipStateCancellable = nil
        boundPiPLayer = nil
        ksOptions = nil
        ksCoordinator.resetPlayer()

        setupResumeMs = request.resumeMs
        playbackURL = request.url
        installKSPlayerCallbacks()
        ksOptions = options

        phase = .connecting
        lastDiagnosticSecond = -1
        startConnectTimeout()

        reapplySelectedSubtitle()
    }

    // MARK: - 播放控制

    public func play() {
        ksCoordinator.playerLayer?.play()
        isPlaying = true
    }

    public func pause() {
        ksCoordinator.playerLayer?.pause()
        isPlaying = false
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func seek(toMs: Int64) {
        let upper = durationMs > 0 ? durationMs : toMs
        let target = max(0, min(toMs, upper))
        currentPositionMs = target
        ksCoordinator.seek(time: TimeInterval(target) / 1000.0)
    }

    public func skip(seconds: Int64) {
        let upper = durationMs > 0 ? durationMs : Int64.max
        seek(toMs: max(0, min(upper, currentPositionMs + seconds * 1000)))
    }

    public func setSpeed(_ speed: Double) {
        playbackSpeed = speed
        ksCoordinator.playbackRate = Float(speed)
    }

    public func toggleAspect() {
        isAspectFill.toggle()
        ksCoordinator.isScaleAspectFill = isAspectFill
    }

    public func setVolume(_ value: Double) {
        let clamped = max(0, min(1, value))
        volume = clamped
        ksCoordinator.playerLayer?.player.playbackVolume = Float(clamped)
    }

    // MARK: - 画中画

    public var isPiPAvailable: Bool {
        ksCoordinator.playerLayer?.player.pipController != nil
    }

    @discardableResult
    public func togglePiP() -> Bool {
        guard let layer = ksCoordinator.playerLayer, layer.player.pipController != nil else {
            return false
        }
        layer.isPipActive.toggle()
        isPiPActive = layer.isPipActive
        return layer.isPipActive
    }

    // MARK: - 字幕

    public func loadSubtitle(_ subtitle: SubtitleEntry, serverUrl: String) async throws {
        let data = try await PlayApi.shared.fetchSubtitleData(
            serverUrl: serverUrl,
            subtitlePath: subtitle.url
        )
        try Task.checkCancellation()
        guard !data.isEmpty else {
            throw PlayApiError.badResponse(statusCode: 0, message: "字幕文件为空")
        }

        let ext = (subtitle.format?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0.lowercased()
        } ?? "srt"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("strmaction-subtitle-\(UUID().uuidString).\(ext)")
        try data.write(to: fileURL, options: .atomic)

        if let oldURL = selectedSubtitleFileURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        selectedSubtitleFileURL = fileURL
        ksCoordinator.subtitleModel.selectedSubtitleInfo = URLSubtitleInfo(url: fileURL)
        D.log("engine", "字幕已加载 \(subtitle.label)")
    }

    public func clearSubtitle() {
        ksCoordinator.subtitleModel.selectedSubtitleInfo = nil
        if let oldURL = selectedSubtitleFileURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        selectedSubtitleFileURL = nil
        subtitleText = nil
    }

    private func reapplySelectedSubtitle() {
        guard let fileURL = selectedSubtitleFileURL else { return }
        ksCoordinator.subtitleModel.selectedSubtitleInfo = URLSubtitleInfo(url: fileURL)
    }

    // MARK: - 回调

    /// 图层创建/重建后必须重新安装回调。由 `KSPlayerSurfaceView.updateUIView` 调用。
    public func installKSPlayerCallbacks() {
        ksCoordinator.onStateChanged = { [weak self] layer, state in
            let layerURL = layer.url.absoluteString
            DispatchQueue.main.async {
                guard let self else { return }
                let isCurrent = self.ksCoordinator.playerLayer === layer
                D.log("state", "\(state) 是当前图层=\(isCurrent) url=\(layerURL.prefix(50))")
                guard isCurrent else { return }

                if state == .readyToPlay {
                    self.enterReady()
                } else if state == .error {
                    self.fail("播放器进入错误状态")
                }
            }
        }

        ksCoordinator.onPlay = { [weak self] current, total in
            DispatchQueue.main.async {
                guard let self, self.ksCoordinator.playerLayer != nil else { return }

                let second = Int64(current)
                if self.lastDiagnosticSecond < 0 || (second % 3 == 0 && second != self.lastDiagnosticSecond) {
                    self.lastDiagnosticSecond = second
                    D.log("play", String(format: "pos=%.2f total=%.2f", current, total))
                }

                self.currentPositionMs = Int64(current * 1000)
                if total > 0 {
                    self.durationMs = Int64(total * 1000)
                }
                self.isPlaying = self.ksCoordinator.state.isPlaying

                // 有数据在动即脱离「连接中」。不在这里直接判 ready，
                // 以免把「刚拿到首包」误当成「已经可播」。
                if self.phase == .connecting || self.phase == .buffering {
                    self.phase = total > 0 ? .ready : .buffering
                }

                let subtitle = self.ksCoordinator.subtitleModel.parts
                    .compactMap { $0.text?.string }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                self.subtitleText = subtitle.isEmpty ? nil : subtitle
            }
        }

        ksCoordinator.onBufferChanged = { [weak self] _, buffered in
            DispatchQueue.main.async {
                guard let self, self.ksCoordinator.playerLayer != nil else { return }
                self.bufferedPositionMs = Int64(buffered * 1000)
            }
        }

        ksCoordinator.onFinish = { [weak self] layer, error in
            let reason = error?.localizedDescription
            // KSPlayer 会把 avformat 的错误码塞进 NSError，这里把细节打出来，
            // 否则永远只能看到 "avformat can't open input" 这种无从下手的信息。
            var detail = ""
            if let nsError = error.map({ $0 as NSError }) {
                detail = " domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let isCurrent = self.ksCoordinator.playerLayer === layer
                D.log("finish", "\(reason ?? "正常结束")\(detail) 是当前图层=\(isCurrent)")
                guard isCurrent else { return }

                self.isPlaying = false
                if let reason {
                    self.fail(reason)
                } else {
                    self.phase = .ready
                    self.onPlaybackEnded?()
                }
            }
        }
    }

    public func bindPiPState(for layer: KSPlayerLayer) {
        guard boundPiPLayer !== layer else { return }
        boundPiPLayer = layer
        pipStateCancellable = layer.$isPipActive
            .sink { [weak self] active in
                DispatchQueue.main.async {
                    self?.isPiPActive = active
                }
            }
    }

    // MARK: - 状态转移

    private func enterReady() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil

        isPlaying = true
        ksCoordinator.playbackRate = Float(playbackSpeed)
        ksCoordinator.isScaleAspectFill = isAspectFill
        ksCoordinator.playerLayer?.player.playbackVolume = Float(volume)
        reapplySelectedSubtitle()

        phase = .ready

        if setupResumeMs > 0 {
            let resume = setupResumeMs
            setupResumeMs = 0
            ksCoordinator.seek(time: TimeInterval(resume) / 1000.0)
        } else {
            play()
        }
    }

    private func fail(_ reason: String) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil

        // 若已知是证书绑定不了地址，把可操作提示接在原始错误后面。
        var message = reason
        if let trustHint, !reason.contains("subjectAltName") {
            message = reason + "\n\n" + trustHint
        }

        D.log("engine", "失败: \(message)")
        errorMessage = message
        isPlaying = false
        phase = .failed(message)
    }

    /// 连接阶段超时。只在 `.connecting` 阶段计时；一旦有数据在动就取消，
    /// 因为慢速源上「缓冲得慢」是正常状态，不该被判为失败。
    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.phase == .connecting else { return }
            self.fail("连接媒体源超时（\(Self.connectTimeoutSeconds) 秒无响应）")
        }
    }

    // MARK: - 生命周期

    private func resetState() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        trustHint = nil
        isPlaying = false
        currentPositionMs = 0
        durationMs = 0
        bufferedPositionMs = 0
        isPiPActive = false
        subtitleText = nil
        errorMessage = nil
        lastDiagnosticSecond = -1
    }

    /// 释放播放器。调用后 `phase` 回到 `.idle`。
    public func destroy() {
        D.log("engine", "destroy")
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        resetState()

        if let layer = ksCoordinator.playerLayer, layer.isPipActive {
            layer.isPipActive = false
        }
        ksOptions = nil
        setupResumeMs = 0
        pipStateCancellable?.cancel()
        pipStateCancellable = nil
        boundPiPLayer = nil
        ksCoordinator.resetPlayer()

        if let oldURL = selectedSubtitleFileURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        selectedSubtitleFileURL = nil
        playbackURL = nil
        phase = .idle
    }
}

// MARK: - 渲染图层

public struct VideoSurfaceView: View {
    @ObservedObject public var controller: VideoPlayerController
    public let url: URL
    public let resumeMs: Int64

    public init(controller: VideoPlayerController, url: URL, resumeMs: Int64) {
        self.controller = controller
        self.url = url
        self.resumeMs = resumeMs
    }

    public var body: some View {
        if let options = controller.ksOptions {
            KSPlayerSurfaceView(
                controller: controller,
                url: controller.playbackURL ?? url,
                options: options
            )
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// 直接承载 `KSPlayerLayer` 的渲染 view。
///
/// 不用官方 `KSVideoPlayer`：它在 URL 不变时无法重建播放器，
/// 而切换剧集与重新装载都需要重建图层。
struct KSPlayerSurfaceView: UIViewRepresentable {
    @ObservedObject var controller: VideoPlayerController
    let url: URL
    let options: KSOptions

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // 仅在 URL 变化或图层为空时创建，避免反复重置 subtitleModel。
        let currentURL = controller.ksCoordinator.playerLayer?.url.absoluteString
        let needsCreate = currentURL != url.absoluteString

        if needsCreate {
            _ = controller.ksCoordinator.makeView(url: url, options: options)
        }

        // 回调必须在拿到图层后立刻安装，不能等 player.view 就绪——
        // 渲染视图是异步创建的，若在早退分支跳过安装，且此后没有状态变更
        // 触发第二次 updateUIView，回调就永远挂不上。
        controller.installKSPlayerCallbacks()
        if let layer = controller.ksCoordinator.playerLayer {
            controller.bindPiPState(for: layer)
        }

        guard let playerView = controller.ksCoordinator.playerLayer?.player.view else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        if playerView.superview !== container {
            for subview in container.subviews where subview !== playerView {
                subview.removeFromSuperview()
            }
            playerView.removeFromSuperview()
            playerView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(playerView)
            NSLayoutConstraint.activate([
                playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                playerView.topAnchor.constraint(equalTo: container.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            for subview in container.subviews where subview !== playerView {
                subview.removeFromSuperview()
            }
        }
    }
}
