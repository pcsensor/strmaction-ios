import CryptoKit
import Foundation
import Network

/// 本地缓存服务：FFmpeg 连 `127.0.0.1`，命中走磁盘，未命中回源并落盘。
///
/// 只实现 FFmpeg 需要的最小 HTTP 子集：`GET` + `Range`，回 `206`，
/// `Connection: close`（FFmpeg 每次 seek 都新建连接，不做 keep-alive）。
///
/// 这一层不是「代理」——它不改变请求语义，只决定这次读取是从磁盘拿还是从源站拿。
final class CacheServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "top.strmaction.cache", qos: .userInitiated)
    private let store: RangeStore
    private let sourceURL: URL
    private let headers: [String: String]
    /// 本地端口的随机路径前缀，避免同网段其他人直接拉到缓存内容。
    private let token: String
    /// 源文件总长度。第一次回源从 `Content-Range` 拿到，后续 seek 直接复用。
    ///
    /// 会在缓存队列上写、在主线程（UI 取缓存区间）上读，所以用锁包一层。
    private let metaLock = NSLock()
    private var storedTotalLength: Int64 = -1
    private var totalLength: Int64 {
        get { metaLock.lock(); defer { metaLock.unlock() }; return storedTotalLength }
        set { metaLock.lock(); defer { metaLock.unlock() }; storedTotalLength = newValue }
    }
    /// 回源吞吐采样。只统计真正走网络的字节，UI 的「实时网速」读它。
    let throughput = ThroughputSampler()
    /// 每个本地连接对应的回源客户端，连接断开时一并取消，避免僵尸下载。
    private var origins: [ObjectIdentifier: OriginClient] = [:]
    private var isStopped = false

    // MARK: 流量控制
    //
    // 这一层插在 FFmpeg 和源站之间，天然会切断 TCP 背压：FFmpeg 不读之后，
    // 本地连接的 send 队列会在内存里无限堆积，源站却毫不知情地继续全速推送。
    // 所以必须由我们自己做「下游消费驱动」的流量控制，否则缓冲设置形同虚设。

    /// 预拉取目标：已拉取但还没播到的字节维持在这个量以内（用户设置的缓冲大小）。
    private let targetAheadBytes: Int64
    /// 已消费字节（播放位置折算）。由播放层定期写入。
    private let consumedLock = NSLock()
    private var storedConsumedBytes: Int64 = 0
    private var consumedBytes: Int64 {
        get { consumedLock.lock(); defer { consumedLock.unlock() }; return storedConsumedBytes }
        set { consumedLock.lock(); defer { consumedLock.unlock() }; storedConsumedBytes = newValue }
    }
    /// 每个连接的流量控制状态。
    private var pacing: [ObjectIdentifier: Pace] = [:]
    private var paceTickScheduled = false

    /// 单条连接的流控状态。
    private final class Pace {
        /// 已交给本地连接、还没被 FFmpeg 取走的字节。
        var inFlight: Int64 = 0
        /// 本次回源已写到的偏移。
        var writeOffset: Int64 = 0
        var suspended = false
        /// 挂起时刻，用于空闲过久时主动断开。
        var suspendedAt: Date?
    }

    /// 本地连接侧的在途上限。即使水位没到，也不能让 NWConnection 的发送队列无限膨胀。
    private static let maxInFlightBytes: Int64 = 4 * 1024 * 1024
    /// 流控重试间隔。40ms 一次的小步呼吸，不是「全速 / 全停」的开关。
    private static let paceTickSeconds: Double = 0.04
    /// 挂起超过这个时长就断开：源站很可能已经把连接掐了，留着只是个死连接。
    private static let maxIdleSeconds: TimeInterval = 60

    init(sourceURL: URL, headers: [String: String], store: RangeStore, token: String, targetAheadMb: Int) throws {
        self.sourceURL = sourceURL
        self.headers = headers
        self.store = store
        self.token = token
        self.targetAheadBytes = Int64(max(0, targetAheadMb)) * 1_048_576

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// 启动并返回本地端口。
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.isStopped = true
            self.listener.cancel()
            for (_, origin) in self.origins { origin.cancel() }
            self.origins.removeAll()
            self.pacing.removeAll()
            self.store.close()
        }
    }

    /// 给 UI 的只读快照：已落盘区间 + 源文件总长度。
    ///
    /// UI 拿这两个值把字节区间折算成时间区间，画进度条上的缓存横线。
    func cacheSnapshot() -> (ranges: [Range<Int64>], totalBytes: Int64) {
        return (store.snapshot(), totalLength)
    }

    /// 播放层写入已消费字节（播放位置按总时长折算）。
    ///
    /// 水位是「已拉取 − 已消费」，所以播放位置必须回流到这一层，
    /// 否则无法判断预拉取是否超前。
    func setConsumedBytes(_ bytes: Int64) {
        consumedBytes = max(0, bytes)
    }

    // MARK: 流量控制

    /// 是否应当暂停这条连接的回源。
    ///
    /// 注意用的是**本次回源的写偏移**而不是全局最高偏移：向后 seek 到未缓存区域时，
    /// 全局最高偏移远在播放点之后，拿它算水位会立刻判定「超前」而把这次回源掐死。
    private func shouldSuspend(_ pace: Pace) -> Bool {
        if pace.inFlight >= Self.maxInFlightBytes { return true }
        guard targetAheadBytes > 0 else { return false }
        return pace.writeOffset - consumedBytes >= targetAheadBytes
    }

    private func startPaceTickIfNeeded() {
        guard !paceTickScheduled else { return }
        guard pacing.values.contains(where: { $0.suspended }) else { return }
        paceTickScheduled = true
        queue.asyncAfter(deadline: .now() + Self.paceTickSeconds) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.paceTickScheduled = false
            self.runPaceTick()
            self.startPaceTickIfNeeded()
        }
    }

    /// 一轮检查：水位回落的恢复接收；挂起太久的直接断开重连。
    private func runPaceTick() {
        let now = Date()
        for (key, pace) in pacing where pace.suspended {
            guard let origin = origins[key] else { continue }
            if let suspendedAt = pace.suspendedAt,
               now.timeIntervalSince(suspendedAt) > Self.maxIdleSeconds {
                D.log("cache", "空闲 \(Int(Self.maxIdleSeconds))s 未消费，断开回源等待下次请求")
                origins.removeValue(forKey: key)
                pace.suspended = false
                origin.cancel()
                continue
            }
            if !shouldSuspend(pace) {
                pace.suspended = false
                pace.suspendedAt = nil
                origin.resume()
            }
        }
    }

    private func markSuspended(_ pace: Pace) {
        pace.suspended = true
        if pace.suspendedAt == nil { pace.suspendedAt = Date() }
    }

    // MARK: 连接处理

    private func accept(_ connection: NWConnection) {
        let buffer = RequestBuffer()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { connection.cancel(); return }
            switch state {
            case .ready:
                self.readRequest(connection, buffer: buffer)
            case .failed, .cancelled:
                self.cancelOrigin(for: connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func readRequest(_ connection: NWConnection, buffer: RequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isStopped else { connection.cancel(); return }
            if let data { buffer.data.append(data) }

            if let headerEnd = Self.findHeaderEnd(buffer.data) {
                let head = Data(buffer.data[..<headerEnd])
                self.route(connection, head: head)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.readRequest(connection, buffer: buffer)
        }
    }

    private func route(_ connection: NWConnection, head: Data) {
        guard Self.requestMatches(head, token: token) else {
            let deny = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(deny.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let range = Self.parseRange(head)
        let start = range.start
        let cachedEnd = store.cachedEnd(from: start)

        if cachedEnd > start, totalLength > 0 {
            // 命中：从磁盘直发，零网络
            serveFromDisk(connection, start: start, end: range.end, cachedEnd: cachedEnd)
        } else {
            serveFromOrigin(connection, start: start, end: range.end)
        }
    }

    // MARK: 磁盘命中

    private func serveFromDisk(_ connection: NWConnection, start: Int64, end: Int64?, cachedEnd: Int64) {
        let total = totalLength
        let upper = min(end ?? total, min(cachedEnd, total))
        let length = upper - start
        guard length > 0 else {
            connection.cancel()
            return
        }

        D.log("cache", "命中磁盘 \(Self.mb(length)) @\(start)")

        var head = "HTTP/1.1 206 Partial Content\r\n"
        head += "Content-Type: video/mp4\r\n"
        head += "Content-Range: bytes \(start)-\(upper - 1)/\(total)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Connection: close\r\n\r\n"

        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            self.pumpDisk(connection, offset: start, remain: length)
        })
    }

    private func pumpDisk(_ connection: NWConnection, offset: Int64, remain: Int64) {
        guard remain > 0, !isStopped else {
            connection.cancel()
            return
        }
        let chunk = Int(min(remain, 256 * 1024))
        guard let data = store.read(length: chunk, at: offset), !data.isEmpty else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.pumpDisk(connection, offset: offset + Int64(data.count), remain: remain - Int64(data.count))
        })
    }

    // MARK: 回源

    private func serveFromOrigin(_ connection: NWConnection, start: Int64, end: Int64?) {
        let client = OriginClient(queue: queue)
        let key = ObjectIdentifier(connection)
        let pace = Pace()
        pace.writeOffset = start
        origins[key] = client
        pacing[key] = pace
        var headSent = false
        var forwarded: Int64 = 0

        client.fetch(
            url: sourceURL,
            headers: headers,
            start: start,
            end: end,
            // 每收一批就问一次：预拉取是否超前。超前就真的停止 receive，
            // 内核接收窗口随之关闭，源站才会停发——这是背压能传导出去的唯一方式。
            shouldContinue: { [weak self] in
                guard let self, !self.isStopped else { return false }
                if self.shouldSuspend(pace) {
                    self.markSuspended(pace)
                    self.startPaceTickIfNeeded()
                    return false
                }
                return true
            },
            onMeta: { [weak self] meta in
                guard let self, !self.isStopped else { return }
                if let total = meta.totalLength, total > 0 {
                    self.totalLength = total
                }
                let total = self.totalLength
                let upper: Int64
                if let end {
                    upper = end
                } else if total > 0 {
                    upper = total
                } else {
                    upper = 0
                }

                var head = "HTTP/1.1 206 Partial Content\r\n"
                head += "Content-Type: video/mp4\r\n"
                if total > 0, upper > start {
                    head += "Content-Range: bytes \(start)-\(upper - 1)/\(total)\r\n"
                    head += "Content-Length: \(upper - start)\r\n"
                }
                // 拿不到总长度时不写 Content-Length，让 FFmpeg 读到连接关闭为止。
                head += "Accept-Ranges: bytes\r\n"
                head += "Connection: close\r\n\r\n"
                headSent = true
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                D.log("cache", "回源 @\(start) total=\(total)")
            },
            onData: { [weak self] data in
                guard let self, !self.isStopped else { return }
                let count = Int64(data.count)
                if headSent {
                    pace.inFlight += count
                    connection.send(content: data, completion: .contentProcessed { error in
                        pace.inFlight -= count
                        // FFmpeg 关掉连接后立刻停掉回源，别继续白下载。
                        if error != nil { self.cancelOrigin(for: connection) }
                    })
                }
                self.throughput.add(count)
                self.store.write(data, at: pace.writeOffset)
                pace.writeOffset += count
                forwarded += count
            },
            onEnd: { [weak self] error in
                guard let self else { connection.cancel(); return }
                self.origins.removeValue(forKey: key)
                self.pacing.removeValue(forKey: key)
                if let error {
                    D.log("cache", "回源中断：\(error.localizedDescription)")
                } else {
                    D.log("cache", "回源完成 共 \(Self.mb(forwarded)) 已存 \(Self.mb(self.store.storedBytes))")
                }
                connection.cancel()
            }
        )
    }

    private func cancelOrigin(for connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        pacing.removeValue(forKey: key)
        if let origin = origins.removeValue(forKey: key) {
            origin.cancel()
        }
    }

    // MARK: 解析

    /// 请求行必须带上会话 token，否则直接 403。
    private static func requestMatches(_ head: Data, token: String) -> Bool {
        guard let text = String(data: head, encoding: .isoLatin1),
              let firstLine = text.components(separatedBy: "\r\n").first else {
            return false
        }
        return firstLine.contains("/" + token)
    }

    private static func parseRange(_ head: Data) -> (start: Int64, end: Int64?) {
        guard let text = String(data: head, encoding: .isoLatin1) else { return (0, nil) }
        for line in text.components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("range:") else { continue }
            let value = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("bytes=") else { continue }
            let spec = value.dropFirst("bytes=".count)
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            guard let first = parts.first, let start = Int64(first) else { continue }
            if parts.count > 1, let end = Int64(parts[1]), end >= start {
                return (start, end + 1)
            }
            return (start, nil)
        }
        return (0, nil)
    }

    private static func findHeaderEnd(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10,
               bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }

    private final class RequestBuffer {
        var data = Data()
    }

    private final class ResumeGate {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}

