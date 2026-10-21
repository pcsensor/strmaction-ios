import Foundation
import Security

/// 唯一的信任判定入口。
///
/// 信任来源只有两个，顺序固定，不存在运行时开关：
/// 1. 证书链能被系统公共根验证通过 → 走系统默认处理；
/// 2. 否则必须落到用户已导入的自签名根证书上，且主机名匹配。
///
/// 刻意**不再固定叶子证书**：Caddy 内部 CA 签发的叶子证书有效期只有 12 小时，
/// 固定它的指纹等于每半天失效一次。轮换时不变的是签发它的 CA，
/// 所以信任对象应该是 CA。
///
/// 判定标准与 FFmpeg 侧保持一致：`SecTrustSetAnchorCertificatesOnly(true)`，
/// 即锚点只有已导入的这些根，不用系统公共根——
/// 这正是 `ca_file` 替换默认信任库后的行为。
enum SecurityPolicy {
    // MARK: - URLSession 通道

    /// API 通道的信任判定。
    ///
    /// 与媒体通道共用同一份受信任根证书，不存在第二套策略。
    static func handleServerTrust(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let hostKey = TLSTrustStore.hostKey(host: host, port: challenge.protectionSpace.port)

        // 1. 公共 CA
        if CertificateTools.isPubliclyTrusted(trust) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 2. 已导入的自签名根
        let chain = CertificateTools.chain(from: trust)
        let anchors = TLSTrustStore.shared.anchorCertificates()
        let verdict = CertificateTools.evaluates(chain: chain, host: host, anchors: anchors)

        switch verdict {
        case .trusted:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .hostnameMismatch:
            D.log("trust", "\(hostKey) 证书与地址不匹配，拒绝连接")
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .broken(let detail):
            D.log("trust", "\(hostKey) 链校验失败，拒绝连接：\(detail)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - 媒体通道

    /// 确认该媒体地址的证书链能被信任，否则抛出可操作的错误。
    ///
    /// 这一步是**提前失败**：与其让 FFmpeg 在 130ms 后丢出一个
    /// "avformat can't open input"，不如在这里就把原因讲清楚。
    static func ensureTrusted(for url: URL) async throws {
        guard let host = url.host, !host.isEmpty else { return }
        guard url.scheme?.lowercased() == "https" else { return }

        let hostKey = TLSTrustStore.hostKey(host: host, port: url.port)
        let port = UInt16(url.port ?? 443)
        let capture = try await TLSProbe.capture(host: host, port: port)

        // 1. 公共 CA：证书轮换时不会牵连到我们，无需任何固定。
        if capture.isPubliclyTrusted {
            D.log("trust", "\(hostKey) 由公共 CA 签发，无需导入根证书")
            return
        }

        let chain = capture.chainDER.compactMap { CertificateTools.certificate(fromDER: $0) }
        guard !chain.isEmpty else {
            throw TrustError.noCertificate(hostKey: hostKey)
        }

        let anchors = TLSTrustStore.shared.anchorCertificates()
        let verdict = CertificateTools.evaluates(chain: chain, host: host, anchors: anchors)

        switch verdict {
        case .trusted:
            D.log("trust", "\(hostKey) 链校验通过 颁发者=\(capture.issuerName) 已导入根=\(anchors.count)")
        case .hostnameMismatch:
            throw TrustError.hostnameMismatch(hostKey: hostKey)
        case .broken(let detail):
            if anchors.isEmpty {
                throw TrustError.anchorMissing(hostKey: hostKey, issuer: capture.issuerName)
            }
            throw TrustError.chainInvalid(hostKey: hostKey, detail: detail)
        }
    }
}
