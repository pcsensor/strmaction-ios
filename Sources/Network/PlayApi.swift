import Foundation
import Security

public enum PlayApiError: LocalizedError {
    case invalidServerUrl
    case badResponse(statusCode: Int, message: String)
    case networkError(Error)
    case decodingError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidServerUrl:
            return "无效的服务器地址"
        case .badResponse(let statusCode, let message):
            return "服务器错误 (HTTP \(statusCode)): \(message)"
        case .networkError(let error):
            return "网络连接失败: \(error.localizedDescription)"
        case .decodingError(let error):
            return "数据解析失败: \(error.localizedDescription)"
        }
    }
}

public final class PlayApi: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    public static let shared = PlayApi()

    private lazy var insecureSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 30.0
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    // Session 级别认证挑战拦截
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleServerTrustChallenge(challenge, completionHandler: completionHandler)
    }

    // Task 级别认证挑战拦截（针对 Swift Concurrency data(for:delegate:)）
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleServerTrustChallenge(challenge, completionHandler: completionHandler)
    }

    /// 核心自签名与 IP 证书放行处理
    private func handleServerTrustChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1. 将策略重置为基础 X.509 结构策略，免去严格的标准 DNS 主机名匹配要求（支持纯 IP 直连）
        let basicPolicy = SecPolicyCreateBasicX509()
        SecTrustSetPolicies(serverTrust, basicPolicy)

        // 2. 将服务端发来的证书链本身置入锚点信任列表中，支持 Caddy 等自签名 Authority
        if let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate], !certChain.isEmpty {
            SecTrustSetAnchorCertificates(serverTrust, certChain as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, false)
        }

        // 3. 评估信任结果
        var error: CFError?
        _ = SecTrustEvaluateWithError(serverTrust, &error)

        // 4. 回传凭据完成 TLS 握手
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    private func getSession(allowInsecure: Bool) -> URLSession {
        return allowInsecure ? insecureSession : URLSession.shared
    }

    /// 测试服务器连通性（支持纯 IP 自签名证书）
    public func checkHealth(serverUrl: String, allowInsecure: Bool? = nil) async throws -> HealthResponse {
        guard let base = URL(string: serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let url = URL(string: "\(base.absoluteString)/api/health") else {
            throw PlayApiError.invalidServerUrl
        }

        let shouldAllowInsecure = allowInsecure ?? (UserDefaults.standard.object(forKey: "allow_insecure_http") as? Bool ?? true)
        let session = getSession(allowInsecure: shouldAllowInsecure)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5.0)
        request.httpMethod = "GET"
        request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")

        do {
            let (data, response) = try await session.data(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse else {
                throw PlayApiError.badResponse(statusCode: 0, message: "无有效响应")
            }
            guard (200...299).contains(http.statusCode) else {
                throw PlayApiError.badResponse(statusCode: http.statusCode, message: "健康检查失败")
            }
            return try JSONDecoder().decode(HealthResponse.self, from: data)
        } catch let err as PlayApiError {
            throw err
        } catch {
            throw PlayApiError.networkError(error)
        }
    }

    /// 请求播放数据（携带 Web 会话 Cookie）
    public func fetchPlayInfo(
        serverUrl: String,
        itemId: Int,
        cookieString: String?,
        mode: String = "builtin",
        allowInsecure: Bool? = nil
    ) async throws -> PlayResponse {
        guard let base = URL(string: serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let url = URL(string: "\(base.absoluteString)/api/play/\(itemId)") else {
            throw PlayApiError.invalidServerUrl
        }

        let shouldAllowInsecure = allowInsecure ?? (UserDefaults.standard.object(forKey: "allow_insecure_http") as? Bool ?? true)
        let session = getSession(allowInsecure: shouldAllowInsecure)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")
        request.setValue("StrmActionCompanion/1.0.0 (iOS; Darwin)", forHTTPHeaderField: "User-Agent")

        if let cookie = cookieString, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let body: [String: Any] = ["mode": mode]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse else {
                throw PlayApiError.badResponse(statusCode: 0, message: "无有效响应")
            }

            guard (200...299).contains(http.statusCode) else {
                if let errorObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errSub = errorObj["error"] as? [String: Any],
                   let msg = errSub["message"] as? String {
                    throw PlayApiError.badResponse(statusCode: http.statusCode, message: msg)
                }
                throw PlayApiError.badResponse(statusCode: http.statusCode, message: "状态码异常")
            }

            return try JSONDecoder().decode(PlayResponse.self, from: data)
        } catch let err as PlayApiError {
            throw err
        } catch let err as DecodingError {
            throw PlayApiError.decodingError(err)
        } catch {
            throw PlayApiError.networkError(error)
        }
    }

    /// 下载外挂字幕文本
    public func fetchSubtitleContent(serverUrl: String, subtitlePath: String, allowInsecure: Bool? = nil) async throws -> String {
        let fullUrlString: String
        if subtitlePath.lowercased().hasPrefix("http://") || subtitlePath.lowercased().hasPrefix("https://") {
            fullUrlString = subtitlePath
        } else {
            let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanPath = subtitlePath.hasPrefix("/") ? subtitlePath : "/\(subtitlePath)"
            fullUrlString = "\(base)\(cleanPath)"
        }

        guard let url = URL(string: fullUrlString) else {
            throw PlayApiError.invalidServerUrl
        }

        let shouldAllowInsecure = allowInsecure ?? (UserDefaults.standard.object(forKey: "allow_insecure_http") as? Bool ?? true)
        let session = getSession(allowInsecure: shouldAllowInsecure)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        request.httpMethod = "GET"
        request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")

        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlayApiError.badResponse(statusCode: 0, message: "字幕下载失败")
        }

        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