// MARK: - 会话

/// 一次播放会话的磁盘缓存。
///
/// 目录按 URL 哈希隔离，`stop()` 时整目录删除——就是「退出播放即清空」。
final class MediaCacheSession {
    let localURL: URL
    private let server: CacheServer
    private let directory: URL
    private let store: RangeStore

    private init(localURL: URL, server: CacheServer, directory: URL, store: RangeStore) {
        self.localURL = localURL
        self.server = server
        self.directory = directory
        self.store = store
    }

    static func start(sourceURL: URL, headers: [String: String], limitMb: Int, targetAheadMb: Int) async throws -> MediaCacheSession {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("strmaction", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
        // 单会话：先清掉上一次的残留
        try? FileManager.default.removeItem(at: root)
        let key = Self.hash(sourceURL.absoluteString)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let limitBytes = Int64(max(0, limitMb)) * 1_048_576
        let store = RangeStore(directory: directory, limitBytes: limitBytes)
        try store.prepare()

        let server = try CacheServer(sourceURL: sourceURL, headers: headers, store: store, token: token, targetAheadMb: targetAheadMb)
        let port = try await server.start()
        guard port > 0, let localURL = URL(string: "http://127.0.0.1:\(port)/\(token)") else {
            server.stop()
            throw CacheError.startFailed
        }
        D.log("cache", "会话就绪 端口=\(port) 磁盘上限=\(limitMb)MB 预拉取目标=\(targetAheadMb)MB 源=\(sourceURL.host ?? "-")")
        return MediaCacheSession(localURL: localURL, server: server, directory: directory, store: store)
    }

    /// 回源吞吐采样器（只读）。
    var throughputSampler: ThroughputSampler { server.throughput }
    /// 已落盘区间 + 源文件总长度，供进度条画缓存横线。
    func cacheSnapshot() -> (ranges: [Range<Int64>], totalBytes: Int64) {
        server.cacheSnapshot()
    }

    /// 回写播放位置折算出的已消费字节，供流量控制算水位。
    func setConsumedBytes(_ bytes: Int64) {
        server.setConsumedBytes(bytes)
    }

    func stop() {
        server.stop()
        store.removeFiles()
        try? FileManager.default.removeItem(at: directory)
        D.log("cache", "会话已清理")
    }

    private static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum CacheError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        "磁盘缓存层启动失败（本地端口不可用）"
    }
}
