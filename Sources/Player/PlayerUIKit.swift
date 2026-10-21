import SwiftUI
import UIKit

// MARK: - 设计令牌
//
// 与 Android 伴侣端 (companion) 保持同一套视觉语言：主强调色金橙 #E8B06A、
// 深色面板 #13161F、控件自动隐藏 4.5 秒。尺寸单位在 iOS 上直接使用 pt，
// 数值对齐 Android 的 dp（同一视觉尺度下 1dp ≈ 1pt）。

enum PlayerTheme {
    // 颜色
    static let accent = Color(hex: "#E8B06A")
    static let accentSoft = Color(hex: "#E8B06A").opacity(0.20)
    static let accentSofter = Color(hex: "#E8B06A").opacity(0.12)

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#D6DCE6")
    static let textMuted = Color(hex: "#9AA2B1")
    static let textFaint = Color(hex: "#7A8293")

    static let panel = Color(hex: "#13161F")
    static let panelRaised = Color(hex: "#1B1F2B")
    static let hairline = Color.white.opacity(0.10)

    static let trackUnplayed = Color.white.opacity(0.24)
    static let trackBuffered = Color.white.opacity(0.72)

    static let pillBackground = Color.white.opacity(0.16)
    static let itemBackground = Color.white.opacity(0.07)

    // 顶/底渐变遮罩
    static let topGradientColors: [Color] = [
        Color.black.opacity(0.82),
        Color.black.opacity(0.35),
        Color.clear
    ]
    static let bottomGradientColors: [Color] = [
        Color.clear,
        Color.black.opacity(0.55),
        Color.black.opacity(0.90)
    ]

    // 尺寸
    static let iconButtonSize: CGFloat = 40
    static let actionButtonSize: CGFloat = 36
    static let pillButtonHeight: CGFloat = 30
    static let centerButtonSize: CGFloat = 56
    static let lockButtonSize: CGFloat = 44
    static let seekBarHeight: CGFloat = 28
    static let seekTrackHeight: CGFloat = 5
    static let topBarPadding = EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12)
    static let bottomBarPadding = EdgeInsets(top: 6, leading: 14, bottom: 12, trailing: 14)
    static let topBarGradientHeight: CGFloat = 96
    static let bottomBarGradientHeight: CGFloat = 132

    // 抽屉
    static let drawerCornerRadius: CGFloat = 18
    static let drawerItemRadius: CGFloat = 12
    static let drawerSidePadding: CGFloat = 14
    /// 抽屉外的压暗遮罩。刻意比 Android 的 53% 更轻，避免“整个画面变暗”的廉价感。
    static let drawerScrimOpacity: Double = 0.34

    // 时长（秒）
    static let autoHideDelay: Double = 4.5
    static let lockButtonHideDelay: Double = 3.0
    static let lockFadeDuration: Double = 0.25
    static let badgeAutoDismiss: Double = 0.6
    static let toastDuration: Double = 1.4
    static let drawerOpenDuration: Double = 0.26
    static let drawerCloseDuration: Double = 0.20

    // 手势阈值
    static let doubleTapLeftZone: Double = 0.35
    static let doubleTapRightZone: Double = 0.65
    static let skipIntervalSeconds: Int64 = 10
    /// 横向滑动整屏可跨越的最大时长（与 Android 一致取 3 分钟）。
    static let scrubRangeMs: Int64 = 180_000    /// 纵向滑动灵敏度：上滑一个屏高对应 100% 变化。
    static let verticalSensitivity: Double = 1.0
    static let dragSlop: CGFloat = 14
}

// MARK: - 形状

/// 只有朝向视频的一侧（左）带圆角，贴屏幕右缘的一侧为直角。
/// 这样抽屉与屏幕边缘严丝合缝，只在“浮起”一侧产生柔和的转角。
struct LeadingRoundedRectangle: Shape {
    var radius: CGFloat = PlayerTheme.drawerCornerRadius
    /// 指定需要圆角的角（.leadingTop / .leadingBottom）
    var corners: VerticalEdge = .top

    func path(in rect: CGRect) -> Path {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        var path = Path()

        let roundTop = corners == .top
        let topRadius = roundTop ? r : 0
        let bottomRadius = roundTop ? 0 : r

        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        if topRadius > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.minY + topRadius),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius))
        if bottomRadius > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 系统方向

enum SystemOrientation {
    /// 请求窗口方向。iOS 16+ 的 `requestGeometryUpdate` 需要宿主 VC 同时声明支持该方向。
    static func request(_ mask: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            print("[Player] 屏幕方向切换失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 时间格式化

enum PlayerTimeFormat {
    /// 与 Android `PlayerUiHelper.formatTime` 一致：不足 1 小时用 mm:ss，否则 h:mm:ss。
    static func string(ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func speed(_ value: Double) -> String {
        // 整数倍速不显示小数尾巴，避免 "2.0x" 这种冗余写法。
        if abs(value.rounded() - value) < 0.001 {
            return String(format: "%.0fx", value)
        }
        return String(format: "%.2fx", value)
    }

    static func speedCompact(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.001 ? String(format: "%.0fx", value) : String(format: "%.1fx", value)
    }
}

// MARK: - 基础控件原子

/// 带按压反馈的图标按钮（对应 Android `iconButton` 的 borderless 水波纹）。
struct PlayerIconButton: View {
    let systemName: String
    var size: CGFloat = PlayerTheme.iconButtonSize
    var iconSize: CGFloat = 17
    var isEnabled: Bool = true
    var isActive: Bool = false
    var accessibilityLabel: String = ""
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.28))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .background {
                    // 仅在按压 / 激活时出现底色，静止状态保持视频画面干净。
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(Color.white.opacity(isPressed ? 0.18 : (isActive ? 0.14 : 0)))
                }
                .scaleEffect(isPressed ? 0.9 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isPressed)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(accessibilityLabel.isEmpty ? systemName : accessibilityLabel))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

/// 胶囊文字按钮（对应 Android `pillButton`，用于「选集」「倍速」）。
struct PlayerPillButton: View {
    let title: String
    var isEnabled: Bool = true
    var isActive: Bool = false
    var fontSize: CGFloat = 12.5
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(isEnabled ? (isActive ? PlayerTheme.accent : Color.white) : Color.white.opacity(0.3))
                .padding(.horizontal, 12)
                .frame(height: PlayerTheme.pillButtonHeight)
                .background {
                    Capsule().fill(isActive ? PlayerTheme.accentSoft : PlayerTheme.pillBackground)
                }
                .overlay {
                    Capsule().strokeBorder(
                        isActive ? PlayerTheme.accent.opacity(0.45) : Color.white.opacity(0.12),
                        lineWidth: 1
                    )
                }
                .scaleEffect(isPressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isPressed)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

/// 顶部 / 底部渐变遮罩。高度固定，避免 Android 那种「遮罩随内容高度抖动」的问题。
struct PlayerChromeGradient: View {
    let edge: VerticalEdge

    var body: some View {
        LinearGradient(
            colors: edge == .top ? PlayerTheme.topGradientColors : PlayerTheme.bottomGradientColors,
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: edge == .top
               ? PlayerTheme.topBarGradientHeight
               : PlayerTheme.bottomBarGradientHeight)
        .allowsHitTesting(false)
    }
}