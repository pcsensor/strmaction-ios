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
            let ns = error as NSError
            var details = error.localizedDescription
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                details += " [\(ns.domain) \(ns.code), \(underlying.domain) \(underlying.code)]"
            } else {
                details += " [\(ns.domain) \(ns.code)]"
            }
            return "网络连接失败: \(details)"
        case .decodingError(let error):
            guard let decodingError = error as? DecodingError else {
                return "数据解析失败: \(error.localizedDescription)"
            }
            switch decodingError {
            case .keyNotFound(let key, let context):
                let path = Self.codingPath(context.codingPath + [key])
                return "数据解析失败: 缺少字段 \(path)"
            case .typeMismatch(let type, let context):
                let path = Self.codingPath(context.codingPath)
                return "数据解析失败: 字段 \(path) 类型不匹配，期望 \(type)"
            case .valueNotFound(let type, let context):
                let path = Self.codingPath(context.codingPath)
                return "数据解析失败: 字段 \(path) 缺少值，期望 \(type)"
            case .dataCorrupted(let context):
                let suffix = context.codingPath.isEmpty ? "" : "（字段 \(Self.codingPath(context.codingPath))）"
                return "数据解析失败: \(context.debugDescription)\(suffix)"
            @unknown default:
                return "数据解析失败: \(decodingError.localizedDescription)"
            }
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        let value = path.map { $0.stringValue }.joined(separator: ".")
        return value.isEmpty ? "<root>" : value
    }
}

/// 服务端 API 通道。
///
/// 只承载 KB 级负载（播放信息、字幕文本、健康检查）。**媒体字节绝不经过这里**，
/// 那条路径由 FFmpeg 自己的 HTTP/TLS 栈直接完成。
///
/// 信任判定统一交给 `SecurityPolicy`：与媒体通道共用同一套证书固定数据。
public final class PlayApi: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    public static let shared = PlayApi()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 30.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    // MARK: - 信任挑战

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        SecurityPolicy.handleServerTrust(challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        SecurityPolicy.handleServerTrust(challenge, completionHandler: completionHandler)
    }

    // MARK: - 健康检查

    public func checkHealth(serverUrl: String) async throws -> HealthResponse {
        guard let base = URL(string: serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let url = URL(string: "\(base.absoluteString)/api/health") else {
            throw PlayApiError.invalidServerUrl
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5.0)
        request.httpMethod = "GET"
        request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")

        do {
            let (data, response) = try await session.data(for: request)
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

    // MARK: - 播放信息

    public func fetchPlayInfo(
        serverUrl: String,
        itemId: Int,
        cookieString: String?,
        mode: String = "builtin"
    ) async throws -> PlayResponse {
        guard let base = URL(string: serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let url = URL(string: "\(base.absoluteString)/api/play/\(itemId)") else {
            throw PlayApiError.invalidServerUrl
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        request.setValue("StrmActionCompanion/\(appVersion) (iOS; Darwin)", forHTTPHeaderField: "User-Agent")

        if let cookie = cookieString, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let body: [String: Any] = ["mode": mode]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
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

    // MARK: - 字幕

    public func fetchSubtitleData(serverUrl: String, subtitlePath: String) async throws -> Data {
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

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        request.httpMethod = "GET"
        request.setValue("1", forHTTPHeaderField: "X-StrmAction-Companion")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw PlayApiError.badResponse(
                    statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    message: "字幕下载失败"
                )
            }
            return data
        } catch let err as PlayApiError {
            throw err
        } catch {
            throw PlayApiError.networkError(error)
        }
    }

    public func fetchSubtitleContent(serverUrl: String, subtitlePath: String) async throws -> String {
        let data = try await fetchSubtitleData(serverUrl: serverUrl, subtitlePath: subtitlePath)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
