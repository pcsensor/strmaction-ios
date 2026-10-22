import SwiftUI

/// 加宽轨道 + 缓存中线的进度条。
///
/// 与上一版（三层同高胶囊）的两处结构性差别：
/// 1. **已缓存不再用同高色块，而是轨道垂直居中的一条细线**，并且画在最上层——
///    已播放的金色色块盖不住它，播放头前后的落盘情况同时可见。
/// 2. **缓存长度只由真实缓存数据决定**，不再与播放头取 `max`。
///    上一版把它和播放位置耦合，拖动预览时缓冲条会瞬间被拉到手指处，
///    松手 seek 后又缩回播放头附近，一涨一缩就是「闪烁刷新」的成因。
///
/// 缓存区间可以多段：seek 之后补拉的片段单独显示，中间没拉过的空洞保持空白。
public struct BufferedSeekBar: View {
    public let currentMs: Int64
    public let durationMs: Int64
    /// 已落盘区间（时间轴，升序、已合并），可能有多段。
    public let cachedSegments: [CachedSegment]
    public var onSeek: (Int64) -> Void
    public var onScrubbingChanged: ((Bool, Int64) -> Void)?

    @State private var isDragging: Bool = false

    private var playedRatio: Double {
        guard durationMs > 0 else { return 0 }
        return min(1, max(0, Double(currentMs) / Double(durationMs)))
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knobDiameter: CGFloat = isDragging ? 18 : 13
            let trackHeight: CGFloat = isDragging
                ? PlayerTheme.seekTrackHeightDragging
                : PlayerTheme.seekTrackHeight
            let lineHeight: CGFloat = isDragging
                ? PlayerTheme.seekCacheLineHeightDragging
                : PlayerTheme.seekCacheLineHeight
            // 滑块中心要内缩半个直径，否则首尾位置会溢出轨道。
            let usableWidth = max(0, width - knobDiameter)
            let playedX = usableWidth * CGFloat(playedRatio)

            ZStack(alignment: .leading) {
                // 1. 未播放轨道
                Capsule()
                    .fill(PlayerTheme.trackUnplayed)
                    .frame(width: width, height: trackHeight)

                // 2. 已播放
                Capsule()
                    .fill(PlayerTheme.accent)
                    .frame(width: max(0, playedX + knobDiameter / 2), height: trackHeight)

                // 3. 已缓存横线：置顶，跨过已播放色块依然可见
                ForEach(cachedSegments) { segment in
                    if let line = lineFrame(for: segment, usableWidth: usableWidth) {
                        Capsule()
                            .fill(PlayerTheme.trackCacheLine)
                            .frame(width: line.width, height: lineHeight)
                            .offset(x: line.x)
                    }
                }
                // 拖动时冻结补间：手指正在定位置，任何动画都是抖动。
                .animation(isDragging ? nil : .easeOut(duration: 0.18), value: cachedSegments)

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
                .animation(isDragging ? nil : .linear(duration: 0.12), value: playedRatio)
            }
            .frame(width: width, height: PlayerTheme.seekBarHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        let target = positionMs(for: value.location.x, usableWidth: usableWidth)
                        onScrubbingChanged?(true, target)
                    }
                    .onEnded { value in
                        let target = positionMs(for: value.location.x, usableWidth: usableWidth)
                        isDragging = false
                        onScrubbingChanged?(false, target)
                        onSeek(target)
                    }
            )
        }
        .frame(height: PlayerTheme.seekBarHeight)
    }

    /// 一段缓存区间对应的横线位置。
    ///
    /// 过短的段也保留最小 2pt，否则刚拉到的一小截会「时有时无」地闪。
    private func lineFrame(
        for segment: CachedSegment,
        usableWidth: CGFloat
    ) -> (x: CGFloat, width: CGFloat)? {
        guard durationMs > 0, usableWidth > 0 else { return nil }
        let start = min(1, max(0, Double(segment.startMs) / Double(durationMs)))
        let end = min(1, max(0, Double(segment.endMs) / Double(durationMs)))
        guard end > start else { return nil }
        let x = usableWidth * CGFloat(start)
        return (x, max(2, usableWidth * CGFloat(end - start)))
    }

    private func positionMs(for x: CGFloat, usableWidth: CGFloat) -> Int64 {
        guard durationMs > 0, usableWidth > 0 else { return 0 }
        let ratio = min(1, max(0, Double(x / usableWidth)))
        return Int64(Double(durationMs) * ratio)
    }
}
