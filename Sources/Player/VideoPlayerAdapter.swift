import SwiftUI
import AVFoundation
import Combine
import Darwin

#if canImport(KSPlayer)
import KSPlayer
#endif

/// 播放器统一协议与控制器
@MainActor
public final class VideoPlayerController: ObservableObject {
    @Published public var isPlaying: Bool = false
    @Published public var currentPositionMs: Int64 = 0
    @Published public var durationMs: Int64 = 0
    @Published public var bufferedPositionMs: Int64 = 0
    @Published public var playbackSpeed: Double = 1.0
    @Published public var isReady: Bool = false
    @Published public var isAspectFill: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var isFinished: Bool = false
    @Published public var isPiPActive: Bool = false
    @Published public var subtitleText: String? = nil

    public var onPlaybackEnded: (() -> Void)?
    @Published public private(set) var volume: Double = 1.0

    fileprivate var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()

    #if canImport(KSPlayer)
    public let ksCoordinator = KSVideoPlayer.Coordinator()
    @Published public var ksOptions: KSOptions?
    private var selectedSubtitleFileURL: URL?
    private var setupResumeMs: Int64 = 0
    private var pipStateCancellable: AnyCancellable?
    private weak var boundPiPLayer: KSPlayerLayer?
    #endif

    /// 实际交给播放器的地址。开启“允许自签名证书”时，这会是本机回环代理地址。
    @Published public private(set) var playbackURL: URL?
    private var playbackProxySession: InsecurePlaybackSession?

    public init() {}

    public func setup(url: URL, headers: [String: String], resumeMs: Int64, cacheLimitMb: Int = 128) {
        isPlaying = false
        isReady = false
        isFinished = false
        isPiPActive = false
        errorMessage = nil
        subtitleText = nil
        currentPositionMs = max(0, resumeMs)
        durationMs = 0
        bufferedPositionMs = 0

        #if canImport(KSPlayer)
        // 先移除旧图层并重建底层 player layer；仅修改 URL 不会让 KSPlayer 重建播放器。
        // 先把 ksOptions 清空，避免旧 options 与新代理地址组合后短暂创建出错误的播放器。
        if let oldLayer = ksCoordinator.playerLayer, oldLayer.isPipActive {
            oldLayer.isPipActive = false
        }
        pipStateCancellable?.cancel()
        pipStateCancellable = nil
        boundPiPLayer = nil
        ksOptions = nil
        ksCoordinator.resetPlayer()
        #endif

        // 自签名开关开启时，所有 HTTPS 播放地址都改走本机回环代理，
        // 让 FFmpeg 和 AVFoundation 都不直接处理远端证书。
        playbackProxySession?.invalidate()
        playbackProxySession = nil
        let resolvedURL: URL
        if InsecurePlaybackProxy.isEnabled, url.scheme?.lowercased() == "https",
           let proxySession = InsecurePlaybackProxy.shared.makeSession(remoteURL: url, headers: headers)
        {
            playbackProxySession = proxySession
            resolvedURL = proxySession.localURL
        } else {
            resolvedURL = url
        }
        playbackURL = resolvedURL

        #if canImport(KSPlayer)
        let options = KSOptions()
        // 设置 302 重定向请求头保持与网络参数
        options.appendHeader(headers)
        // 允许自签名或无校验的 TLS/HTTPS 直链
        options.formatContextOptions["tls_verify"] = "0"
        // KSPlayer 2.3.x 移除了实例 isAutoPlay，图层默认自动 prepare；
        // 播放时机由下面 onStateChanged(.readyToPlay) 统一控制。
        options.isSeekedAutoPlay = true
        // 由 App 统一注册 MPRemoteCommandCenter，避免与 KSPlayer 重复响应。
        options.registerRemoteControll = false
        options.canStartPictureInPictureAutomaticallyFromInline = true

        // cache_limit_mb 映射为 KSPlayer 的最大缓存时长。
        // KSPlayer 只暴露时长配置，这里按约 8 Mbps 估算：1 MB ≈ 1 秒。
        let normalizedCacheLimit = max(0, cacheLimitMb)
        options.cache = normalizedCacheLimit > 0
        if normalizedCacheLimit > 0 {
            let cacheSeconds = min(300.0, max(15.0, Double(normalizedCacheLimit)))
            options.maxBufferDuration = cacheSeconds
            options.preferredForwardBufferDuration = min(cacheSeconds, max(3.0, cacheSeconds / 4.0))
        }

        // 回环代理本身是 HTTP，不要再让 FFmpeg 读取系统代理环境变量；
        // 未启用代理时恢复 KSPlayer 的默认行为。
        if playbackProxySession != nil {
            KSOptions.useSystemHTTPProxy = false
            unsetenv("http_proxy")
            unsetenv("https_proxy")
        } else {
            KSOptions.useSystemHTTPProxy = true
        }
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSAVPlayer.self
        self.setupResumeMs = max(0, resumeMs)
        installKSPlayerCallbacks()
        // 最后再发布 options，确保 SwiftUI 创建图层时回调与续播位置都已就绪。
        self.ksOptions = options

        // 重试/重新 setup 时恢复用户已选择的字幕。
        DispatchQueue.main.async { [weak self] in
            self?.reapplySelectedSubtitle()
        }
        #else
        // Fallback: 原生 AVPlayer 方案
        let asset = AVURLAsset(url: resolvedURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.volume = Float(volume)
        self.avPlayer = player

        // 监听播放状态
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isFinished = true
                    self?.isPlaying = false
                    self?.onPlaybackEnded?()
                }
            }
            .store(in: &cancellables)

