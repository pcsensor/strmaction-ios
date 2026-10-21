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
    private var totalLength: Int64 = -1
    /// 每个本地连接对应的回源客户端，连接断开时一并取消，避免僵尸下载。
    private var origins: [ObjectIdentifier: OriginClient] = [:]
    private var isStopped = false

    init(sourceURL: URL, headers: [String: String], store: RangeStore, token: String) throws {
        self.sourceURL = sourceURL
        self.headers = headers
        self.store = store
        self.token = token

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
            self.store.close()
        }
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
        origins[ObjectIdentifier(connection)] = client
        var writeOffset = start
        var headSent = false
        var forwarded: Int64 = 0

        client.fetch(
            url: sourceURL,
            headers: headers,
            start: start,
            end: end,
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
                if headSent {
                    connection.send(content: data, completion: .contentProcessed { error in
                        // FFmpeg 关掉连接后立刻停掉回源，别继续白下载。
                        if error != nil { self.cancelOrigin(for: connection) }
                    })
                }
                self.store.write(data, at: writeOffset)
                writeOffset += Int64(data.count)
                forwarded += Int64(data.count)
            },
            onEnd: { [weak self] error in
                guard let self else { connection.cancel(); return }
                self.origins.removeValue(forKey: ObjectIdentifier(connection))
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
        if let origin = origins.removeValue(forKey: ObjectIdentifier(connection)) {
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

    static func start(sourceURL: URL, headers: [String: String], limitMb: Int) async throws -> MediaCacheSession {
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

        let server = try CacheServer(sourceURL: sourceURL, headers: headers, store: store, token: token)
        let port = try await server.start()
        guard port > 0, let localURL = URL(string: "http://127.0.0.1:\(port)/\(token)") else {
            server.stop()
            throw CacheError.startFailed
        }
        D.log("cache", "会话就绪 端口=\(port) 上限=\(limitMb)MB 源=\(sourceURL.host ?? "-")")
        return MediaCacheSession(localURL: localURL, server: server, directory: directory, store: store)
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
