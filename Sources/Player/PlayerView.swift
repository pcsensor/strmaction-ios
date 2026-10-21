import SwiftUI
import AVFoundation
import MediaPlayer
import Combine

public struct PlayerView: View {
    private struct RemoteRegistration {
        let command: MPRemoteCommand
        let token: Any
    }

    public let playInfo: PlayResponse
    public let serverUrl: String
    public var onClose: () -> Void
    public var onSelectEpisode: (Int) -> Void

    // 核心播放控制器
    @StateObject private var playerController = VideoPlayerController()

    // 播放与界面状态
    @State private var isControlsVisible: Bool = true
    @State private var showEpisodesDrawer: Bool = false
    @State private var showSpeedDrawer: Bool = false
    @State private var showMoreSettingsDrawer: Bool = false
    @State private var isFastForwarding: Bool = false
    @State private var originalSpeedBeforeFast: Double = 1.0
    @State private var feedbackText: String? = nil
    @State private var scrubPreviewText: String? = nil

    // 手势状态（亮度、音量）
    @State private var brightnessLevel: Double = Double(UIScreen.main.brightness)
    @State private var showBrightnessOverlay: Bool = false
    @State private var showVolumeOverlay: Bool = false
    @State private var panStartBrightness: Double? = nil
    @State private var panStartVolume: Double? = nil

    // 字幕
    @State private var selectedSubtitleId: String? = nil
    @State private var subtitleLoadTask: Task<Void, Never>? = nil

    // 超时与自动连播状态
    @State private var showTimeoutAlert: Bool = false
    @State private var autoNextCountdown: Int = 3
    @State private var showAutoNextOverlay: Bool = false

    // 用户偏好
    @AppStorage("long_press_speed") private var longPressSpeed: Double = 2.0

    // 定时器
    @State private var heartbeatTimer: Timer?
    @State private var hideControlsTimer: Timer?
    @State private var loadingTimeoutTimer: Timer?
    @State private var autoNextTimer: Timer?
    @State private var remoteRegistrations: [RemoteRegistration] = []

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
    private let longPressSpeeds: [Double] = [1.5, 2.0, 2.5, 3.0]

