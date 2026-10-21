import SwiftUI

// MARK: - 居中反馈浮层
//
// 修复点 #1：亮度 / 音量 / 进度预览的提示统一显示在**屏幕正中**，
// 不再跟随手指位置。浮层自身不接收触摸，避免手势中途被自己吃掉。

struct PlayerCenterBadgeView: View {
    let badge: PlayerCenterBadge

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            // 必须用固定 width，不能用 minWidth：
            // levelContent 里的 Spacer + GeometryReader 都是贪婪布局，
            // 在 ZStack 里会被撑到整屏宽，背景就变成一条横贯屏幕的黑条。
            .frame(width: 200)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.82))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 6)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    @ViewBuilder
    private var content: some View {
        switch badge {
        case .toast(let text):
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PlayerTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

        case .scrub(let data):
            scrubContent(data)

        case .brightness(let value):
            levelContent(
                icon: "sun.max.fill",
                label: "亮度",
                value: value,
                tint: PlayerTheme.accent
            )

        case .volume(let value):
            levelContent(
                icon: value <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: "音量",
                value: value,
                tint: PlayerTheme.accent
            )
        }
    }

    private func scrubContent(_ data: ScrubBadgeData) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: data.deltaSec >= 0 ? "goforward" : "gobackward")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(data.deltaSec >= 0 ? PlayerTheme.accent : Color.white)
                Text("\(PlayerTimeFormat.string(ms: data.targetMs)) / \(PlayerTimeFormat.string(ms: data.totalMs))")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(PlayerTheme.textPrimary)
                    .monospacedDigit()
                if data.deltaSec != 0 {
                    Text("\(data.deltaSec > 0 ? "+" : "")\(data.deltaSec)s")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PlayerTheme.textMuted)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(data.isBuffered ? Color.green.opacity(0.85) : PlayerTheme.accent)
                    .frame(width: 6, height: 6)
                Text(data.isBuffered ? "已缓冲" : "缓冲中")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(data.isBuffered ? PlayerTheme.textMuted : PlayerTheme.accent)
            }
        }
    }

    private func levelContent(icon: String, label: String, value: Double, tint: Color) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PlayerTheme.textSecondary)
                Spacer(minLength: 4)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(PlayerTheme.textPrimary)
                    .monospacedDigit()
            }

            // 细条形进度，直观反映当前档位
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geometry.size.width * CGFloat(min(1, max(0, value)))))
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - 长按倍速浮层（顶部）

struct PlayerSpeedBadgeView: View {
    let speed: Double

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "forward.fill")
                .font(.system(size: 13, weight: .bold))
            Text("\(PlayerTimeFormat.speedCompact(speed)) 倍速播放中")
                .font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(PlayerTheme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            Capsule().fill(Color.black.opacity(0.75))
        }
        .overlay {
            Capsule().strokeBorder(PlayerTheme.accent.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 缓冲指示

struct PlayerBufferingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(PlayerTheme.accent)
                .scaleEffect(1.4)
            Text("正在缓冲…")
                .font(.system(size: 13))
                .foregroundStyle(PlayerTheme.textSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.62))
        }
        .transition(.opacity)
    }
}

// MARK: - 错误浮层

struct PlayerErrorOverlay: View {
    let message: String
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.86).ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(PlayerTheme.accent)

                Text("播放失败")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(PlayerTheme.textPrimary)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(PlayerTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)

                HStack(spacing: 12) {
                    button(title: "重试", filled: true, action: onRetry)
                    button(title: "关闭", filled: false, action: onClose)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PlayerTheme.panel)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(PlayerTheme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.6), radius: 28, x: 0, y: 10)
            .padding(.horizontal, 32)
        }
    }

    private func button(title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(filled ? Color.black : PlayerTheme.textPrimary)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(filled ? PlayerTheme.accent : PlayerTheme.panelRaised)
            }
            .buttonStyle(.plain)
    }
}

// MARK: - 自动连播浮层

struct PlayerAutoNextOverlay: View {
    let nextTitle: String
    let countdown: Int
    let onCancel: () -> Void
    let onPlayNow: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("即将播放下一集")
                .font(.system(size: 13))
                .foregroundStyle(PlayerTheme.textMuted)

            Text(nextTitle)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(PlayerTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 8)

            Text("\(countdown) 秒后自动连播")
                .font(.system(size: 12))
                .foregroundStyle(PlayerTheme.accent)

            HStack(spacing: 12) {
                Button("取消", action: onCancel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PlayerTheme.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(PlayerTheme.panelRaised)
                    }

                Button("立即播放", action: onPlayNow)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(PlayerTheme.accent)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .frame(maxWidth: 300)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PlayerTheme.panel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PlayerTheme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 8)
    }
}