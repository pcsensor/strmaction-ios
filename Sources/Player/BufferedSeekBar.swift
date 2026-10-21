import SwiftUI

/// 精致三层缓冲进度条 (BufferedSeekBar)
/// 1. 底层：未缓冲轨道 rgba(255, 255, 255, 0.2)
/// 2. 中层：已缓冲轨道 rgba(255, 255, 255, 0.5)
/// 3. 顶层：已播放进度 #E8B06A，带 12pt 圆形滑块
/// 4. 触摸区高度扩展至 36pt，确保触摸手感
public struct BufferedSeekBar: View {
    public let currentMs: Int64
    public let durationMs: Int64
    public let bufferedMs: Int64
    public var onSeek: (Int64) -> Void
    public var onScrubbingChanged: ((Bool, Int64) -> Void)?

    @State private var isDragging: Bool = false
    @State private var dragPositionMs: Int64 = 0

    public init(
        currentMs: Int64,
        durationMs: Int64,
        bufferedMs: Int64,
        onSeek: @escaping (Int64) -> Void,
        onScrubbingChanged: ((Bool, Int64) -> Void)? = nil
    ) {
        self.currentMs = currentMs
        self.durationMs = durationMs
        self.bufferedMs = bufferedMs
        self.onSeek = onSeek
        self.onScrubbingChanged = onScrubbingChanged
    }

    private var activePositionMs: Int64 {
        isDragging ? dragPositionMs : currentMs
    }

    public var body: some View {
        GeometryReader { geometry in
            let totalDuration = max(1, durationMs)
            let width = geometry.size.width
            let playedRatio = min(1.0, max(0.0, Double(activePositionMs) / Double(totalDuration)))
            let bufferedRatio = min(1.0, max(0.0, Double(bufferedMs) / Double(totalDuration)))

            ZStack(alignment: .leading) {
                // 触摸热区
                Color.clear
                    .frame(height: 36)
                    .contentShape(Rectangle())

                // 1. 底层未缓冲轨道
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 3)

                // 2. 中层已缓冲轨道
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: max(0, width * CGFloat(bufferedRatio)), height: 3)

                // 3. 顶层已播放轨道
                Capsule()
                    .fill(Color(hex: "#E8B06A"))
                    .frame(width: max(0, width * CGFloat(playedRatio)), height: 3)

                // 4. 滑块 (Knob)
                Circle()
                    .fill(Color(hex: "#E8B06A"))
                    .frame(width: isDragging ? 16 : 12, height: isDragging ? 16 : 12)
                    .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(x: max(0, min(width - (isDragging ? 16 : 12), width * CGFloat(playedRatio) - (isDragging ? 8 : 6))))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let clampedX = max(0, min(width, value.location.x))
                        let ratio = clampedX / width
                        let newMs = Int64(Double(totalDuration) * Double(ratio))
                        dragPositionMs = newMs
                        onScrubbingChanged?(true, newMs)
                    }
                    .onEnded { value in
                        let clampedX = max(0, min(width, value.location.x))
                        let ratio = clampedX / width
                        let targetMs = Int64(Double(totalDuration) * Double(ratio))
                        isDragging = false
                        onScrubbingChanged?(false, targetMs)
                        onSeek(targetMs)
                    }
            )
        }
        .frame(height: 36)
    }
}
