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

    // 播放内核
    @StateObject private var playerController = VideoPlayerController()
    // 界面状态机（控件显隐 / 锁定 / 全屏 / 面板 / 浮层 / 手势仲裁 / 定时器）
    @StateObject private var ui = PlayerUIController()

    // 字幕
    @State private var selectedSubtitleId: String?
    @State private var subtitleLoadTask: Task<Void, Never>?

    // 自动连播
    @State private var autoNextCountdown = 3
    @State private var showAutoNextOverlay = false

    // 手势
    @State private var dragBegan = false

    // 临时诊断面板
    @State private var showDiagnostics = false
    /// 证书信任管理面板
    @State private var showTrust = false

    // 定时器与远程控制注册
    @State private var heartbeatTimer: Timer?
    @State private var autoNextTimer: Timer?
    @State private var remoteRegistrations: [RemoteRegistration] = []
    /// 装载任务。切换播放源时取消上一个，避免两路 load 互相覆盖状态。
    @State private var loadTask: Task<Void, Never>?

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

    // MARK: - 派生状态

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

    private var isInitialLoading: Bool {
        switch playerController.phase {
        case .resolving, .pinning, .connecting, .buffering:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    /// 播放失败的原始原因。由引擎的 `phase` 单一来源提供，不再另设标志位。
    private var failureReason: String? {
        if case .failed(let reason) = playerController.phase { return reason }
        return nil
    }

    private var playbackRequest: PlaybackRequest? {
        PlaybackRequest(playInfo: playInfo)
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 1. 视频画面
                Color.black.ignoresSafeArea()
                if let videoUrl = URL(string: playInfo.playUrl) {
                    VideoSurfaceView(
                        controller: playerController,
                        url: videoUrl,
                        resumeMs: playInfo.resumeMs
                    )
                }

                // 2. 手势层。必须在控件层**之下**，否则这层全屏 Color.clear
                //    会抢走所有按钮的点击（这是「控件点了没反应」的典型成因）。
                gestureLayer(size: geometry.size)

                // 3. 外挂字幕渲染层。排在控件层之前，保证控件压在字幕之上。
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

                // 4. 控件层（渐变遮罩 + 顶栏 / 中心键 / 底栏 / 锁定入口）
                chrome

                // 5. 亮度遮罩：iOS 没有 per-window 亮度，用一层压暗替代，
                //    盖在控件之上、浮层之下，既不污染系统设置也能整体压暗。
                if ui.dimAmount > 0.002 {
                    Color.black
                        .opacity(ui.dimAmount)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: ui.dimAmount)
                }

                // 6. 瞬时反馈浮层（全部居中，不再跟随手指）
                if let speed = ui.speedBadge {
                    VStack(spacing: 0) {
                        PlayerSpeedBadgeView(speed: speed)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 88)
                    .allowsHitTesting(false)
                }

                if let badge = ui.centerBadge {
                    PlayerCenterBadgeView(badge: badge)
                        .id(badge.transitionKey)
                        .allowsHitTesting(false)
                }

                if isInitialLoading {
                    PlayerBufferingView()
                        .allowsHitTesting(false)
                }

                // 7. 锁定状态的解锁按钮（独立于控件层，始终压在亮度遮罩之上）
                if ui.isLocked && ui.isLockButtonVisible {
                    PlayerLockButton(ui: ui)
                        // .trailing 即「水平靠右、垂直居中」；SwiftUI 没有 .centerTrailing。
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 16)
                        .transition(.opacity)
                }

                // 8. 自动连播
                if showAutoNextOverlay {
                    PlayerAutoNextOverlay(
                        nextTitle: playInfo.nextTitle ?? "下一集",
                        countdown: autoNextCountdown,
                        onCancel: cancelAutoNext,
                        onPlayNow: triggerAutoNext
                    )
                }

                // 9. 播放错误：展示引擎给出的原始失败原因
                if let message = failureReason {
                    PlayerErrorOverlay(
                        message: message,
                        onRetry: retryLoad,
                        onClose: handleClose
                    )
                }

                // 10. 功能面板
                if let drawer = ui.activeDrawer {
                    drawerLayer(drawer, size: geometry.size)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        // 全屏时收起状态栏与 Home Indicator
        .persistentSystemOverlays(ui.isFullscreen ? .hidden : .automatic)
        .ignoresSafeArea(ui.isFullscreen ? .all : [])
        .onAppear(perform: setupInitialState)
        .onDisappear(perform: cleanup)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            sendProgress(finished: false)
        }
        .onReceive(playerController.$phase.removeDuplicates()) { phase in
            if phase == .ready {
                setupRemoteCommands()
            }
        }
        .onReceive(playerController.$isPlaying.removeDuplicates()) { _ in
            ui.playbackStateChanged()
        }
        .sheet(isPresented: $showDiagnostics) {
            PlayerDiagnosticsView()
        }
        .sheet(isPresented: $showTrust) {
            TrustManagementView()
        }
    }

    // MARK: - 控件层

    @ViewBuilder
    private var chrome: some View {
        if !ui.isLocked && ui.isControlsVisible && ui.activeDrawer == nil {
            ZStack {
                // 固定高度的顶 / 底渐变遮罩
                VStack(spacing: 0) {
                    PlayerChromeGradient(edge: .top)
                    Spacer()
                    PlayerChromeGradient(edge: .bottom)
                }
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    PlayerTopBar(
                        title: playInfo.fullDisplayTitle,
                        player: playerController,
                        ui: ui,
                        onClose: handleClose
                    )
                    Spacer(minLength: 0)
                    PlayerCenterButton(player: playerController, ui: ui)
                    Spacer(minLength: 0)
                    PlayerBottomBar(
                        playInfo: playInfo,
                        player: playerController,
                        ui: ui,
                        hasPrevious: hasPreviousEpisode,
                        hasNext: hasNextEpisode,
                        onPrevious: playPreviousEpisode,
                        onNext: playNextEpisode
                    )
                }
            }
            .overlay(alignment: .trailing) {
                // 锁定入口：悬浮在右侧垂直居中，随控件一起显隐
                PlayerLockEntryButton { ui.toggleLock() }
                    .padding(.trailing, 14)
            }
            .transition(.opacity)
        }
    }

    // MARK: - 手势层

    @ViewBuilder
    private func gestureLayer(size: CGSize) -> some View {
        if ui.isLocked {
            // 锁定态：只保留单击，用来唤出解锁按钮
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { ui.handleTapWhileLocked() }
        } else if ui.activeDrawer == nil {
            Color.clear
                .contentShape(Rectangle())
                .gesture(tapGesture(size: size))
                .highPriorityGesture(dragGesture(size: size))
                .onLongPressGesture(
                    minimumDuration: 0.35,
                    maximumDistance: PlayerTheme.dragSlop,
                    perform: { ui.setLongPressSpeed(true) },
                    onPressingChanged: { pressing in
                        if !pressing { ui.setLongPressSpeed(false) }
                    }
                )
        }
    }

    /// 单击切控件、双击分区快进快退。用 ExclusiveGesture 保证双击优先，
    /// 单击会等到双击判定窗口结束才触发——这是双击「点不动」的根因修复。
    private func tapGesture(size: CGSize) -> some Gesture {
        ExclusiveGesture(
            SpatialTapGesture(count: 2),
            SpatialTapGesture(count: 1)
        )
        .onEnded { value in
            switch value {
            case .first(let tap):
                let ratio = size.width > 0 ? Double(tap.location.x / size.width) : 0.5
                ui.handleDoubleTap(xRatio: ratio)
            case .second:
                ui.handleSingleTap()
            }
        }
    }

    /// 横向拖动 = 进度预瞄；纵向拖动 = 左亮度 / 右音量。
    /// 模式在首次越过死区时锁定，拖动过程中不会中途改判。
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: PlayerTheme.dragSlop)
            .onChanged { value in
                if !dragBegan {
                    dragBegan = true
                    ui.handleDragBegan(at: value.startLocation, in: size)
                }
                ui.handleDragChanged(value.translation, in: size)
            }
            .onEnded { _ in
                ui.handleDragEnded()
                dragBegan = false
            }
    }

    // MARK: - 功能面板

    private func drawerLayer(_ drawer: PlayerDrawer, size: CGSize) -> some View {
        PlayerDrawerView(
            drawer: drawer,
            subtitle: drawerSubtitle(drawer),
            containerSize: size,
            onClose: { ui.closeDrawer() },
            onBack: backAction(for: drawer)
        ) {
            PlayerDrawerContent(
                drawer: drawer,
                playInfo: playInfo,
                player: playerController,
                ui: ui,
                selectedSubtitleId: selectedSubtitleId,
                onSelectSubtitle: { selectSubtitle($0) },
                onSelectEpisode: { id in
                    sendProgress(finished: false)
                    onSelectEpisode(id)
                },
                onExternalPlayer: openExternalPlayer,
                onCopyLink: {
                    UIPasteboard.general.string = playInfo.playUrl
                    ui.showToast("播放直链已复制")
                },
                onShowDiagnostics: {
                    ui.closeDrawer(animated: false)
                    showDiagnostics = true
                },
                onShowTrust: {
                    ui.closeDrawer(animated: false)
                    showTrust = true
                }
            )
        }
    }

    private func backAction(for drawer: PlayerDrawer) -> (() -> Void)? {
        guard drawer.parent != nil else { return nil }
        return { ui.popDrawer() }
    }

    private func drawerSubtitle(_ drawer: PlayerDrawer) -> String? {
        switch drawer {
        case .menu:
            return playInfo.seriesTitle ?? playInfo.library
        case .episodes:
            return "共 \(playInfo.safePlaylist.count) 集"
        case .speed:
            return abs(playerController.playbackSpeed - 1.0) < 0.001
                ? "正常"
                : PlayerTimeFormat.speed(playerController.playbackSpeed)
        case .subtitles:
            return playInfo.safeSubtitles.isEmpty
                ? "无可用字幕"
                : "\(playInfo.safeSubtitles.count) 条可选"
        }
    }

    // MARK: - 字幕

    private func selectSubtitle(_ subtitle: SubtitleEntry?) {
        guard let subtitle else {
            selectedSubtitleId = nil
            subtitleLoadTask?.cancel()
            subtitleLoadTask = nil
            playerController.clearSubtitle()
            return
        }

        if selectedSubtitleId == subtitle.id {
            selectedSubtitleId = nil
            subtitleLoadTask?.cancel()
            subtitleLoadTask = nil
            playerController.clearSubtitle()
            ui.showToast("已关闭字幕")
            return
        }

        subtitleLoadTask?.cancel()
        selectedSubtitleId = subtitle.id

        subtitleLoadTask = Task { @MainActor in
            do {
                try await playerController.loadSubtitle(subtitle, serverUrl: serverUrl)
                guard !Task.isCancelled else { return }
                ui.showToast("已选择字幕：\(subtitle.label)")
            } catch is CancellationError {
                // 用户已切换到别的字幕或关闭字幕，无需提示。
            } catch {
                guard !Task.isCancelled else { return }
                selectedSubtitleId = nil
                playerController.clearSubtitle()
                ui.showToast("字幕加载失败")
            }
        }
    }

    // MARK: - 生命周期与控制

    private func setupInitialState() {
        D.log("view", "onAppear → setupInitialState itemId=\(playInfo.itemId)")
        ui.player = playerController
        configureAudioSession()
        setupNowPlayingInfo()
        setupRemoteCommands()

        playerController.onPlaybackEnded = { handleVideoFinished() }

        guard let request = playbackRequest else {
            playerController.reportUnplayableSource("服务端返回的播放地址无效")
            return
        }

        loadTask?.cancel()
        loadTask = Task { @MainActor in
            await playerController.load(request)
        }

        startHeartbeat()
        ui.showControls()
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
        if let seriesTitle = playInfo.seriesTitle {
            info[MPMediaItemPropertyArtist] = seriesTitle
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(playerController.currentPositionMs) / 1000.0
        info[MPMediaItemPropertyPlaybackDuration] = Double(playerController.durationMs) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playerController.isPlaying ? playerController.playbackSpeed : 0
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

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: PlayerTheme.skipIntervalSeconds)]
        let forwardToken = center.skipForwardCommand.addTarget { _ in
            self.playerController.skip(seconds: PlayerTheme.skipIntervalSeconds)
            self.setupNowPlayingInfo()
            return .success
        }
        registrations.append(RemoteRegistration(command: center.skipForwardCommand, token: forwardToken))

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlayerTheme.skipIntervalSeconds)]
        let backwardToken = center.skipBackwardCommand.addTarget { _ in
            self.playerController.skip(seconds: -PlayerTheme.skipIntervalSeconds)
            self.setupNowPlayingInfo()
            return .success
        }
        registrations.append(RemoteRegistration(command: center.skipBackwardCommand, token: backwardToken))

        let positionToken = center.changePlaybackPositionCommand.addTarget { event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                self.playerController.seek(toMs: Int64(positionEvent.positionTime * 1000))
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

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let interval = max(1.0, Double(playInfo.safeProgressIntervalMs) / 1000.0)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                guard self.playerController.isPlaying else { return }
                self.sendProgress(finished: false)
                self.setupNowPlayingInfo()
            }
        }
    }

    // MARK: - 选集

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

    // MARK: - 自动连播

    private func handleVideoFinished() {
        sendProgress(finished: true)
        guard hasNextEpisode else { return }
        autoNextCountdown = 3
        showAutoNextOverlay = true
        autoNextTimer?.invalidate()
        autoNextTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
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

    // MARK: - 错误与外部工具

    /// 用户主动重试。只在用户点击时触发，不存在自动重试或通道切换。
    private func retryLoad() {
        guard let url = URL(string: playInfo.playUrl) else {
            playerController.reportUnplayableSource("服务端返回的播放地址无效")
            return
        }
        let request = PlaybackRequest(
            url: url,
            headers: playInfo.safeHeaders,
            resumeMs: playerController.currentPositionMs,
            cacheLimitMb: playInfo.safeCacheLimitMb
        )
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            await playerController.load(request)
        }
    }

    private func openExternalPlayer() {
        let encoded = playInfo.playUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? playInfo.playUrl
        if let infuseURL = URL(string: "infuse://x-callback-url/play?url=\(encoded)"),
           UIApplication.shared.canOpenURL(infuseURL) {
            UIApplication.shared.open(infuseURL)
        } else if let vlcURL = URL(string: "vlc://\(playInfo.playUrl)"),
                  UIApplication.shared.canOpenURL(vlcURL) {
            UIApplication.shared.open(vlcURL)
        } else {
            UIPasteboard.general.string = playInfo.playUrl
            ui.showToast("未检测到 Infuse/VLC，已复制直链")
        }
    }

    private func handleClose() {
        sendProgress(finished: false)
        cleanup()
        onClose()
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
        D.log("view", "cleanup → 销毁播放会话")
        loadTask?.cancel()
        loadTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        autoNextTimer?.invalidate()
        autoNextTimer = nil
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        playerController.destroy()
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // 退出时如果停在全屏/锁定态，恢复成竖屏与正常亮度，避免下次进入是错的。
        ui.resetForNewEpisode()
        SystemOrientation.request(.all)
    }
}