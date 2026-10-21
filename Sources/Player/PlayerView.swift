import SwiftUI
import AVFoundation

public struct PlayerView: View {
    public let playInfo: PlayResponse
    public let serverUrl: String
    public var onClose: () -> Void
    public var onSelectEpisode: (Int) -> Void

    // 播放状态
    @State private var isPlaying: Bool = true
    @State private var currentPositionMs: Int64 = 0
    @State private var durationMs: Int64 = 0
    @State private var currentSpeed: Double = 1.0
    @State private var isControlsVisible: Bool = true
    @State private var showEpisodesDrawer: Bool = false
    @State private var showSpeedDrawer: Bool = false
    @State private var isFastForwarding: Bool = false
    @State private var feedbackText: String? = nil

    // 定时器
    @State private var heartbeatTimer: Timer?
    @State private var hideControlsTimer: Timer?

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

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
                // 1. 底层：视频画面背景（由播放引擎图层渲染）
                Color.black.ignoresSafeArea()

                // 占位/实际播放内核图层（如 KSPlayerView 封装）
                VStack {
                    Spacer()
                    Text("播放直链: \(playInfo.playUrl)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .padding(.horizontal)
                    Spacer()
                }

                // 2. 长按快速倍速提示
                if isFastForwarding {
                    VStack {
                        HStack(spacing: 6) {
                            Image(systemName: "forward.fill")
                            Text("2.0x 快速播放中")
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .transition(.scale)
                }

                // 4. 手势交互层
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleControls()
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4)
                            .onEnded { _ in
                                triggerLongPressSpeed(true)
                            }
                    )

                // 5. 控制层（TopBar, CenterButton, BottomBar）
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

                // 6. 40% 右侧侧滑抽屉（选集 / 倍速）
                if showEpisodesDrawer || showSpeedDrawer {
                    HStack(spacing: 0) {
                        // 左侧 60% 遮罩区域，点击收起
                        Color.black.opacity(0.5)
                            .frame(width: geometry.size.width * 0.6)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showEpisodesDrawer = false
                                    showSpeedDrawer = false
                                }
                            }

                        // 右侧 40% 抽屉内容区
                        ZStack {
                            Color(hex: "#14161C").opacity(0.98)
                            if showEpisodesDrawer {
                                episodesDrawerView
                            } else if showSpeedDrawer {
                                speedDrawerView
                            }
                        }
                        .frame(width: geometry.size.width * 0.4)
                    }
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .onAppear {
            setupInitialState()
        }
        .onDisappear {
            cleanup()
        }
    }

    // MARK: - 子视图组件

    private var topBar: some View {
        HStack {
            Button(action: handleClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
            }

            Text(playInfo.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            Button(action: { /* 画中画切换 */ }) {
                Image(systemName: "pip.enter")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .padding(8)
            }

            Button(action: {
                withAnimation { showEpisodesDrawer = false; showSpeedDrawer.toggle() }
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .padding(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var centerButton: some View {
        Button(action: togglePlayPause) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 64, height: 64)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // 进度条
            Slider(
                value: Binding(
                    get: { Double(currentPositionMs) },
                    set: { currentPositionMs = Int64($0) }
                ),
                in: 0...Double(max(1, durationMs))
            )
            .tint(Color(hex: "#E8B06A"))

            HStack {
                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                }

                Text("\(formatTime(currentPositionMs)) / \(formatTime(durationMs))")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#8A93A5"))

                Spacer()

                Button("选集") {
                    withAnimation { showSpeedDrawer = false; showEpisodesDrawer.toggle() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(showEpisodesDrawer ? Color(hex: "#E8B06A") : .white)
                .padding(.horizontal, 6)

                Button("\(String(format: "%.1fx", currentSpeed))") {
                    withAnimation { showEpisodesDrawer = false; showSpeedDrawer.toggle() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(showSpeedDrawer ? Color(hex: "#E8B06A") : .white)
                .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var episodesDrawerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选集")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 20)
                .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(playInfo.playlist) { ep in
                        Button(action: {
                            withAnimation { showEpisodesDrawer = false }
                            onSelectEpisode(ep.id)
                        }) {
                            HStack {
                                if ep.current {
                                    Image(systemName: "play.fill")
                                        .font(.caption2)
                                        .foregroundColor(Color(hex: "#E8B06A"))
                                }
                                Text(ep.displayLabel)
                                    .font(.system(size: 13))
                                    .foregroundColor(ep.current ? Color(hex: "#E8B06A") : .white)
                                    .lineLimit(1)
                                Spacer()
                                if ep.watched {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .foregroundColor(Color(hex: "#8A93A5"))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(ep.current ? Color(hex: "#1E222D") : Color.clear)
                            .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var speedDrawerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放速度")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 20)
                .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(speeds, id: \.self) { sp in
                        Button(action: {
                            currentSpeed = sp
                            withAnimation { showSpeedDrawer = false }
                        }) {
                            HStack {
                                Text("\(String(format: "%.2fx", sp))")
                                    .font(.system(size: 14))
                                    .foregroundColor(currentSpeed == sp ? Color(hex: "#E8B06A") : .white)
                                Spacer()
                                if currentSpeed == sp {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundColor(Color(hex: "#E8B06A"))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(currentSpeed == sp ? Color(hex: "#1E222D") : Color.clear)
                            .cornerRadius(6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 逻辑控制

    private func setupInitialState() {
        currentPositionMs = playInfo.resumeMs
        durationMs = playInfo.durationMs ?? 0
        startHeartbeat()
        resetControlsTimer()
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

    private func togglePlayPause() {
        isPlaying.toggle()
        sendProgress(finished: false)
    }

    private func triggerLongPressSpeed(_ enable: Bool) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        withAnimation {
            isFastForwarding = enable
        }
    }

    private func handleClose() {
        sendProgress(finished: false)
        cleanup()
        onClose()
    }

    private func startHeartbeat() {
        let interval = Double(playInfo.progressIntervalMs) / 1000.0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            if isPlaying {
                currentPositionMs += Int64(interval * 1000)
                sendProgress(finished: false)
            }
        }
    }

    private func sendProgress(finished: Bool) {
        ProgressEngine.shared.report(
            serverUrl: serverUrl,
            itemId: playInfo.itemId,
            playToken: playInfo.playToken,
            positionMs: currentPositionMs,
            durationMs: durationMs,
            finished: finished
        )
    }

    private func cleanup() {
        heartbeatTimer?.invalidate()
        hideControlsTimer?.invalidate()
    }

    private func formatTime(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
