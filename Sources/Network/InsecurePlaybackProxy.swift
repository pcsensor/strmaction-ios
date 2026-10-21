import Foundation
import Network

/// 当“允许自签名证书”开启时，把播放地址包装成本机回环 HTTP 代理。
///
/// KSPlayer 的两条播放链路对自签名证书的支持不一致：
/// - KSMEPlayer / FFmpeg 的 TLS 行为受编译选项影响；
/// - KSAVPlayer / AVFoundation 没有公开的证书信任回调。
///
/// 让播放器只访问 127.0.0.1，由本代理使用 URLSession（可放行服务端信任）
/// 回源到真正的 HTTPS 地址，两条链路就都能播放自签名资源。
final class InsecurePlaybackProxy {
    static let shared = InsecurePlaybackProxy()

    private let queue = DispatchQueue(label: "top.strmaction.playback-proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var listeningPort: UInt16?
    private var isStarting = false
    private var startWaiters: [DispatchSemaphore] = []
    private var sessions: [String: [String: String]] = [:]

    private init() {}

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "allow_insecure_http") as? Bool ?? true
    }

    /// 为一次播放注册代理会话。返回的 session 需要由播放器持有，销毁时调用 invalidate。
    func makeSession(remoteURL: URL, headers: [String: String]) -> InsecurePlaybackSession? {
        guard let scheme = remoteURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let port = ensureStarted() else {
            return nil
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let base = "http://127.0.0.1:\(port)"
        guard let localURL = Self.makeLocalURL(base: base, sessionID: id, remoteURL: remoteURL) else {
            return nil
        }

        queue.sync {
            sessions[id] = headers
        }
        return InsecurePlaybackSession(id: id, localURL: localURL, proxy: self)
    }

    fileprivate func removeSession(_ id: String) {
        queue.async { [weak self] in
            self?.sessions.removeValue(forKey: id)
        }
    }

    // MARK: - Listener

    private func ensureStarted() -> UInt16? {
        if let port = queue.sync(execute: { listeningPort }) {
            return port
        }

        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            if self.listeningPort != nil {
                semaphore.signal()
                return
            }
            if self.isStarting {
                self.startWaiters.append(semaphore)
                return
            }

            self.isStarting = true
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: .any
                )

                let listener = try NWListener(using: parameters, on: .any)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listeningPort = listener.port?.rawValue
                        self.isStarting = false
                        self.signalStartWaiters()
                    case .failed(let error):
                        print("[PlaybackProxy] listener failed: \(error)")
                        self.listeningPort = nil
                        self.isStarting = false
                        self.signalStartWaiters()
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                self.startWaiters.append(semaphore)
                listener.start(queue: self.queue)
            } catch {
                print("[PlaybackProxy] listener start failed: \(error)")
                self.isStarting = false
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return queue.sync { listeningPort }
    }

    private func signalStartWaiters() {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.signal() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var received = buffer
            if let data {
                received.append(data)
            }
            if received.count > 64 * 1024 {
                self.sendSimpleError(connection: connection, status: 431, reason: "Request Header Fields Too Large")
                return
            }

            let terminator = Data("\r\n\r\n".utf8)
            if let range = received.range(of: terminator) {
                let headerData = received.subdata(in: 0 ..< range.lowerBound)
                self.handleRequest(connection: connection, headerData: headerData)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: received)
            }
        }
    }

    private func handleRequest(connection: NWConnection, headerData: Data) {
        guard let text = String(data: headerData, encoding: .utf8) else {
            sendSimpleError(connection: connection, status: 400, reason: "Bad Request")
            return
        }

        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendSimpleError(connection: connection, status: 400, reason: "Bad Request")
            return
        }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            sendSimpleError(connection: connection, status: 400, reason: "Bad Request")
            return
        }
        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])

        guard method == "GET" || method == "HEAD" else {
            sendSimpleError(connection: connection, status: 405, reason: "Method Not Allowed")
            return
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                headers[name] = value
            }
        }

        let path: String
        if let url = URL(string: target), url.scheme != nil {
            path = url.path
        } else {
            path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        }

        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "s" else {
            sendSimpleError(connection: connection, status: 404, reason: "Not Found")
            return
        }

        let sessionID = parts[1]
        let payload = parts[2]
        // 本方法运行在代理串行队列上，直接访问受该队列保护的状态。
        guard let sessionHeaders = sessions[sessionID] else {
            sendSimpleError(connection: connection, status: 404, reason: "Not Found")
            return
        }
        guard let remoteURL = Self.remoteURL(fromPayload: payload),
              let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            sendSimpleError(connection: connection, status: 400, reason: "Bad Request")
            return
        }
        guard let port = listeningPort else {
            sendSimpleError(connection: connection, status: 503, reason: "Service Unavailable")
            return
        }

        let localBase = "http://127.0.0.1:\(port)"
        let transaction = PlaybackProxyTransaction(
            connection: connection,
            remoteURL: remoteURL,
            sessionID: sessionID,
            sessionHeaders: sessionHeaders,
            requestHeaders: headers,
            method: method,
            localBase: localBase
        )
        transaction.start()
    }

    private func sendSimpleError(connection: NWConnection, status: Int, reason: String) {
        let body = Data("\(status) \(reason)".utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - URL helpers

    fileprivate static func makeLocalURL(base: String, sessionID: String, remoteURL: URL) -> URL? {
        let payload = base64URL(remoteURL.absoluteString)
        let filename = sanitizedFilename(remoteURL)
        return URL(string: "\(base)/s/\(sessionID)/\(payload)/\(filename)")
    }

    fileprivate static func makeLocalURLString(base: String, sessionID: String, remoteURL: URL) -> String {
        makeLocalURL(base: base, sessionID: sessionID, remoteURL: remoteURL)?.absoluteString ?? remoteURL.absoluteString
    }

    fileprivate static func remoteURL(fromPayload payload: String) -> URL? {
        var value = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 {
            value.append("=")
        }
        guard let data = Data(base64Encoded: value),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return URL(string: string)
    }

    private static func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sanitizedFilename(_ url: URL) -> String {
        let name = url.lastPathComponent
        let candidate = name.isEmpty ? "stream" : name
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let encoded = candidate.addingPercentEncoding(withAllowedCharacters: allowed) ?? "stream"
        return String(encoded.prefix(120))
    }
}

/// 一次播放代理会话的句柄。
final class InsecurePlaybackSession {
    let id: String
    let localURL: URL
    private weak var proxy: InsecurePlaybackProxy?

    fileprivate init(id: String, localURL: URL, proxy: InsecurePlaybackProxy) {
        self.id = id
        self.localURL = localURL
        self.proxy = proxy
    }

    func invalidate() {
        proxy?.removeSession(id)
    }

    deinit {
        proxy?.removeSession(id)
    }
}

// MARK: - HTTP transaction

private final class PlaybackProxyTransaction: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private static let maxPlaylistBytes = 8 * 1024 * 1024
    private static let maxPendingBytes = 16 * 1024 * 1024
    private static let resumePendingBytes = 4 * 1024 * 1024

    private let connection: NWConnection
    private let remoteURL: URL
    private let sessionID: String
    private let sessionHeaders: [String: String]
    private let requestHeaders: [String: String]
    private let method: String
    private let localBase: String
    private let delegateQueue: OperationQueue
    private let stateQueue = DispatchQueue(label: "top.strmaction.playback-proxy.transaction")

    private var urlSession: URLSession?
    private var task: URLSessionDataTask?
    private var httpResponse: HTTPURLResponse?
    private var playlistData = Data()
    private var isPlaylist = false
    private var headersSent = false
    private var remoteCompleted = false
    private var finished = false
    private var pending = Data()
    private var isSending = false
    private var isTaskSuspended = false

    init(
        connection: NWConnection,
        remoteURL: URL,
        sessionID: String,
        sessionHeaders: [String: String],
        requestHeaders: [String: String],
        method: String,
        localBase: String
    ) {
        self.connection = connection
        self.remoteURL = remoteURL
        self.sessionID = sessionID
        self.sessionHeaders = sessionHeaders
        self.requestHeaders = requestHeaders
        self.method = method
        self.localBase = localBase

        let operationQueue = OperationQueue()
        operationQueue.name = "top.strmaction.playback-proxy.session"
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInitiated
        delegateQueue = operationQueue

        super.init()
    }

    func start() {
        var request = URLRequest(
            url: remoteURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 120
        )
        request.httpMethod = method
        applyHeaders(to: &request)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true

        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        let dataTask = session.dataTask(with: request)
        stateQueue.sync {
            self.urlSession = session
            self.task = dataTask
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                self.stateQueue.async { [weak self] in
                    self?.cancel()
                }
            default:
                break
            }
        }

        dataTask.resume()
    }

    private func applyHeaders(to request: inout URLRequest) {
        let ignored: Set<String> = [
            "host", "connection", "proxy-connection", "keep-alive",
            "te", "trailer", "upgrade", "content-length",
            "transfer-encoding", "accept-encoding", "expect",
        ]

        var headers: [String: String] = [:]
        for (name, value) in requestHeaders where !ignored.contains(name.lowercased()) {
            headers[name] = value
        }
        // 播放接口给出的请求头优先级更高（例如 AList 需要的 Referer / Cookie / UA）。
        for (name, value) in sessionHeaders where !ignored.contains(name.lowercased()) {
            headers[name] = value
        }
        headers["Accept-Encoding"] = "identity"

        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func sendHeaders(statusCode: Int, responseHeaders: [String: String], forcedContentLength: Int? = nil) {
        guard !headersSent, !finished else { return }
        headersSent = true

        let allowed: Set<String> = [
            "content-type", "content-length", "content-range", "accept-ranges",
            "last-modified", "etag", "cache-control", "expires", "date",
            "content-disposition", "www-authenticate",
        ]

        var lines: [String] = []
        for (name, value) in responseHeaders where allowed.contains(name.lowercased()) {
            let clean = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            if !clean.isEmpty {
                lines.append("\(name): \(clean)")
            }
        }
        lines.removeAll { $0.lowercased().hasPrefix("content-length:") }

        if let forcedContentLength {
            lines.append("Content-Length: \(forcedContentLength)")
        } else if let length = responseHeaders.first(where: { $0.key.lowercased() == "content-length" })?.value {
            let clean = length.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            lines.append("Content-Length: \(clean)")
        }

        lines.append("Connection: close")

        let reason = Self.reasonPhrase(for: statusCode)
        let head = "HTTP/1.1 \(statusCode) \(reason)\r\n" + lines.joined(separator: "\r\n") + "\r\n\r\n"
        let data = Data(head.utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil, let self else { return }
            self.stateQueue.async { [weak self] in
                self?.cancel()
            }
        })
    }

    private func enqueue(_ data: Data) {
        guard !data.isEmpty, !finished else { return }
        pending.append(data)
        if pending.count > Self.maxPendingBytes {
            suspendTaskIfNeeded()
        }
        flush()
    }

    private func flush() {
        guard !finished else { return }
        guard !isSending, !pending.isEmpty else {
            if remoteCompleted, pending.isEmpty {
                finishClient()
            }
            return
        }

        let count = min(pending.count, 1024 * 1024)
        let chunk = pending.prefix(count)
        pending.removeFirst(count)
        isSending = true

        connection.send(content: Data(chunk), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.stateQueue.async { [weak self] in
                guard let self else { return }
                self.isSending = false
                if error != nil {
                    self.cancel()
                    return
                }
                if self.pending.count < Self.resumePendingBytes {
                    self.resumeTaskIfNeeded()
                }
                self.flush()
            }
        })
    }

    private func suspendTaskIfNeeded() {
        guard !isTaskSuspended, let task, task.state == .running else { return }
        task.suspend()
        isTaskSuspended = true
    }

    private func resumeTaskIfNeeded() {
        guard isTaskSuspended, let task, task.state == .suspended else { return }
        task.resume()
        isTaskSuspended = false
    }

    private func finishClient() {
        guard !finished else { return }
        finished = true
        isTaskSuspended = false
        task?.cancel()
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil

        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        isTaskSuspended = false
        task?.cancel()
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connection.cancel()
    }

    private func sendProxyError(status: Int, message: String) {
        guard !headersSent, !finished else {
            finishClient()
            return
        }
        let body = Data(message.utf8)
        sendHeaders(
            statusCode: status,
            responseHeaders: ["Content-Type": "text/plain; charset=utf-8"],
            forcedContentLength: body.count
        )
        enqueue(body)
        remoteCompleted = true
        flush()
    }

    // MARK: URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        acceptServerTrust(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        acceptServerTrust(challenge, completionHandler: completionHandler)
    }

    private func acceptServerTrust(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        redirected.httpMethod = method
        applyHeaders(to: &redirected)
        completionHandler(redirected)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            stateQueue.sync {
                self.sendProxyError(status: 502, message: "代理未收到有效的 HTTP 响应")
            }
            return
        }

        completionHandler(.allow)
        stateQueue.sync {
            self.handleResponse(http)
        }
    }

    private func handleResponse(_ http: HTTPURLResponse) {
        guard !finished else { return }
        httpResponse = http
        let finalURL = http.url ?? remoteURL
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let pathExtension = finalURL.pathExtension.lowercased()
        isPlaylist = pathExtension == "m3u8" || contentType.contains("mpegurl")

        if method == "HEAD" || http.statusCode == 204 || http.statusCode == 304 {
            sendHeaders(
                statusCode: http.statusCode,
                responseHeaders: Self.stringHeaders(http),
                forcedContentLength: Self.contentLength(http)
            )
            remoteCompleted = true
            flush()
            return
        }

        if !isPlaylist {
            sendHeaders(
                statusCode: http.statusCode,
                responseHeaders: Self.stringHeaders(http),
                forcedContentLength: Self.contentLength(http)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        stateQueue.sync {
            guard !self.finished else { return }
            if self.isPlaylist {
                self.playlistData.append(data)
                if self.playlistData.count > Self.maxPlaylistBytes {
                    self.sendProxyError(status: 502, message: "HLS 播放列表过大")
                }
            } else {
                self.enqueue(data)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateQueue.sync {
            self.handleComplete(error)
        }
    }

    private func handleComplete(_ error: Error?) {
        guard !finished else { return }

        if let error {
            if !headersSent {
                sendProxyError(status: 502, message: "代理请求失败: \(error.localizedDescription)")
            } else {
                remoteCompleted = true
                flush()
            }
            return
        }

        if isPlaylist {
            let finalURL = httpResponse?.url ?? remoteURL
            let original = String(data: playlistData, encoding: .utf8)
                ?? String(decoding: playlistData, as: UTF8.self)
            let rewritten = rewritePlaylist(original, baseURL: finalURL)
            let data = Data(rewritten.utf8)
            sendHeaders(
                statusCode: httpResponse?.statusCode ?? 200,
                responseHeaders: [
                    "Content-Type": "application/vnd.apple.mpegurl; charset=utf-8",
                ],
                forcedContentLength: data.count
            )
            enqueue(data)
        }

        remoteCompleted = true
        flush()
    }

    private func rewritePlaylist(_ text: String, baseURL: URL) -> String {
        let uriRegex = try? NSRegularExpression(pattern: "URI=\"([^\"]*)\"", options: [])
        var output: [String] = []
        output.reserveCapacity(text.components(separatedBy: "\n").count)

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                output.append(rawLine)
                continue
            }

            if trimmed.hasPrefix("#") {
                var rewritten = rawLine
                if let uriRegex {
                    let matches = uriRegex.matches(
                        in: rewritten,
                        range: NSRange(location: 0, length: rewritten.utf16.count)
                    )
                    for match in matches.reversed() {
                        guard let valueRange = Range(match.range(at: 1), in: rewritten) else { continue }
                        let value = String(rewritten[valueRange])
                        let local = localPlaylistURL(value, baseURL: baseURL)
                        rewritten.replaceSubrange(valueRange, with: local)
                    }
                }
                output.append(rewritten)
            } else {
                output.append(localPlaylistURL(trimmed, baseURL: baseURL))
            }
        }

        return output.joined(separator: "\n")
    }

    private func localPlaylistURL(_ value: String, baseURL: URL) -> String {
        guard !value.isEmpty,
              !value.lowercased().hasPrefix("data:"),
              !value.lowercased().hasPrefix("skd:")
        else {
            return value
        }
        guard let absolute = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let scheme = absolute.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return value
        }
        return InsecurePlaybackProxy.makeLocalURLString(
            base: localBase,
            sessionID: sessionID,
            remoteURL: absolute
        )
    }

    private static func stringHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key)] = String(describing: value)
        }
        return result
    }

    private static func contentLength(_ response: HTTPURLResponse) -> Int? {
        if let value = response.value(forHTTPHeaderField: "Content-Length") {
            return Int(value)
        }
        return response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Response"
        }
    }
}
