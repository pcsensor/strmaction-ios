import Foundation
import Security

/// 唯一的信任判定入口。
///
/// 规则只有三条，顺序固定，不存在运行时开关：
/// 1. 该主机已有固定指纹 → 只认这一个指纹，不符即拒绝；
/// 2. 没有固定，但证书链能被系统公共根验证 → 走系统默认处理，不做固定；
/// 3. 没有固定且公共根无法验证（自签名 / 私有 CA）→ 首次使用即固定，然后放行。
///
/// 第 3 条就是 TOFU。它不是「关掉校验」，而是把这一次看到的证书钉死，
/// 之后任何不同的证书都会被拒绝。
enum SecurityPolicy {
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

        let hostKey = TLSTrustStore.hostKey(
            host: challenge.protectionSpace.host,
            port: challenge.protectionSpace.port
        )

        let chain = CertificateTools.chain(from: trust)
        guard let leaf = chain.first else {
            D.log("trust", "\(hostKey) 未返回证书，拒绝连接")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let leafDER = CertificateTools.der(from: leaf)
        let fingerprint = CertificateTools.sha256Fingerprint(of: leafDER)
        let store = TLSTrustStore.shared

        // 1. 已固定
        if let pin = store.pin(forHostKey: hostKey) {
            if pin.fingerprint == fingerprint {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                D.log("trust", "\(hostKey) 指纹不符，拒绝连接。固定=\(pin.shortFingerprint)… 实际=\(String(fingerprint.prefix(23)))…")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        // 2. 公共 CA 可验证，交给系统
        if CertificateTools.isPubliclyTrusted(trust) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 3. 自签名首次使用，固定后放行
        let pin = PinnedCertificate(
            hostKey: hostKey,
            fingerprint: fingerprint,
            pem: CertificateTools.pem(from: leafDER),
            subject: CertificateTools.subject(of: leaf),
            notAfter: CertificateTools.notAfter(of: leaf),
            pinnedAt: Date(),
            chainUsable: nil
        )
        store.store(pin)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// 确保指定 URL 的主机已建立固定关系。
    ///
    /// - 已是公共 CA：直接返回，不固定。
    /// - 已固定：用 `TLSProbe` 复验一次指纹，不符即抛错（绝不静默续播）。
    /// - 未固定：捕获并固定。
    @discardableResult
    static func ensurePinned(for url: URL) async throws -> PinnedCertificate? {
        guard let host = url.host, !host.isEmpty else { return nil }
        guard url.scheme?.lowercased() == "https" else { return nil }

        let port = UInt16(url.port ?? 443)
        let hostKey = TLSTrustStore.hostKey(host: host, port: url.port)
        let store = TLSTrustStore.shared

        let existing = store.pin(forHostKey: hostKey)
        let capture = try await TLSProbe.capture(host: host, port: port)

        if capture.isPubliclyTrusted {
            // 公共 CA：如果之前误固定过，撤掉，避免证书轮换后误报。
            if existing != nil {
                store.remove(hostKey: hostKey)
            }
            return nil
        }

        if let existing {
            guard existing.fingerprint == capture.fingerprint else {
                throw TrustError.fingerprintMismatch(
                    hostKey: hostKey,
                    expected: existing.shortFingerprint + "…",
                    actual: String(capture.fingerprint.prefix(23)) + "…"
                )
            }
            // 刷新「可链校验」结论，保证提示信息始终反映当前证书状态。
            if existing.chainUsable != capture.chainUsable {
                var refreshed = existing
                refreshed.chainUsable = capture.chainUsable
                store.store(refreshed)
                return refreshed
            }
            return existing
        }

        let pin = PinnedCertificate(
            hostKey: hostKey,
            fingerprint: capture.fingerprint,
            pem: capture.pem,
            subject: capture.subject,
            notAfter: capture.notAfter,
            pinnedAt: Date(),
            chainUsable: capture.chainUsable
        )
        store.store(pin)
        return pin
    }
}