        // 监听缓冲与时长
        playerItem.publisher(for: \.loadedTimeRanges)
            .sink { [weak self] ranges in
                if let first = ranges.first?.timeRangeValue {
                    let buffered = CMTimeGetSeconds(first.start) + CMTimeGetSeconds(first.duration)
                    DispatchQueue.main.async {
                        self?.bufferedPositionMs = Int64(buffered * 1000)
                    }
                }
            }
            .store(in: &cancellables)

        playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if status == .readyToPlay {
                        self.isReady = true
                        let dur = CMTimeGetSeconds(playerItem.duration)
                        if !dur.isNaN && dur > 0 {
                            self.durationMs = Int64(dur * 1000)
                        }
                        if resumeMs > 0 {
                            self.seek(toMs: resumeMs)
                        }
                        self.play()
                    } else if status == .failed {
                        self.errorMessage = playerItem.error?.localizedDescription ?? "播放失败"
                    }
                }
            }
            .store(in: &cancellables)

        // 周期性进度监听
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let secs = CMTimeGetSeconds(time)
            if !secs.isNaN && secs >= 0 {
                self.currentPositionMs = Int64(secs * 1000)
            }
            self.isPlaying = (player.timeControlStatus == .playing)
        }
        #endif
    }

    public func play() {
        isFinished = false
        #if canImport(KSPlayer)
        ksCoordinator.playerLayer?.play()
        isPlaying = true
        #else
        avPlayer?.play()
        avPlayer?.rate = Float(playbackSpeed)
        isPlaying = true
        #endif
    }

    public func pause() {
        #if canImport(KSPlayer)
        ksCoordinator.playerLayer?.pause()
        isPlaying = false
        #else
        avPlayer?.pause()
        isPlaying = false
        #endif
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func seek(toMs: Int64) {
        let upperBound = durationMs > 0 ? durationMs : toMs
        let target = max(0, min(toMs, upperBound))
        isFinished = false
        currentPositionMs = target
        #if canImport(KSPlayer)
        ksCoordinator.seek(time: TimeInterval(target) / 1000.0)
        #else
        let targetTime = CMTime(seconds: Double(target) / 1000.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avPlayer?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        #endif
    }

    public func skip(seconds: Int64) {
        let target = max(0, min(durationMs > 0 ? durationMs : Int64.max, currentPositionMs + seconds * 1000))
        seek(toMs: target)
    }

    public func setSpeed(_ speed: Double) {
        playbackSpeed = speed
        #if canImport(KSPlayer)
        ksCoordinator.playbackRate = Float(speed)
        #else
        if isPlaying {
            avPlayer?.rate = Float(speed)
        }
        #endif
    }

    public func toggleAspect() {
        isAspectFill.toggle()
        #if canImport(KSPlayer)
        ksCoordinator.isScaleAspectFill = isAspectFill
        #endif
    }

    /// 调节播放器音量（0...1）。使用播放器音量而非系统音量，避免修改全局设置。
    public func setVolume(_ value: Double) {
        let clamped = max(0, min(1, value))
        volume = clamped
        #if canImport(KSPlayer)
        ksCoordinator.playerLayer?.player.playbackVolume = Float(clamped)
        #else
        avPlayer?.volume = Float(clamped)
        #endif
    }

    public var isPiPAvailable: Bool {
        #if canImport(KSPlayer)
        return ksCoordinator.playerLayer?.player.pipController != nil
        #else
        return false
        #endif
    }

    /// 切换画中画。返回切换后的状态；不支持 PiP 时返回 false。
    @discardableResult
    public func togglePiP() -> Bool {
        #if canImport(KSPlayer)
        guard let layer = ksCoordinator.playerLayer, layer.player.pipController != nil else {
            return false
        }
        layer.isPipActive.toggle()
        isPiPActive = layer.isPipActive
        return layer.isPipActive
        #else
        return false
        #endif
    }

    /// 下载并加载外挂字幕。通过 PlayApi 下载，确保自签名 HTTPS 服务端也可用。
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

        #if canImport(KSPlayer)
        if let oldURL = selectedSubtitleFileURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        selectedSubtitleFileURL = fileURL
        ksCoordinator.subtitleModel.selectedSubtitleInfo = URLSubtitleInfo(url: fileURL)
        #else
        try? FileManager.default.removeItem(at: fileURL)
        #endif
    }

    public func clearSubtitle() {
        #if canImport(KSPlayer)
        ksCoordinator.subtitleModel.selectedSubtitleInfo = nil
        if let oldURL = selectedSubtitleFileURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        selectedSubtitleFileURL = nil
        #endif
        subtitleText = nil
    }

    #if canImport(KSPlayer)
    /// 重新安装回调。图层重建/重试时会由新的 KSPlayerLayer 接管 delegate，
    /// 因此每次挂载图层后都需要再次安装 App 的回调。
    public func installKSPlayerCallbacks() {
        ksCoordinator.onStateChanged = { [weak self] layer, state in
            DispatchQueue.main.async {
                guard let self = self, self.ksCoordinator.playerLayer === layer else { return }
                if state == .readyToPlay {
                    self.isReady = true
                    self.applyVolume()
                    self.ksCoordinator.playbackRate = Float(self.playbackSpeed)
                    self.ksCoordinator.isScaleAspectFill = self.isAspectFill
                    // subtitleModel.url 在图层创建时会被异步重置，就绪后再恢复一次外挂字幕。
                    self.reapplySelectedSubtitle()
                    if self.setupResumeMs > 0 {
                        let resumeMs = self.setupResumeMs
                        self.setupResumeMs = 0
                        self.ksCoordinator.seek(time: TimeInterval(resumeMs) / 1000.0)
                    } else {
                        self.play()
                    }
                } else if state == .error {
                    self.isReady = false
                    self.isPlaying = false
                    if self.errorMessage == nil {
                        self.errorMessage = "播放器加载失败"
                    }
                }
            }
        }

        ksCoordinator.onPlay = { [weak self] current, total in
            DispatchQueue.main.async {
                guard let self = self, self.ksCoordinator.playerLayer != nil else { return }
                self.currentPositionMs = Int64(current * 1000)
                if total > 0 {
                    self.durationMs = Int64(total * 1000)
                }
                self.isPlaying = self.ksCoordinator.state.isPlaying

                let subtitle = self.ksCoordinator.subtitleModel.parts
                    .compactMap { $0.text?.string }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                self.subtitleText = subtitle.isEmpty ? nil : subtitle
            }
        }

        ksCoordinator.onBufferChanged = { [weak self] _, buffered in
            DispatchQueue.main.async {
                guard let self = self, self.ksCoordinator.playerLayer != nil else { return }
                self.bufferedPositionMs = Int64(buffered * 1000)
            }
        }

        ksCoordinator.onFinish = { [weak self] layer, error in
            DispatchQueue.main.async {
                guard let self = self, self.ksCoordinator.playerLayer === layer else { return }
                self.isPlaying = false
                if let err = error {
                    self.isReady = false
                    self.errorMessage = err.localizedDescription
                } else {
                    self.isFinished = true
                    self.onPlaybackEnded?()
                }
            }
        }
    }

    private func applyVolume() {
        ksCoordinator.playerLayer?.player.playbackVolume = Float(volume)
    }

    /// 同步系统侧退出画中画后的按钮状态。
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

    private func reapplySelectedSubtitle() {
        guard let fileURL = selectedSubtitleFileURL else { return }
        ksCoordinator.subtitleModel.selectedSubtitleInfo = URLSubtitleInfo(url: fileURL)
    }
    #endif

    public func destroy() {
        isPlaying = false
        isReady = false
        isPiPActive = false
        subtitleText = nil
        playbackProxySession?.invalidate()
        playbackProxySession = nil
        playbackURL = nil
        #if canImport(KSPlayer)
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
        #else
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        #endif
        cancellables.removeAll()
    }
}

