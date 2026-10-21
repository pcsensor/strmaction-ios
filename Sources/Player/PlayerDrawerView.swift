import SwiftUI

// MARK: - 抽屉外壳

/// 右侧抽屉面板。
///
/// 针对旧版「面板丑陋 / 边界不清 / 整个画面变暗」三个问题做了三处结构性修改：
/// 1. 遮罩改为**方向性渐变**（左 10% → 右 55%），视频主体基本保持可见，
///    不再像原来那样整屏压 53% 黑；点任意处仍可关闭。
/// 2. 面板改为**实色 + 左侧投影 + 发丝描边**，与遮罩之间有明确的高差边界。
/// 3. 只有朝向视频的一侧（左）带圆角，贴屏幕右缘的一侧为直角，与屏幕严丝合缝。
struct PlayerDrawerView<Content: View>: View {
    let drawer: PlayerDrawer
    let subtitle: String?
    let containerSize: CGSize
    let onClose: () -> Void
    let onBack: (() -> Void)?
    @ViewBuilder let content: () -> Content

    /// 横屏 40% 屏宽，竖屏 70% 但不小于 300pt（与 Android 一致）。
    private var panelWidth: CGFloat {
        guard containerSize.width > 0, containerSize.height > 0 else { return 300 }
        if containerSize.width > containerSize.height {
            return containerSize.width * 0.40
        }
        return max(300, containerSize.width * 0.70)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 方向性遮罩：越靠近面板越暗，视频主体基本不受影响。
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(PlayerTheme.drawerScrimOpacity * 0.30), location: 0.0),
                    .init(color: .black.opacity(PlayerTheme.drawerScrimOpacity * 0.58), location: 0.55),
                    .init(color: .black.opacity(PlayerTheme.drawerScrimOpacity), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)

