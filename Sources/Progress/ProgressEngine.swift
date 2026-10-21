import Foundation
import Security

public final class ProgressEngine: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    public static let shared = ProgressEngine()

    private struct PendingReport {
        let serverUrl: String
        let itemId: Int
        let playToken: String
        let positionMs: Int64
        let durationMs: Int64
        let finished: Bool
    }

    private var queue: [PendingReport] = []
    private let lock = NSLock()
    private var isDraining = false
    public var onTokenExpired: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 15.0
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleServerTrustChallenge(challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleServerTrustChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleServerTrustChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let allowInsecure = UserDefaults.standard.object(forKey: "allow_insecure_http") as? Bool ?? true
        guard allowInsecure,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1. 设置允许基本 X.509 策略，支持纯 IP
        let basicPolicy = SecPolicyCreateBasicX509()
        SecTrustSetPolicies(serverTrust, basicPolicy)

        // 2. 将服务端证书置入锚点
        if let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate], !certChain.isEmpty {
            SecTrustSetAnchorCertificates(serverTrust, certChain as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, false)
        }

        var error: CFError?
        _ = SecTrustEvaluateWithError(serverTrust, &error)

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    /// 入队并触发异步上报
    public func report(
        serverUrl: String,
        itemId: Int,
        playToken: String,
        positionMs: Int64,
        durationMs: Int64,
        finished: Bool
    ) {
        let isActuallyFinished = finished || (durationMs > 0 && Double(positionMs) / Double(durationMs) >= 0.90)
        let report = PendingReport(
            serverUrl: serverUrl,
            itemId: itemId,
            playToken: playToken,
            positionMs: max(0, positionMs),
            durationMs: durationMs,
            finished: isActuallyFinished
        )

        lock.lock()
        queue.append(report)
        // 限制最多排队 3 条，避免网络堆积
        while queue.count > 3 {
            queue.removeFirst()
        }
        lock.unlock()

        Task {
            await self.drain()
        }
    }

    private func drain() async {
        lock.lock()
        guard !isDraining else {
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()

        while true {
            lock.lock()
            guard !queue.isEmpty else {
                isDraining = false
                lock.unlock()
                return
            }
            let current = queue.removeFirst()
            lock.unlock()

            let success = await send(report: current)
            if !success {
                // 如果失败且非401，保留下次重试的机会
                break
            }
        }

        lock.lock()
        isDraining = false
        lock.unlock()
    }

    private func send(report: PendingReport) async -> Bool {
        guard let base = URL(string: report.serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let url = URL(string: "\(base.absoluteString)/api/items/\(report.itemId)/progress") else {
            return false
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5.0)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(report.playToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")

        let body = ProgressReportBody(
            positionMs: report.positionMs,
            durationMs: report.durationMs,
            finished: report.finished
        )
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (_, response) = try await session.data(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse else { return false }

            if http.statusCode == 401 {
                DispatchQueue.main.async {
                    self.onTokenExpired?()
                }
                return false
            }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
