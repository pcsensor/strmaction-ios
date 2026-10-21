import SwiftUI

/// 三层缓冲进度条。
///
/// 对齐 Android 端 `BufferedSeekBar` 的视觉：未播放 30% 白、已缓冲 80% 白、已播放金橙，
/// 外加一个同心双环滑块。两处关键改进：
/// 1. 触摸区独立扩展到 44pt 高，不需要精准点在细轨道上；
/// 2. 缓冲进度永远不会短于已播放进度（与 Android 的 coerceIn 一致），
///    否则回放缓存收缩时会出现颜色闪烁。
public struct BufferedSeekBar: View {
    public let currentMs: Int64
    public let durationMs: Int64
    public let bufferedMs: Int64
    public var onSeek: (Int64) -> Void
    public var onScrubbingChanged: ((Bool, Int64) -> Void)?

    @State private var isDragging: Bool = false
    @State private var dragPositionMs: Int64 = 0

    private var playedRatio: Double {
        guard durationMs > 0 else { return 0 }
        return min(1, max(0, Double(currentMs) / Double(durationMs)))
    }

    private var bufferedRatio: Double {
        guard durationMs > 0 else { return 0 }
        let raw = min(1, max(0, Double(bufferedMs) / Double(durationMs)))
        // 缓冲进度至少等于已播放进度，避免已播部分被画成「未播放」的灰白色。
        return max(raw, playedRatio)
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let trackWidth = max(0, width)
            let knobDiameter: CGFloat = isDragging ? 16 : 12
            let trackHeight: CGFloat = isDragging ? 6 : PlayerTheme.seekTrackHeight
            // 滑块中心要内缩半个直径，否则首尾位置会溢出轨道。
            let usableWidth = max(0, trackWidth - knobDiameter)
            let playedX = usableWidth * CGFloat(playedRatio)

            ZStack(alignment: .leading) {
                // 1. 未播放轨道
                Capsule()
                    .fill(PlayerTheme.trackUnplayed)
                    .frame(width: trackWidth, height: trackHeight)

                // 2. 已缓冲轨道
                Capsule()
                    .fill(PlayerTheme.trackBuffered)
                    .frame(width: max(0, usableWidth * CGFloat(bufferedRatio) + knobDiameter / 2), height: trackHeight)

                // 3. 已播放轨道
                Capsule()
                    .fill(PlayerTheme.accent)
                    .frame(width: max(0, playedX + knobDiameter / 2), height: trackHeight)

                // 4. 滑块：外环金橙 + 内芯白色，拖动时轻微放大
                ZStack {
                    Circle()
                        .fill(PlayerTheme.accent)
                        .frame(width: knobDiameter, height: knobDiameter)
                        .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                    Circle()
                        .fill(Color.white)
                        .frame(width: max(4, knobDiameter * 0.42), height: max(4, knobDiameter * 0.42))
                }
                .offset(x: playedX)
                .animation(.easeOut(duration: 0.14), value: isDragging)
                // 只有非拖动状态才做进度补间，拖动时必须 1:1 跟手。
                .animation(.linear(duration: 0.12), value: playedRatio)
            }
            .frame(width: trackWidth, height: PlayerTheme.seekBarHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        let target = positionMs(for: value.location.x, usableWidth: usableWidth)
                        dragPositionMs = target
                        onScrubbingChanged?(true, target)
                    }
                    .onEnded { value in
                        let target = positionMs(for: value.location.x, usableWidth: usableWidth)
                        isDragging = false
                        dragPositionMs = 0
                        onScrubbingChanged?(false, target)
                        onSeek(target)
                    }
            )
        }
        .frame(height: PlayerTheme.seekBarHeight)
    }

    private func positionMs(for x: CGFloat, usableWidth: CGFloat) -> Int64 {
        guard durationMs > 0, usableWidth > 0 else { return 0 }
        let ratio = min(1, max(0, Double(x / usableWidth)))
        return Int64(Double(durationMs) * ratio)
    }
}