    public init(
        playInfo: PlayResponse,
        serverUrl: String,
        onClose: @escaping () -> Void,
        onSelectEpisode: @escaping (Int) -> Void
    ) {
        self.playInfo = playInfo
        self.serverUrl = serverUrl
        self.onClose = onClose
        self.onSelectEpisode = onSelectEpisode
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 1. 底层：视频画面渲染视图
                Color.black.ignoresSafeArea()

                if let videoUrl = URL(string: playInfo.playUrl) {
                    VideoSurfaceView(
                        controller: playerController,
                        url: videoUrl,
                        headers: playInfo.safeHeaders,
                        resumeMs: playInfo.resumeMs
                    )
                }

                // 2. 长按快速倍速提示
                if isFastForwarding {
                    VStack {
                        HStack(spacing: 6) {
                            Image(systemName: "forward.fill")
                            Text("\(String(format: "%.1fx", longPressSpeed)) 极速播放中")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(Color(hex: "#E8B06A"))
                        .cornerRadius(20)
                        .padding(.top, 40)
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // 3. 快进/快退手势反馈提示
                if let feedback = feedbackText {
                    Text(feedback)
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .transition(.scale)
                }

                // 4. 水平拖拽进度预览提示
                if let scrubText = scrubPreviewText {
                    Text(scrubText)
                        .font(.system(size: 18, weight: .bold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.85))
                        .foregroundColor(Color(hex: "#E8B06A"))
                        .cornerRadius(12)
                }

                // 5. 侧边亮度/音量指示器
                if showBrightnessOverlay {
                    VStack {
                        Image(systemName: "sun.max.fill")
                            .foregroundColor(Color(hex: "#E8B06A"))
                        ProgressView(value: brightnessLevel, total: 1.0)
                            .tint(Color(hex: "#E8B06A"))
                            .frame(width: 80)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(10)
                    .position(x: 60, y: geometry.size.height / 2)
                    .transition(.opacity)
                }

                if showVolumeOverlay {
                    VStack {
                        Image(systemName: playerController.volume <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(Color(hex: "#E8B06A"))
                        ProgressView(value: playerController.volume, total: 1.0)
                            .tint(Color(hex: "#E8B06A"))
                            .frame(width: 80)
                        Text("\(Int(playerController.volume * 100))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(10)
                    .position(x: geometry.size.width - 60, y: geometry.size.height / 2)
                    .transition(.opacity)
                }

                // 6. 外挂字幕渲染层
                if let subtitle = playerController.subtitleText {
                    VStack {
                        Spacer()
                        Text(subtitle)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(6)
                            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 96)
                    }
                    .allowsHitTesting(false)
                }

                // 7. 交互手势层
                gestureOverlay(geometry: geometry)

                // 8. 控制层 (TopBar, CenterButton, BottomBar)
                if isControlsVisible {
                    VStack {
                        topBar
                        Spacer()
                        centerButton
                        Spacer()
                        bottomBar
                    }
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.black.opacity(0.7),
                                Color.clear,
                                Color.clear,
                                Color.black.opacity(0.8)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .transition(.opacity)
                }

                // 9. 播完即将连播下一集过渡浮层
                if showAutoNextOverlay {
                    autoNextEpisodeOverlay
                }

                // 10. 40% 右侧侧滑抽屉（选集 / 倍速 / 更多设置）
                if showEpisodesDrawer || showSpeedDrawer || showMoreSettingsDrawer {
                    HStack(spacing: 0) {
                        // 左侧 60% 遮罩区域，点击平滑收回
                        Color.black.opacity(0.5)
                            .frame(width: geometry.size.width * 0.6)
                            .onTapGesture {
                                dismissAllDrawers()
                            }

                        // 右侧 40% 抽屉内容区
                        ZStack {
                            Color(hex: "#14161C").opacity(0.98)
                            if showEpisodesDrawer {
                                episodesDrawerView
                            } else if showSpeedDrawer {
                                speedDrawerView
                            } else if showMoreSettingsDrawer {
                                moreSettingsDrawerView
                            }
                        }
                        .frame(width: geometry.size.width * 0.4)
                    }
                    .transition(.move(edge: .trailing))
                }

                // 11. 播放错误提示（覆盖控制层，避免错误被静默忽略）
                if let message = playerController.errorMessage {
                    errorOverlay(message)
                }
            }
        }
        .onAppear {
            setupInitialState()
        }
        .onDisappear {
            cleanup()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            sendProgress(finished: false)
        }
        .onReceive(playerController.$isReady.removeDuplicates()) { ready in
            if ready {
                showTimeoutAlert = false
                // KSPlayer 图层创建/重建后重新注册 App 自己的远程控制处理器。
                setupRemoteCommands()
            }
        }
        .onReceive(playerController.$errorMessage.removeDuplicates()) { message in
            if message != nil {
                showTimeoutAlert = false
            }
        }
        .alert("连接提示", isPresented: $showTimeoutAlert) {
            Button("重试连接") {
                restartPlayback()
            }
            Button("复制直链") {
                UIPasteboard.general.string = playInfo.playUrl
                showFeedback("直链已复制到剪贴板")
            }
            Button("用外部播放器打开") {
                openExternalPlayer()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("连接网盘超时，可能因防盗链拦截或网络阻塞。您可以尝试重试，或复制直链通过第三方播放器加载。")
        }
    }

    // MARK: - 手势层

    private func gestureOverlay(geometry: GeometryProxy) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                toggleControls()
            }
            .gesture(
                TapGesture(count: 2)
                    .onEnded {
                        // 双击判定：在手势坐标内判断位置
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { event in
                        handleDoubleTap(at: event.location, width: geometry.size.width)
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in
                        triggerLongPressSpeed(true)
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        handlePanGesture(value: value, geometry: geometry)
                    }
                    .onEnded { value in
                        handlePanEnd(value: value, geometry: geometry)
                    }
            )
    }

    private func handleDoubleTap(at location: CGPoint, width: CGFloat) {
        let ratio = location.x / width
        if ratio < 0.35 {
            // 左侧 35%：快退 10 秒
            playerController.skip(seconds: -10)
            showFeedback("⏪ 快退 10 秒")
        } else if ratio > 0.65 {
            // 右侧 35%：快进 10 秒
            playerController.skip(seconds: 10)
            showFeedback("⏩ 快进 10 秒")
        } else {
            // 中间 30%：切换播放/暂停
            playerController.togglePlayPause()
        }
    }

    private func handlePanGesture(value: DragGesture.Value, geometry: GeometryProxy) {
        let translation = value.translation
        if abs(translation.width) > abs(translation.height) && abs(translation.width) > 20 {
            // 水平滑动：快进/快退进度预拖拽
            let scrubDeltaSeconds = Int64(translation.width / 5)
            let previewTarget = max(0, min(playerController.durationMs, playerController.currentPositionMs + scrubDeltaSeconds * 1000))
            let sign = scrubDeltaSeconds >= 0 ? "+" : ""
            scrubPreviewText = "\(sign)\(scrubDeltaSeconds)s (\(formatTime(previewTarget)))"
        } else if abs(translation.height) > 20 {
            // 垂直滑动：左半屏调亮度，右半屏调音量
            if value.startLocation.x < geometry.size.width * 0.5 {
                if panStartBrightness == nil {
                    panStartBrightness = brightnessLevel
                }
                let delta = Double(-translation.height / 300)
                let newBrightness = max(0.0, min(1.0, (panStartBrightness ?? brightnessLevel) + delta))
                UIScreen.main.brightness = CGFloat(newBrightness)
                brightnessLevel = newBrightness
                showBrightnessOverlay = true
            } else {
                if panStartVolume == nil {
                    panStartVolume = playerController.volume
                }
                let delta = Double(-translation.height / 300)
                let newVolume = max(0.0, min(1.0, (panStartVolume ?? playerController.volume) + delta))
                playerController.setVolume(newVolume)
                showVolumeOverlay = true
            }
        }
    }

    private func handlePanEnd(value: DragGesture.Value, geometry: GeometryProxy) {
        let translation = value.translation
        if abs(translation.width) > abs(translation.height) && abs(translation.width) > 20 {
            let scrubDeltaSeconds = Int64(translation.width / 5)
            playerController.skip(seconds: scrubDeltaSeconds)
            scrubPreviewText = nil
        }
        panStartBrightness = nil
        panStartVolume = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showBrightnessOverlay = false
            showVolumeOverlay = false
        }
        if isFastForwarding {
            triggerLongPressSpeed(false)
        }
    }

    // MARK: - 子视图组件

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: handleClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playInfo.fullDisplayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Spacer()

            // 画面比例切换 (Fit / Fill)
            Button(action: {
                playerController.toggleAspect()
                showFeedback(playerController.isAspectFill ? "铺满屏幕" : "原始比例")
            }) {
                Image(systemName: playerController.isAspectFill ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(6)
            }

            // 画中画按钮 (PiP)
            Button(action: {
                if playerController.togglePiP() {
                    showFeedback(playerController.isPiPActive ? "已开启画中画" : "已退出画中画")
                } else {
                    showFeedback("当前设备或播放器不支持画中画")
                }
                resetControlsTimer()
            }) {
                Image(systemName: playerController.isPiPActive ? "pip.exit" : "pip.enter")
                    .font(.system(size: 17))
                    .foregroundColor(.white)
                    .padding(6)
            }

            // 更多设置按钮 (⚙)
            Button(action: {
                dismissAllDrawers()
                withAnimation { showMoreSettingsDrawer.toggle() }
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundColor(.white)
                    .padding(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var centerButton: some View {
        Button(action: {
            playerController.togglePlayPause()
            resetControlsTimer()
        }) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 64, height: 64)
                Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            // 三层缓冲进度条
            BufferedSeekBar(
                currentMs: playerController.currentPositionMs,
                durationMs: playerController.durationMs,
                bufferedMs: playerController.bufferedPositionMs,
                onSeek: { targetMs in
                    playerController.seek(toMs: targetMs)
                    resetControlsTimer()
                },
                onScrubbingChanged: { isScrubbing, ms in
                    if isScrubbing {
                        scrubPreviewText = formatTime(ms)
                    } else {
                        scrubPreviewText = nil
                    }
                }
            )

            HStack(spacing: 16) {
                // 播放/暂停
                Button(action: {
                    playerController.togglePlayPause()
                    resetControlsTimer()
                }) {
                    Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                }

                // 上一集
                Button(action: playPreviousEpisode) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14))
                        .foregroundColor(hasPreviousEpisode ? .white : Color(hex: "#5C6678"))
                }
                .disabled(!hasPreviousEpisode)

                // 下一集
                Button(action: playNextEpisode) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 14))
                        .foregroundColor(hasNextEpisode ? .white : Color(hex: "#5C6678"))
                }
                .disabled(!hasNextEpisode)

                Text("\(formatTime(playerController.currentPositionMs)) / \(formatTime(playerController.durationMs))")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#8A93A5"))

                Spacer()

                // 选集按钮
                if !playInfo.safePlaylist.isEmpty {
                    Button("选集") {
                        dismissAllDrawers()
                        withAnimation { showEpisodesDrawer.toggle() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(showEpisodesDrawer ? Color(hex: "#E8B06A") : .white)
                    .padding(.horizontal, 6)
                }

                // 倍速按钮
                Button("\(String(format: "%.1fx", playerController.playbackSpeed))") {
                    dismissAllDrawers()
                    withAnimation { showSpeedDrawer.toggle() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(showSpeedDrawer ? Color(hex: "#E8B06A") : .white)
                .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - 40% 右侧侧滑抽屉

    private var episodesDrawerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选集 (\(playInfo.safePlaylist.count))")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { withAnimation { showEpisodesDrawer = false } }) {
                    Image(systemName: "xmark")
                        .foregroundColor(Color(hex: "#8A93A5"))
                        .padding(4)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(playInfo.safePlaylist) { ep in
                        let isCurrent = (ep.id == playInfo.itemId) || ep.isCurrent
                        Button(action: {
                            withAnimation { showEpisodesDrawer = false }
                            if ep.id != playInfo.itemId {
                                sendProgress(finished: false)
                                onSelectEpisode(ep.id)
                            }
                        }) {
                            HStack {
                                if isCurrent {
                                    Image(systemName: "play.fill")
                                        .font(.caption2)
                                        .foregroundColor(Color(hex: "#E8B06A"))
                                }
                                Text(ep.displayLabel)
                                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                                    .foregroundColor(isCurrent ? Color(hex: "#E8B06A") : .white)
                                    .lineLimit(1)
                                Spacer()
                                if ep.isWatched {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .foregroundColor(Color(hex: "#8A93A5"))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(isCurrent ? Color(hex: "#1E222D") : Color.clear)
                            .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var speedDrawerView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("播放速度")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { withAnimation { showSpeedDrawer = false } }) {
                    Image(systemName: "xmark")
                        .foregroundColor(Color(hex: "#8A93A5"))
                        .padding(4)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(speeds, id: \.self) { sp in
                        Button(action: {
                            playerController.setSpeed(sp)
                            withAnimation { showSpeedDrawer = false }
                        }) {
                            HStack {
                                Text("\(String(format: "%.2fx", sp))")
                                    .font(.system(size: 14))
                                    .foregroundColor(playerController.playbackSpeed == sp ? Color(hex: "#E8B06A") : .white)
                                Spacer()
                                if playerController.playbackSpeed == sp {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundColor(Color(hex: "#E8B06A"))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(playerController.playbackSpeed == sp ? Color(hex: "#1E222D") : Color.clear)
                            .cornerRadius(6)
                        }
                    }

                    Divider().background(Color(hex: "#1E222D")).padding(.vertical, 8)

                    Text("长按快捷倍速设定")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "#8A93A5"))
                        .padding(.horizontal, 16)

                    HStack(spacing: 8) {
                        ForEach(longPressSpeeds, id: \.self) { lp in
                            Button("\(String(format: "%.1fx", lp))") {
                                longPressSpeed = lp
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(longPressSpeed == lp ? Color(hex: "#E8B06A") : Color(hex: "#1E222D"))
                            .foregroundColor(longPressSpeed == lp ? Color(hex: "#07080A") : .white)
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var moreSettingsDrawerView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("更多设置")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { withAnimation { showMoreSettingsDrawer = false } }) {
                    Image(systemName: "xmark")
                        .foregroundColor(Color(hex: "#8A93A5"))
                        .padding(4)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 外挂字幕切换
                    VStack(alignment: .leading, spacing: 8) {
                        Text("外挂字幕")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: "#8A93A5"))

                        if playInfo.safeSubtitles.isEmpty {
                            Text("无外挂字幕")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                                .padding(.vertical, 4)
                        } else {
                            if selectedSubtitleId != nil {
                                Button(action: {
                                    selectedSubtitleId = nil
                                    subtitleLoadTask?.cancel()
                                    subtitleLoadTask = nil
                                    playerController.clearSubtitle()
                                    showFeedback("已关闭字幕")
                                    withAnimation { showMoreSettingsDrawer = false }
                                }) {
                                    HStack {
                                        Image(systemName: "captions.bubble")
                                        Text("关闭字幕")
                                            .font(.system(size: 13))
                                        Spacer()
                                    }
                                    .foregroundColor(Color(hex: "#E8B06A"))
                                    .padding(.vertical, 6)
                                }
                            }

                            ForEach(playInfo.safeSubtitles) { sub in
                                Button(action: {
                                    selectSubtitle(sub)
                                }) {
                                    HStack {
                                        Text(sub.label)
                                            .font(.system(size: 13))
                                            .foregroundColor(selectedSubtitleId == sub.id ? Color(hex: "#E8B06A") : .white)
                                        Spacer()
                                        if selectedSubtitleId == sub.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(Color(hex: "#E8B06A"))
                                        }
                                        if let fmt = sub.format {
                                            Text(fmt.uppercased())
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(Color(hex: "#E8B06A"))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color(hex: "#1E222D"))
                                                .cornerRadius(4)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                    }

                    Divider().background(Color(hex: "#1E222D"))

                    // 外部播放器
                    VStack(alignment: .leading, spacing: 8) {
                        Text("外部工具")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: "#8A93A5"))

                        Button(action: {
                            openExternalPlayer()
                        }) {
                            HStack {
                                Image(systemName: "arrow.up.right.video")
                                Text("用外部播放器打开 (Infuse / VLC)")
                                    .font(.system(size: 13))
                            }
                            .foregroundColor(.white)
                            .padding(.vertical, 6)
                        }

                        Button(action: {
                            UIPasteboard.general.string = playInfo.playUrl
                            showFeedback("播放直链已复制")
                        }) {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text("复制视频直链")
                                    .font(.system(size: 13))
                            }
                            .foregroundColor(Color(hex: "#E8B06A"))
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func selectSubtitle(_ subtitle: SubtitleEntry) {
        if selectedSubtitleId == subtitle.id {
            selectedSubtitleId = nil
            subtitleLoadTask?.cancel()
            subtitleLoadTask = nil
            playerController.clearSubtitle()
            showFeedback("已关闭字幕")
            withAnimation { showMoreSettingsDrawer = false }
            return
        }

        subtitleLoadTask?.cancel()
        selectedSubtitleId = subtitle.id
        showFeedback("正在加载字幕: \(subtitle.label)")
        withAnimation { showMoreSettingsDrawer = false }

        subtitleLoadTask = Task { @MainActor in
            do {
                try await playerController.loadSubtitle(subtitle, serverUrl: serverUrl)
                if !Task.isCancelled {
                    showFeedback("已选择字幕: \(subtitle.label)")
                }
            } catch is CancellationError {
                // 用户已切换到别的字幕或关闭字幕，无需提示。
            } catch {
                if !Task.isCancelled {
                    selectedSubtitleId = nil
                    playerController.clearSubtitle()
                    showFeedback("字幕加载失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(Color(hex: "#E8B06A"))

                Text("播放失败")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#B8C0CF"))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)

                HStack(spacing: 12) {
                    Button("重试") {
                        restartPlayback()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(Color(hex: "#E8B06A"))
                    .foregroundColor(Color(hex: "#07080A"))
                    .fontWeight(.semibold)
                    .cornerRadius(8)

                    Button("关闭") {
                        handleClose()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(Color(hex: "#1E222D"))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .background(Color(hex: "#14161C").opacity(0.98))
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.5), radius: 20)
            .padding(32)
        }
    }

    // MARK: - 自动连播下一集过渡

    private var autoNextEpisodeOverlay: some View {
        VStack(spacing: 12) {
            Text("即将播放下一集")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#8A93A5"))

            Text(playInfo.nextTitle ?? "下一集")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)

            Text("\(autoNextCountdown) 秒后自动连播...")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#E8B06A"))

            HStack(spacing: 16) {
                Button("取消") {
                    cancelAutoNext()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "#1E222D"))
                .foregroundColor(.white)
                .cornerRadius(6)

                Button("立即播放") {
                    triggerAutoNext()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "#E8B06A"))
                .foregroundColor(Color(hex: "#07080A"))
                .fontWeight(.semibold)
                .cornerRadius(6)
            }
        }
        .padding(24)
        .background(Color(hex: "#14161C").opacity(0.95))
        .cornerRadius(12)
        .shadow(radius: 10)
    }

    // MARK: - 控制与生命周期

    private func setupInitialState() {
        configureAudioSession()
        setupNowPlayingInfo()
        setupRemoteCommands()

        playerController.onPlaybackEnded = {
            self.handleVideoFinished()
        }

        if let videoUrl = URL(string: playInfo.playUrl) {
            playerController.setup(
                url: videoUrl,
                headers: playInfo.safeHeaders,
                resumeMs: playInfo.resumeMs,
                cacheLimitMb: playInfo.safeCacheLimitMb
            )
        }

        startHeartbeat()
        resetControlsTimer()
        startLoadingTimeoutTimer()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PlayerView] 音频会话配置失败: \(error)")
        }
    }

    private func setupNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = playInfo.title
        if let sTitle = playInfo.seriesTitle {
            info[MPMediaItemPropertyArtist] = sTitle
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(playerController.currentPositionMs) / 1000.0
        info[MPMediaItemPropertyPlaybackDuration] = Double(playerController.durationMs) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playerController.isPlaying ? playerController.playbackSpeed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        removeRemoteCommands()

        let center = MPRemoteCommandCenter.shared()
        var registrations: [RemoteRegistration] = []

        let playToken = center.playCommand.addTarget { _ in
            self.playerController.play()
            self.setupNowPlayingInfo()
            return .success
        }
        registrations.append(RemoteRegistration(command: center.playCommand, token: playToken))

        let pauseToken = center.pauseCommand.addTarget { _ in
            self.playerController.pause()
            self.setupNowPlayingInfo()
            return .success
        }
        registrations.append(RemoteRegistration(command: center.pauseCommand, token: pauseToken))

        let toggleToken = center.togglePlayPauseCommand.addTarget { _ in
            self.playerController.togglePlayPause()
            self.setupNowPlayingInfo()
            return .success
        }
        registrations.append(RemoteRegistration(command: center.togglePlayPauseCommand, token: toggleToken))

        center.skipForwardCommand.preferredIntervals = [10]
        let forwardToken = center.skipForwardCommand.addTarget { _ in
            self.playerController.skip(seconds: 10)
            self.setupNowPlayingInfo()
            return .success
        }
        registrations.append(RemoteRegistration(command: center.skipForwardCommand, token: forwardToken))

        center.skipBackwardCommand.preferredIntervals = [10]
        let backwardToken = center.skipBackwardCommand.addTarget { _ in
            self.playerController.skip(seconds: -10)
            self.setupNowPlayingInfo()
            return .success
        }
        registrations.append(RemoteRegistration(command: center.skipBackwardCommand, token: backwardToken))

        let positionToken = center.changePlaybackPositionCommand.addTarget { event in
            if let posEvent = event as? MPChangePlaybackPositionCommandEvent {
                self.playerController.seek(toMs: Int64(posEvent.positionTime * 1000))
                self.setupNowPlayingInfo()
                return .success
            }
            return .commandFailed
        }
        registrations.append(RemoteRegistration(command: center.changePlaybackPositionCommand, token: positionToken))

        remoteRegistrations = registrations
    }

    private func removeRemoteCommands() {
        for registration in remoteRegistrations {
            registration.command.removeTarget(registration.token)
        }
        remoteRegistrations.removeAll()
    }

    private func startLoadingTimeoutTimer() {
        loadingTimeoutTimer?.invalidate()
        loadingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
            if !self.playerController.isReady && self.playerController.errorMessage == nil {
                self.showTimeoutAlert = true
            }
        }
    }

    private func handleVideoFinished() {
        sendProgress(finished: true)
        if hasNextEpisode {
            autoNextCountdown = 3
            showAutoNextOverlay = true
            autoNextTimer?.invalidate()
            autoNextTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                if self.autoNextCountdown > 1 {
                    self.autoNextCountdown -= 1
                } else {
                    self.triggerAutoNext()
                }
            }
        }
    }

    private func triggerAutoNext() {
        cancelAutoNext()
        playNextEpisode()
    }

    private func cancelAutoNext() {
        autoNextTimer?.invalidate()
        autoNextTimer = nil
        showAutoNextOverlay = false
    }

    private var hasNextEpisode: Bool {
        if playInfo.nextItemId != nil { return true }
        let playlist = playInfo.safePlaylist
        if let idx = playlist.firstIndex(where: { $0.id == playInfo.itemId }), idx + 1 < playlist.count {
            return true
        }
        return false
    }

    private var hasPreviousEpisode: Bool {
        let playlist = playInfo.safePlaylist
        if let idx = playlist.firstIndex(where: { $0.id == playInfo.itemId }), idx > 0 {
            return true
        }
        return false
    }

    private func playNextEpisode() {
        if let nextId = playInfo.nextItemId {
            sendProgress(finished: false)
            onSelectEpisode(nextId)
            return
        }
        let playlist = playInfo.safePlaylist
        if let idx = playlist.firstIndex(where: { $0.id == playInfo.itemId }), idx + 1 < playlist.count {
            sendProgress(finished: false)
            onSelectEpisode(playlist[idx + 1].id)
        }
    }

    private func playPreviousEpisode() {
        let playlist = playInfo.safePlaylist
        if let idx = playlist.firstIndex(where: { $0.id == playInfo.itemId }), idx > 0 {
            sendProgress(finished: false)
            onSelectEpisode(playlist[idx - 1].id)
        }
    }

    private func restartPlayback() {
        showTimeoutAlert = false
        if let videoUrl = URL(string: playInfo.playUrl) {
            playerController.setup(
                url: videoUrl,
                headers: playInfo.safeHeaders,
                resumeMs: playerController.currentPositionMs,
                cacheLimitMb: playInfo.safeCacheLimitMb
            )
            startLoadingTimeoutTimer()
        }
    }

    private func openExternalPlayer() {
        let encoded = playInfo.playUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playInfo.playUrl
        if let infuseUrl = URL(string: "infuse://x-callback-url/play?url=\(encoded)"), UIApplication.shared.canOpenURL(infuseUrl) {
            UIApplication.shared.open(infuseUrl)
        } else if let vlcUrl = URL(string: "vlc://\(playInfo.playUrl)"), UIApplication.shared.canOpenURL(vlcUrl) {
            UIApplication.shared.open(vlcUrl)
        } else {
            UIPasteboard.general.string = playInfo.playUrl
            showFeedback("未检测到 Infuse/VLC，已复制直链")
        }
    }

    private func toggleControls() {
        withAnimation {
            isControlsVisible.toggle()
        }
        if isControlsVisible {
            resetControlsTimer()
        }
    }

    private func resetControlsTimer() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { _ in
            withAnimation {
                self.isControlsVisible = false
            }
        }
    }

    private func dismissAllDrawers() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showEpisodesDrawer = false
            showSpeedDrawer = false
            showMoreSettingsDrawer = false
        }
    }

    private func triggerLongPressSpeed(_ enable: Bool) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        withAnimation {
            isFastForwarding = enable
        }
        if enable {
            originalSpeedBeforeFast = playerController.playbackSpeed
            playerController.setSpeed(longPressSpeed)
        } else {
            playerController.setSpeed(originalSpeedBeforeFast)
        }
    }

    private func showFeedback(_ text: String) {
        withAnimation {
            feedbackText = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if self.feedbackText == text {
                withAnimation {
                    self.feedbackText = nil
                }
            }
        }
    }

    private func handleClose() {
        sendProgress(finished: false)
        cleanup()
        onClose()
    }

    private func startHeartbeat() {
        let interval = Double(playInfo.safeProgressIntervalMs) / 1000.0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            if self.playerController.isPlaying {
                self.sendProgress(finished: false)
                self.setupNowPlayingInfo()
            }
        }
    }

    private func sendProgress(finished: Bool) {
        ProgressEngine.shared.report(
            serverUrl: serverUrl,
            itemId: playInfo.itemId,
            playToken: playInfo.playToken,
            positionMs: playerController.currentPositionMs,
            durationMs: playerController.durationMs,
            finished: finished
        )
    }

    private func cleanup() {
        heartbeatTimer?.invalidate()
        hideControlsTimer?.invalidate()
        loadingTimeoutTimer?.invalidate()
        autoNextTimer?.invalidate()
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        playerController.destroy()
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func formatTime(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
