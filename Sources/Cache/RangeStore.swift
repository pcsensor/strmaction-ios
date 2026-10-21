import Foundation

/// 按绝对字节偏移存储的稀疏缓存 + 区间索引。
///
/// FFmpeg 的 seek 会随时改变读取位置，所以不能顺序写，必须按 offset 随机写。
/// 区间索引负责回答一个问题：**这个位置我之前拉过没有**。
/// 命中就直接读盘，不再回源——这就是「拖动回已缓冲位置不重新下载」的全部机制。
final class RangeStore {
    let dataURL: URL
    private let limitBytes: Int64
    private var handle: FileHandle?
    private var ranges: [Range<Int64>] = []
    private let lock = NSLock()
    /// 已落盘的去重字节数（同一段重复写只算一次），用于容量上限。
    private var coveredBytes: Int64 = 0

    init(directory: URL, limitBytes: Int64) {
        self.dataURL = directory.appendingPathComponent("data.bin")
        self.limitBytes = limitBytes
    }

    // MARK: 生命周期

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: dataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: dataURL.path) {
            FileManager.default.createFile(atPath: dataURL.path, contents: nil)
        }
        handle = try FileHandle(forUpdating: dataURL)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    func removeFiles() {
        close()
        try? FileManager.default.removeItem(at: dataURL)
    }

    // MARK: 查询

    /// `start` 是否已经落盘。
    func contains(start: Int64) -> Bool {
        cachedEnd(from: start) > start
    }

    /// 从 `start` 起连续已缓存到的位置。未命中返回 `start`。
    func cachedEnd(from start: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        for range in ranges where range.contains(start) {
            return range.upperBound
        }
        return start
    }

    var storedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return coveredBytes
    }

    // MARK: 写入 / 读取

    /// 写入一段数据，返回是否真的落盘（超过容量上限时返回 false，调用方仍应继续转发）。
    @discardableResult
    func write(_ data: Data, at offset: Int64) -> Bool {
        guard !data.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }

        let incoming = offset..<(offset + Int64(data.count))
        if limitBytes > 0 {
            let projected = merged(ranges, adding: incoming)
                .reduce(Int64(0)) { $0 + Int64($1.count) }
            if projected > limitBytes { return false }
        }

        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            return false
        }

        let before = ranges.reduce(Int64(0)) { $0 + Int64($1.count) }
        ranges = merged(ranges, adding: incoming)
        let after = ranges.reduce(Int64(0)) { $0 + Int64($1.count) }
        coveredBytes += max(Int64(0), after - before)
        return true
    }

    func read(length: Int, at offset: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, length > 0 else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    // MARK: 区间合并

    private func merged(_ existing: [Range<Int64>], adding new: Range<Int64>) -> [Range<Int64>] {
        var lower = new.lowerBound
        var upper = new.upperBound
        var result: [Range<Int64>] = []
        for range in existing {
            if range.upperBound < lower || range.lowerBound > upper {
                result.append(range)
            } else {
                lower = min(lower, range.lowerBound)
                upper = max(upper, range.upperBound)
            }
        }
        result.append(lower..<upper)
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }
}
