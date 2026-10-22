import Foundation
import Network
import Security

/// 收到一批之后的下一步动作。
///
/// 之所以分三档而不是「继续 / 停止」两档：
/// 直接停止 `receive` 会让 TCP 接收窗口关闭，源站发不出去，几秒后就把连接 RST 掉
/// （实测这个源站约 3.8 秒）。限速这一档让 socket 保持排空，既把下载量压到码率附近，
/// 又不会让源站认为连接已死。
enum PaceDecision {
    /// 立刻收下一批。
    case now
    /// 延迟指定秒数再收下一批，用于限速。
    case after(TimeInterval)
    /// 真的停止 `receive`，等 `resume()`。只在下游彻底不读时用。
    case suspend
}

/// 回源客户端：手写 HTTP/1.1 over `NWConnection`。
///
/// 为什么不用 URLSession：它会与 CDN 协商 HTTP/2，实测吞吐被流控压到 40 KB/s
/// （同一 URL 用外部播放器有 1–2 MB/s）。这里只需要「顺序读一大段字节」，
/// HTTP/1.1 + 大 buffer 的确定性更好。
///
/// 证书校验沿用 `TLSTrustStore` 的根证书锚点，与 API 通道是同一套策略，
/// 不因为多了一层缓存就放松。
final class OriginClient {
    struct Meta {
        let status: Int
        let headers: [String: String]
        /// 文件总长度：优先取 `Content-Range` 的 `/total`，其次 `Content-Length`。
        let totalLength: Int64?
    }

