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
    /// 缓冲上限（MB），用户设置项。
    @Published public private(set) var bufferLimitMb: Int = PlaybackBufferPreference.defaultLimitMb
    /// 按码率折算出的实际目标时长（秒）。面板里的读数用它。
    @Published public private(set) var bufferTargetSeconds: Double = PlaybackBufferPreference.secondsForCurrentLimit()
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
    /// 当前会话的选项实例。`KSOptions` 是引用类型，
    /// ready 之后改 `maxBufferDuration` 会立刻被 `codecDidChangeCapacity` 读到。
    private var activeOptions: KSOptions?
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
        D.log("engine", "load \(request.url.absoluteString.prefix(110)) resumeMs=\(request.resumeMs) buffer=\(Int(request.bufferTargetSeconds))s")

        resetState()
        phase = .resolving

        // 1. 证书信任校验（仅 https）
        //
        //    这里刻意提前失败：链校验不过就直接给出原因，
        //    而不是把问题丢给 FFmpeg，让它在 100ms 后吐一句
        //    "avformat can't open input"。
        if request.url.scheme?.lowercased() == "https" {
            let host = request.url.host ?? ""
            let hostKey = TLSTrustStore.hostKey(host: host, port: request.url.port)
            phase = .pinning(hostKey: hostKey)
            do {
                try await SecurityPolicy.ensureTrusted(for: request.url)
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
        bufferLimitMb = request.bufferLimitMb
        bufferTargetSeconds = PlaybackBufferPreference.seconds(
            limitMb: request.bufferLimitMb,
            bitRate: PlaybackBufferPreference.observedBitRate
        )
        playbackURL = request.url
        installKSPlayerCallbacks()
        ksOptions = options
        activeOptions = options

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

                // 缓冲进度只认 playableTime。
                //
                // KSMEPlayer 里 playableTime = currentPlaybackTime + loadedTime，
                // 也就是「已经能播到哪个时间点」。不要用 onBufferChanged：
                // 它的两个参数是 (bufferedCount, consumeTime)，后者是「这一次缓冲花了多久」，
                // 当成已缓冲秒数用会得到一个几百毫秒的数字，进度条永远画不出来。
                if let layer = self.ksCoordinator.playerLayer {
                    let playable = max(current, layer.player.playableTime)
                    if playable > 0 {
                        self.bufferedPositionMs = Int64(playable * 1000)
                    }
                }

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

        // 轨道已经解析出来了，用真实码率把「MB → 秒」校正一次。
        refreshBufferTarget()

        if setupResumeMs > 0 {
            let resume = setupResumeMs
            setupResumeMs = 0
            ksCoordinator.seek(time: TimeInterval(resume) / 1000.0)
        } else {
            play()
        }
    }

    /// 用真实码率把「缓冲上限 MB」折算成 `maxBufferDuration` 秒数。
    ///
    /// 必须在解析出轨道之后才能算：`avformat_open_input` 之前拿不到码率，
    /// 所以 load 时先用上次观测到的码率估算，这里再用真实值校正。
    /// 改的是同一个 `KSOptions` 实例，`codecDidChangeCapacity` 每轮都会读它，立即生效。
    private func refreshBufferTarget() {
        guard let player = ksCoordinator.playerLayer?.player else { return }

        // 1. 视频轨码率（FFmpeg 的 codecpar.bit_rate），最准确
        var bitRate = Double(
            player.tracks(mediaType: .video)
                .first(where: { $0.isEnabled })?
                .bitRate ?? 0
        )
        // 2. 反推整体码率：KSPlayer 内部 fileSize = bit_rate × duration ÷ 8
        if bitRate <= 0, player.duration > 0, player.fileSize > 0 {
            bitRate = player.fileSize * 8 / player.duration
        }
        guard bitRate > 0, bitRate.isFinite else { return }

        PlaybackBufferPreference.rememberBitRate(bitRate)
        let seconds = PlaybackBufferPreference.seconds(limitMb: bufferLimitMb, bitRate: bitRate)
        bufferTargetSeconds = seconds
        activeOptions?.maxBufferDuration = seconds
        D.log("buffer", "目标 \(Int(seconds))s = \(bufferLimitMb)MB @ "
            + String(format: "%.1f", bitRate / 1_000_000) + "Mbps")
    }

    private func fail(_ reason: String) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil

        // 失败原因一律用底层原文，不加工、不降级。
        // 证书类问题在进入引擎之前就已经给出可操作的说明，这里不再追加提示。
        D.log("engine", "失败: \(reason)")
        errorMessage = reason
        isPlaying = false
        phase = .failed(reason)
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
        isPlaying = false
        currentPositionMs = 0
        durationMs = 0
        bufferedPositionMs = 0
        activeOptions = nil
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