/// 播放器视频渲染图层 View
public struct VideoSurfaceView: View {
    @ObservedObject public var controller: VideoPlayerController
    public let url: URL
    public let headers: [String: String]
    public let resumeMs: Int64

    public init(
        controller: VideoPlayerController,
        url: URL,
        headers: [String: String],
        resumeMs: Int64
    ) {
        self.controller = controller
        self.url = url
        self.headers = headers
        self.resumeMs = resumeMs
    }

    public var body: some View {
        #if canImport(KSPlayer)
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
        #else
        AVPlayerSurfaceView(player: controller.avPlayer, isAspectFill: controller.isAspectFill)
            .ignoresSafeArea()
        #endif
    }
}

#if canImport(KSPlayer)
/// 直接承载 KSPlayerLayer 的渲染 view，避免 KSVideoPlayer 在 URL 不变时无法重建播放器，
/// 同时确保图层重建后回调仍由 App 安装。
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
        // 仅在 URL 变化或重试后 playerLayer 为空时创建新图层。
        // 频繁调用 makeView 会反复重置 subtitleModel.url，从而清空字幕选择。
        if controller.ksCoordinator.playerLayer?.url != url {
            _ = controller.ksCoordinator.makeView(url: url, options: options)
        }

        guard let layer = controller.ksCoordinator.playerLayer,
              let playerView = layer.player.view
        else {
            // 播放器还没准备好渲染 view，先清掉旧图层，避免重试后旧画面残留。
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        // KSPlayer 2.3+ 的 KSPlayerLayer 是 NSObject，真正的渲染视图在 player.view。
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

        controller.installKSPlayerCallbacks()
        controller.bindPiPState(for: layer)
    }
}
#endif

#if !canImport(KSPlayer)
/// 原生 AVPlayerLayer 视图封装
struct AVPlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer?
    let isAspectFill: Bool

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = isAspectFill ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = isAspectFill ? .resizeAspectFill : .resizeAspect
    }
}

class PlayerContainerUIView: UIView {
    var playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
#endif
