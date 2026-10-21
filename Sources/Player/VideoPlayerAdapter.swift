import SwiftUI
import AVFoundation
import Combine

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

    public var onPlaybackEnded: (() -> Void)?

    private var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()

    #if canImport(KSPlayer)
    public let ksCoordinator = KSVideoPlayer.Coordinator()
    public var ksOptions: KSOptions?
    private var hasConfiguredKS = false
    #endif

    public init() {}

    public func setup(url: URL, headers: [String: String], resumeMs: Int64) {
        currentPositionMs = resumeMs

        #if canImport(KSPlayer)
        let options = KSOptions()
        // 设置 302 重定向请求头保持与网络参数
        options.appendHeader(headers)
        options.firstPlayerType = KSMEPlayer.self
        options.secondPlayerType = KSAVPlayer.self
        self.ksOptions = options

        ksCoordinator.onStateChanged = { [weak self] _, state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if state == .readyToPlay {
                    self.isReady = true
                    if resumeMs > 0 {
                        self.ksCoordinator.seek(time: TimeInterval(resumeMs) / 1000.0)
                    }
                }
            }
        }

        ksCoordinator.onPlay = { [weak self] current, total in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.currentPositionMs = Int64(current * 1000)
                if total > 0 {
                    self.durationMs = Int64(total * 1000)
                }
                self.isPlaying = self.ksCoordinator.state.isPlaying
            }
        }

        ksCoordinator.onBufferChanged = { [weak self] _, buffered in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.bufferedPositionMs = Int64(buffered * 1000)
            }
        }

        ksCoordinator.onFinish = { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = error {
                    self.errorMessage = err.localizedDescription
                } else {
                    self.isFinished = true
                    self.onPlaybackEnded?()
                }
            }
        }

        hasConfiguredKS = true
        #else
        // Fallback: 原生 AVPlayer 方案
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
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
        currentPositionMs = toMs
        #if canImport(KSPlayer)
        ksCoordinator.seek(time: TimeInterval(toMs) / 1000.0)
        #else
        let targetTime = CMTime(seconds: Double(toMs) / 1000.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
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

    public func destroy() {
        #if canImport(KSPlayer)
        ksCoordinator.resetPlayer()
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
            KSVideoPlayer(coordinator: controller.ksCoordinator, url: url, options: options)
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
