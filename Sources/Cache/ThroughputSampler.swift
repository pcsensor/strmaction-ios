import Foundation

/// 回源吞吐采样器：滚动窗口内的字节数 → 字节/秒。
///
/// 为什么需要它：FFmpeg 现在只连本机缓存服务（`127.0.0.1`），
/// 播放器自己看到的永远是无损的本地读取速度，真实网速只能在这一层统计。
/// 只有**回源**的字节计入，磁盘命中是 0 流量——这正好回答「到底有没有在下载」。
///
/// 线程模型：写入发生在缓存服务的串行队列上，读取发生在主线程（UI 每秒取一次），
/// 用 NSLock 保护样本数组。
final class ThroughputSampler {
    private struct Sample {
        let time: TimeInterval
        let bytes: Int64
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private let window: TimeInterval
    /// 平滑下限：只有一两个包时窗口很短，直接除会得到虚高的瞬时值。
    private let minimumElapsed: TimeInterval

    init(window: TimeInterval = 3.0, minimumElapsed: TimeInterval = 0.5) {
        self.window = window
        self.minimumElapsed = minimumElapsed
    }

    func add(_ bytes: Int64) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        samples.append(Sample(time: now, bytes: bytes))
        trim(olderThan: now - window)
    }

    func bytesPerSecond() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        trim(olderThan: now - window)
        guard let first = samples.first, !samples.isEmpty else { return 0 }
        // 窗口内最后一次样本到现在还有一段静默时间，也算进去，否则停流后速度不回落。
        let elapsed = max(minimumElapsed, now - first.time)
        let total = samples.reduce(Int64(0)) { $0 + $1.bytes }
        return Double(total) / elapsed
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
    }

    private func trim(olderThan cutoff: TimeInterval) {
        guard let index = samples.firstIndex(where: { $0.time >= cutoff }) else {
            // 全部过期（或数组为空）——只保留最近一次样本作为统计起点。
            if let last = samples.last { samples = [last] } else { samples = [] }
            return
        }
        if index > 0 { samples.removeFirst(index) }
    }
}
