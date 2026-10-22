import SwiftUI

// MARK: - 顶部栏

struct PlayerTopBar: View {
    let title: String
    @ObservedObject var player: VideoPlayerController
    @ObservedObject var ui: PlayerUIController

    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            PlayerIconButton(
                systemName: "chevron.left",
                iconSize: 19,
                accessibilityLabel: "返回",
                action: {
                    if ui.activeDrawer != nil {
                        ui.closeDrawer()
                    } else {
                        onClose()
                    }
                    ui.resetAutoHide()
                }
            )

            Text(title)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(PlayerTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)

            Spacer(minLength: 8)

            PlayerIconButton(
                systemName: player.isAspectFill ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward",
                iconSize: 16,
                accessibilityLabel: "画面比例",
                action: {
                    player.toggleAspect()
                    ui.showToast(player.isAspectFill ? "铺满画面" : "适应画面")
                    ui.resetAutoHide()
                }
            )

            if player.isPiPAvailable {
                PlayerIconButton(
                    systemName: player.isPiPActive ? "pip.exit" : "pip.enter",
                    iconSize: 17,
                    isActive: player.isPiPActive,
                    accessibilityLabel: "画中画",
                    action: {
                        let success = player.togglePiP()
                        ui.showToast(success
                                     ? (player.isPiPActive ? "已开启画中画" : "已退出画中画")
                                     : "当前设备不支持画中画")
                        ui.resetAutoHide()
                    }
                )
            }

            PlayerIconButton(
                systemName: "ellipsis",
                iconSize: 18,
                accessibilityLabel: "更多设置",
                action: {
                    ui.openDrawer(.menu)
                }
            )
        }
        .padding(PlayerTheme.topBarPadding)
        .frame(height: 56)
    }
}

// MARK: - 底部栏

struct PlayerBottomBar: View {
    let playInfo: PlayResponse
    @ObservedObject var player: VideoPlayerController
    @ObservedObject var ui: PlayerUIController

    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    /// 拖动时显示预瞄位置，否则显示真实播放位置。
    private var displayedPositionMs: Int64 {
        ui.scrubPreviewMs ?? player.currentPositionMs
    }

    private var isPreviewing: Bool {
        ui.scrubPreviewMs != nil
    }

    var body: some View {
        VStack(spacing: 6) {
            BufferedSeekBar(
                currentMs: displayedPositionMs,
                durationMs: player.durationMs,
                cachedSegments: player.cachedSegments,
                onSeek: { target in
                    player.seek(toMs: target)
                    ui.resetAutoHide()
                },
                onScrubbingChanged: { scrubbing, ms in
                    ui.setBarScrubbing(scrubbing)
                    if scrubbing {
                        ui.updateBarScrubPreview(ms)
                    }
                }
            )

            HStack(spacing: 10) {
                PlayerIconButton(
                    systemName: player.isPlaying ? "pause.fill" : "play.fill",
                    size: PlayerTheme.actionButtonSize,
                    iconSize: 17,
                    accessibilityLabel: player.isPlaying ? "暂停" : "播放",
                    action: { ui.togglePlayPause() }
                )

                PlayerIconButton(
                    systemName: "backward.end.fill",
                    size: PlayerTheme.actionButtonSize,
                    iconSize: 14,
                    isEnabled: hasPrevious,
                    accessibilityLabel: "上一集",
                    action: onPrevious
                )

                PlayerIconButton(
                    systemName: "forward.end.fill",
                    size: PlayerTheme.actionButtonSize,
                    iconSize: 14,
                    isEnabled: hasNext,
                    accessibilityLabel: "下一集",
                    action: onNext
                )

                // 网速来自缓存层的回源统计：FFmpeg 只连本机，它看不到真实下载速度。
                HStack(spacing: 6) {
                    timeLabel
                    if player.isDownloading {
                        Text(PlayerTimeFormat.networkSpeed(bytesPerSecond: player.networkSpeedBps))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(PlayerTheme.textMuted)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if !playInfo.safePlaylist.isEmpty {
                    PlayerPillButton(
                        title: "选集",
                        isActive: ui.isDrawerOpen(.episodes),
                        action: {
                            ui.openDrawer(.episodes)
                        }
                    )
                }

                PlayerPillButton(
                    title: abs(player.playbackSpeed - 1.0) < 0.001
                        ? "倍速"
                        : PlayerTimeFormat.speed(player.playbackSpeed),
                    isActive: ui.isDrawerOpen(.speed),
                    action: {
                        ui.openDrawer(.speed)
                    }
                )

                PlayerIconButton(
                    systemName: ui.isFullscreen
                        ? "arrow.down.forward.and.arrow.up.backward"
                        : "arrow.up.left.and.arrow.down.right",
                    size: PlayerTheme.actionButtonSize,
                    iconSize: 16,
                    isActive: ui.isFullscreen,
                    accessibilityLabel: ui.isFullscreen ? "退出全屏" : "全屏",
                    action: { ui.toggleFullscreen() }
                )
            }
        }
        .padding(PlayerTheme.bottomBarPadding)
    }

    /// 拖动时复刻 Android 的文案：显示目标时间 + 缓冲状态，方便判断拖过去会不会卡。
    private var timeLabel: some View {
        Group {
            if isPreviewing {
                Text("\(PlayerTimeFormat.string(ms: displayedPositionMs)) · \(displayedPositionMs <= player.bufferedPositionMs ? "已缓冲" : "缓冲中")")
                    .foregroundStyle(
                        displayedPositionMs <= player.bufferedPositionMs
                            ? PlayerTheme.textSecondary
                            : PlayerTheme.accent
                    )
            } else {
                Text("\(PlayerTimeFormat.string(ms: player.currentPositionMs)) / \(PlayerTimeFormat.string(ms: player.durationMs))")
                    .foregroundStyle(PlayerTheme.textMuted)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.leading, 2)
    }
}

// MARK: - 中心播放按钮

struct PlayerCenterButton: View {
    @ObservedObject var player: VideoPlayerController
    @ObservedObject var ui: PlayerUIController

    var body: some View {
        Button {
            ui.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: PlayerTheme.centerButtonSize, height: PlayerTheme.centerButtonSize)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .offset(x: player.isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
    }
}

// MARK: - 锁定按钮

/// 锁定入口：随控件一起显隐，悬浮在右侧垂直居中。
struct PlayerLockEntryButton: View {
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.38))
                    .frame(width: 38, height: 38)
                Image(systemName: "lock.open")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
        }
        .buttonStyle(.plain)
        .frame(width: 46, height: 46)
        .contentShape(Circle())
        .accessibilityLabel("锁定屏幕")
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

/// 解锁按钮：锁定后唯一可见的控件，3 秒无操作自动淡出，轻点画面可再次唤出。
struct PlayerLockButton: View {
    @ObservedObject var ui: PlayerUIController

    var body: some View {
        Button {
            ui.toggleLock()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: PlayerTheme.lockButtonSize, height: PlayerTheme.lockButtonSize)
                Image(systemName: "lock.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 60, height: 60)
        .contentShape(Circle())
        .transition(.opacity)
        .accessibilityLabel("解锁")
    }
}