            panel
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(PlayerTheme.hairline)
                .frame(height: 1)
            content()
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            LeadingRoundedRectangle(radius: PlayerTheme.drawerCornerRadius, corners: .top)
                .fill(PlayerTheme.panel)
        }
        // 左侧投影 + 发丝描边，制造清晰的浮起层次（旧版完全没有，是边界不清的根因）。
        // 注意：strokeBorder 只在 InsettableShape（RoundedRectangle / Capsule）上有，
        // 自定义 Shape 只能用 stroke。
        .overlay {
            LeadingRoundedRectangle(radius: PlayerTheme.drawerCornerRadius, corners: .top)
                .stroke(PlayerTheme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 26, x: -10, y: 0)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let onBack {
                PlayerIconButton(
                    systemName: "chevron.left",
                    size: 34,
                    iconSize: 16,
                    accessibilityLabel: "返回",
                    action: onBack
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(drawer.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(PlayerTheme.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PlayerTheme.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PlayerIconButton(
                systemName: "xmark",
                size: 34,
                iconSize: 14,
                accessibilityLabel: "关闭",
                action: onClose
            )
        }
        .padding(.horizontal, PlayerTheme.drawerSidePadding)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }
}

// MARK: - 行组件

/// 带图标的导航行（点进去还有下一级）。
struct PlayerDrawerNavRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PlayerTheme.accent)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PlayerTheme.textPrimary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(PlayerTheme.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: PlayerTheme.drawerItemRadius, style: .continuous)
                    .fill(PlayerTheme.itemBackground)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 带图标的操作行（点击立即执行，没有下一级）。
struct PlayerDrawerActionRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = PlayerTheme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint == PlayerTheme.textPrimary ? PlayerTheme.accent : tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(PlayerTheme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: PlayerTheme.drawerItemRadius, style: .continuous)
                    .fill(PlayerTheme.itemBackground)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 单选行（倍速 / 字幕 / 选集）。
struct PlayerDrawerSelectionRow: View {
    let title: String
    var leadingIcon: String? = nil
    var badge: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PlayerTheme.accent)
                        .frame(width: 18)
                }
                Text(title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? PlayerTheme.accent : PlayerTheme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if let badge {
                    Text(badge.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(PlayerTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(PlayerTheme.accentSofter)
                        }
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PlayerTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: PlayerTheme.drawerItemRadius, style: .continuous)
                    .fill(isSelected ? PlayerTheme.accentSoft : PlayerTheme.itemBackground)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 分组小标题。
struct PlayerDrawerSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(PlayerTheme.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }
}
// MARK: - 面板内容

/// 根据当前抽屉类型渲染对应内容。所有状态变化都直接反映在行内，
/// 不再往屏幕中央弹 Toast（那会被面板挡住）。
struct PlayerDrawerContent: View {
    let drawer: PlayerDrawer
    let playInfo: PlayResponse
    @ObservedObject var player: VideoPlayerController
    @ObservedObject var ui: PlayerUIController
    let selectedSubtitleId: String?

    let onSelectSubtitle: (SubtitleEntry?) -> Void
    let onSelectEpisode: (Int) -> Void
    let onExternalPlayer: () -> Void
    let onCopyLink: () -> Void

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
    private let longPressSpeeds: [Double] = [1.5, 2.0, 2.5, 3.0]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                switch drawer {
                case .menu: menuRows
                case .episodes: episodeRows
                case .speed: speedRows
                case .subtitles: subtitleRows
                }
            }
            .padding(.horizontal, PlayerTheme.drawerSidePadding)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
    }

    // MARK: 主菜单

    @ViewBuilder
    private var menuRows: some View {
        PlayerDrawerNavRow(
            icon: "captions.bubble",
            title: "字幕",
            subtitle: playInfo.safeSubtitles.isEmpty
                ? "无可用字幕"
                : "\(playInfo.safeSubtitles.count) 条可选"
        ) {
            ui.pushDrawer(.subtitles)
        }

        PlayerDrawerNavRow(
            icon: "speedometer",
            title: "播放速度",
            subtitle: abs(player.playbackSpeed - 1.0) < 0.001
                ? "正常 (1.0x)"
                : PlayerTimeFormat.speed(player.playbackSpeed)
        ) {
            ui.pushDrawer(.speed)
        }

        PlayerDrawerActionRow(
            icon: player.isAspectFill ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward",
            title: "画面比例",
            subtitle: player.isAspectFill ? "铺满画面" : "适应画面"
        ) {
            player.toggleAspect()
            ui.resetAutoHide()
        }

        PlayerDrawerActionRow(
            icon: "internaldrive",
            title: "播放缓存",
            subtitle: "\(playInfo.safeCacheLimitMb) MB · 已缓冲 \(PlayerTimeFormat.string(ms: player.bufferedPositionMs))"
        ) {}

        if playInfo.nextItemId != nil || playInfo.nextTitle != nil {
            PlayerDrawerActionRow(
                icon: "forward.end",
                title: "下一集",
                subtitle: playInfo.nextTitle ?? "立即播放"
            ) {
                if let nextId = playInfo.nextItemId {
                    ui.closeDrawer(animated: false)
                    onSelectEpisode(nextId)
                }
            }
        }

        PlayerDrawerActionRow(
            icon: "arrow.up.forward.app",
            title: "用外部播放器打开",
            subtitle: "Infuse / VLC"
        ) {
            onExternalPlayer()
            ui.closeDrawer()
        }

        PlayerDrawerActionRow(
            icon: "doc.on.doc",
            title: "复制视频直链",
            tint: PlayerTheme.accent
        ) {
            onCopyLink()
            ui.closeDrawer()
        }
    }

    // MARK: 选集

    @ViewBuilder
    private var episodeRows: some View {
        if playInfo.safePlaylist.isEmpty {
            emptyHint("该片源没有选集信息")
        } else {
            ForEach(playInfo.safePlaylist) { item in
                let isCurrent = item.id == playInfo.itemId || item.isCurrent
                PlayerDrawerSelectionRow(
                    title: item.displayLabel,
                    leadingIcon: isCurrent ? "play.fill" : nil,
                    isSelected: isCurrent
                ) {
                    if item.id != playInfo.itemId {
                        ui.closeDrawer(animated: false)
                        onSelectEpisode(item.id)
                    }
                }
            }
        }
    }

    // MARK: 倍速

    @ViewBuilder
    private var speedRows: some View {
        PlayerDrawerSectionHeader(text: "常规倍速")

        ForEach(speeds, id: \.self) { speed in
            PlayerDrawerSelectionRow(
                title: speed == 1.0 ? "1.0x　标准" : PlayerTimeFormat.speed(speed),
                isSelected: abs(player.playbackSpeed - speed) < 0.001
            ) {
                ui.setSpeed(speed)
                ui.closeDrawer()
            }
        }

        PlayerDrawerSectionHeader(text: "长按加速（按住画面时）")

        ForEach(longPressSpeeds, id: \.self) { speed in
            PlayerDrawerSelectionRow(
                title: PlayerTimeFormat.speed(speed),
                isSelected: abs(ui.longPressSpeed - speed) < 0.001
            ) {
                ui.commitLongPressSpeed(speed)
            }
        }
    }

    // MARK: 字幕

    @ViewBuilder
    private var subtitleRows: some View {
        if playInfo.safeSubtitles.isEmpty {
            emptyHint("该片源没有外挂字幕")
        } else {
            PlayerDrawerSelectionRow(
                title: "关闭字幕",
                leadingIcon: "captions.bubble",
                isSelected: selectedSubtitleId == nil
            ) {
                onSelectSubtitle(nil)
                ui.closeDrawer()
            }

            PlayerDrawerSectionHeader(text: "可用字幕 \(playInfo.safeSubtitles.count) 条")

            ForEach(playInfo.safeSubtitles) { subtitle in
                PlayerDrawerSelectionRow(
                    title: subtitle.label,
                    badge: subtitle.format,
                    isSelected: selectedSubtitleId == subtitle.id
                ) {
                    onSelectSubtitle(subtitle)
                    ui.closeDrawer()
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(PlayerTheme.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }
}