    enum OriginError: LocalizedError {
        case invalidURL
        case malformedResponse
        case httpStatus(Int)
        case tooManyRedirects

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "回源地址无效"
            case .malformedResponse: return "回源响应无法解析"
            case .httpStatus(let code): return "回源返回 HTTP \(code)"
            case .tooManyRedirects: return "回源重定向次数过多"
            }
        }
    }

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var cancelled = false
    /// 被流量控制挂起时，恢复接收所需的 continuation。
    private var resumeHandler: (() -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelled = true
            self.resumeHandler = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    /// 继续接收。由缓存在水位回落后调用。
    func resume() {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            let handler = self.resumeHandler
            self.resumeHandler = nil
            handler?()
        }
    }

    /// 拉取 `[start, end)`。`end` 为 nil 表示一直到文件末尾。
    ///
    /// 回调都在 `queue` 上执行，调用方自行切换线程。
    func fetch(
        url: URL,
        headers: [String: String],
        start: Int64,
        end: Int64?,
        redirectsLeft: Int = 6,
        pace: @escaping (Int64) -> PaceDecision,
        onMeta: @escaping (Meta) -> Void,
        onData: @escaping (Data) -> Void,
        onEnd: @escaping (Error?) -> Void
    ) {
        queue.async { [weak self] in
            self?.start(url: url, headers: headers, start: start, end: end,
                        redirectsLeft: redirectsLeft, pace: pace,
                        onMeta: onMeta, onData: onData, onEnd: onEnd)
        }
    }

    // MARK: 实现

    private func start(
        url: URL,
        headers: [String: String],
        start: Int64,
        end: Int64?,
        redirectsLeft: Int,
        pace: @escaping (Int64) -> PaceDecision,
        onMeta: @escaping (Meta) -> Void,
        onData: @escaping (Data) -> Void,
        onEnd: @escaping (Error?) -> Void
    ) {
        guard !cancelled else { return }
        guard let host = url.host, let scheme = url.scheme?.lowercased() else {
            onEnd(OriginError.invalidURL)
            return
        }
        let isTLS = scheme == "https"
        let rawPort = url.port ?? (isTLS ? 443 : 80)
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: rawPort)) else {
            onEnd(OriginError.invalidURL)
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15

        let parameters: NWParameters
        if isTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                let chain = CertificateTools.chain(from: trust)
                let anchors = TLSTrustStore.shared.anchorCertificates()
                let verdict = CertificateTools.evaluates(chain: chain, host: host, anchors: anchors)
                complete(verdict.isTrusted || CertificateTools.isPubliclyTrusted(trust))
            }, queue)
            if !Self.isNumericHost(host) {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            }
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection

        // 用引用类型承载流式解析状态：receive 的闭包是逃逸的，
        // 不能捕获 inout 参数。
        let state = StreamState()

        connection.stateUpdateHandler = { [weak self] state2 in
            guard let self, !self.cancelled else {
                connection.cancel()
                return
            }
            switch state2 {
            case .ready:
                let request = Self.buildRequest(
                    url: url, host: host, port: Int(port.rawValue), isTLS: isTLS,
                    headers: headers, start: start, end: end
                )
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error {
                        onEnd(error)
                        connection.cancel()
                    }
                })
                self.receiveLoop(
                    connection: connection, sourceURL: url, headers: headers,
                    start: start, end: end, redirectsLeft: redirectsLeft,
                    state: state, pace: pace,
                    onMeta: onMeta, onData: onData, onEnd: onEnd
                )
            case .failed(let error):
                onEnd(error)
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    /// 流式解析状态。header 还没读全时先攒着，读全后一次性把剩余字节当 body 发出去。
    private final class StreamState {
        var headerBuffer = Data()
        var metaDelivered = false
    }

    private func receiveLoop(
        connection: NWConnection,
        sourceURL: URL,
        headers: [String: String],
        start: Int64,
        end: Int64?,
        redirectsLeft: Int,
        state: StreamState,
        pace: @escaping (Int64) -> PaceDecision,
        onMeta: @escaping (Meta) -> Void,
        onData: @escaping (Data) -> Void,
        onEnd: @escaping (Error?) -> Void
    ) {
        // 三种决策都要回到同一个入口，先做成闭包避免三份重复参数。
        let again: () -> Void = { [weak self] in
            self?.receiveLoop(
                connection: connection, sourceURL: sourceURL, headers: headers,
                start: start, end: end, redirectsLeft: redirectsLeft,
                state: state, pace: pace,
                onMeta: onMeta, onData: onData, onEnd: onEnd
            )
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if self.cancelled {
                connection.cancel()
                return
            }

            if let data, !data.isEmpty {
                if state.metaDelivered {
                    onData(data)
                } else {
                    state.headerBuffer.append(data)
                    if let headerEnd = Self.findHeaderEnd(state.headerBuffer) {
                        let head = Data(state.headerBuffer[..<headerEnd])
                        let bodyStart = headerEnd + 4
                        let body = bodyStart < state.headerBuffer.count
                            ? Data(state.headerBuffer[bodyStart...])
                            : Data()

                        guard let meta = Self.parseMeta(head) else {
                            onEnd(OriginError.malformedResponse)
                            connection.cancel()
                            return
                        }

                        // 重定向：换地址重发，保留原始请求头与区间
                        if (300...399).contains(meta.status) {
                            connection.cancel()
                            guard redirectsLeft > 0 else {
                                onEnd(OriginError.tooManyRedirects)
                                return
                            }
                            guard let location = meta.headers["location"],
                                  let next = URL(string: location, relativeTo: sourceURL)?.absoluteURL else {
                                onEnd(OriginError.malformedResponse)
                                return
                            }
                            self.start(url: next, headers: headers, start: start, end: end,
                                       redirectsLeft: redirectsLeft - 1,
                                       pace: pace,
                                       onMeta: onMeta, onData: onData, onEnd: onEnd)
                            return
                        }

                        guard (200...299).contains(meta.status) else {
                            onEnd(OriginError.httpStatus(meta.status))
                            connection.cancel()
                            return
                        }

                        state.metaDelivered = true
                        onMeta(meta)
                        if !body.isEmpty { onData(body) }
                    }
                }
            }

            if isComplete {
                onEnd(nil)
            } else if let error {
                onEnd(error)
            } else {
                switch pace(Int64(data?.count ?? 0)) {
                case .now:
                    again()
                case .after(let seconds):
                    self.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                        guard let self, !self.cancelled else { return }
                        again()
                    }
                case .suspend:
                    // 流量控制生效：不再发起下一次 receive，TCP 接收窗口随之关闭，
                    // 源站就会停发。恢复由 `resume()` 触发。
                    self.resumeHandler = again
                }
            }
        }
    }

    // MARK: HTTP 解析

    private static func buildRequest(
        url: URL, host: String, port: Int, isTLS: Bool,
        headers: [String: String], start: Int64, end: Int64?
    ) -> Data {
        // 注意必须用 percentEncoded 的形式：URL.path 会把 %E5%BD%B1 解码成中文，
        // 而请求行里必须是原始编码，否则源站找不到路径。
        var path = "/"
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            if let query = components.percentEncodedQuery, !query.isEmpty {
                path += "?" + query
            }
        }

        var lines: [String] = []
        lines.append("GET \(path) HTTP/1.1")
        let defaultPort = isTLS ? 443 : 80
        lines.append("Host: \(port == defaultPort ? host : "\(host):\(port)")")

        var hasUserAgent = false
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            let lower = key.lowercased()
            if lower == "range" || lower == "host" || lower == "connection" { continue }
            if lower == "user-agent" { hasUserAgent = true }
            lines.append("\(key): \(value)")
        }
        if !hasUserAgent {
            lines.append("User-Agent: StrmAction/1.0")
        }
        lines.append("Accept: */*")
        lines.append("Range: " + (end.map { "bytes=\(start)-\($0 - 1)" } ?? "bytes=\(start)-"))
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// 返回 `\r\n\r\n` 的起始下标（header 结束位置）。
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

    private static func parseMeta(_ data: Data) -> Meta? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }

        var total: Int64?
        if let contentRange = headers["content-range"], let slash = contentRange.lastIndex(of: "/") {
            total = Int64(contentRange[contentRange.index(after: slash)...])
        }
        if total == nil, let length = headers["content-length"] {
            total = Int64(length)
        }
        return Meta(status: status, headers: headers, totalLength: total)
    }

    private static func isNumericHost(_ host: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789.:")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
