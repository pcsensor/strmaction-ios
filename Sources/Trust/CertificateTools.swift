import Foundation
import Security
import CryptoKit

/// 证书读取与评估的公共工具。
///
/// 这里只做「读取」和「按指定锚点评估」两件事，不做任何信任决策；
/// 决策统一在 `SecurityPolicy`。
enum CertificateTools {
    static func sha256Fingerprint(of der: Data) -> String {
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func pem(from der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    static func der(from certificate: SecCertificate) -> Data {
        SecCertificateCopyData(certificate) as Data
    }

    /// 取证书链（叶子在前）。iOS 15+ 用 `SecTrustCopyCertificateChain`。
    static func chain(from trust: SecTrust) -> [SecCertificate] {
        if let array = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !array.isEmpty {
            return array
        }
        let count = SecTrustGetCertificateCount(trust)
        guard count > 0 else { return [] }
        return (0..<count).compactMap { SecTrustGetCertificateAtIndex(trust, $0) }
    }

    static func subject(of certificate: SecCertificate) -> String {
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? "未知主体"
    }

    /// 证书到期时间。
    ///
    /// iOS 没有公开 API 读取单张证书的有效期字段：
    /// `SecCertificateCopyValues` 与 `kSecOIDX509V1ValidityNotAfter` 只在 macOS 提供。
    /// 这里返回 nil，UI 会自动隐藏该项。
    static func notAfter(of certificate: SecCertificate) -> Date? {
        nil
    }

    /// 该链能否被系统公共根验证通过。
    /// 通过 → 公共 CA 签发，无需导入根证书；失败 → 私有 CA，必须由已导入的根来兜。
    static func isPubliclyTrusted(_ trust: SecTrust) -> Bool {
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// 以给定的证书集合为**唯一**锚点，按 SSL 策略（含主机名）评估一条链。
    ///
    /// 刻意用 `SecTrustSetAnchorCertificatesOnly(true)` 关掉系统公共根：
    /// 这与 FFmpeg 侧 `ca_file` 替换默认信任库的行为一致，
    /// 所以这里的结论可以直接预测 FFmpeg 会不会通过。
    ///
    /// 注意锚点必须传**自签名根证书**。iOS 的 `SecTrust` 比 openssl 宽松
    /// （允许把链上任意一张证书设成锚点），所以「传进去就能过」不代表 FFmpeg 能过；
    /// 是否自签名由 `isSelfSigned` 单独把关。
    static func evaluates(
        chain: [SecCertificate],
        host: String,
        anchors: [SecCertificate]
    ) -> CertificateChainVerdict {
        guard !chain.isEmpty else { return .broken("链为空") }
        guard !anchors.isEmpty else { return .broken("没有任何信任锚") }

        // 第一道：只看链与有效期，不看主机名。过不了说明是信任/链的问题。
        guard evaluates(chain: chain, policy: SecPolicyCreateBasicX509(), anchors: anchors).isTrusted else {
            return .broken(describe(chain: chain, host: host, anchors: anchors))
        }

        // 第二道：加上主机名。到这里还失败，就是证书没绑定这个地址。
        guard evaluates(chain: chain, policy: SecPolicyCreateSSL(true, host as CFString), anchors: anchors).isTrusted else {
            return .hostnameMismatch
        }

        return .trusted
    }

    private static func evaluates(
        chain: [SecCertificate],
        policy: SecPolicy,
        anchors: [SecCertificate]
    ) -> (isTrusted: Bool, error: CFError?) {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(chain as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else { return (false, nil) }

        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        return (ok, error)
    }

    /// 把第一道评估失败的原因说清楚，方便直接看到「缺哪一级」。
    private static func describe(chain: [SecCertificate], host: String, anchors: [SecCertificate]) -> String {
        let names = chain.map { subject(of: $0) }
        let anchorNames = anchors.map { subject(of: $0) }
        return "链=[\(names.joined(separator: " → "))]，"
            + "已导入根=[\(anchorNames.joined(separator: "、"))]，主机=\(host)"
    }
}

/// 一次链式评估的结论。
enum CertificateChainVerdict {
    /// 链成立且主机名匹配，FFmpeg 侧应当能通过。
    case trusted
    /// 链成立，但证书没有绑定当前地址。
    case hostnameMismatch
    /// 链断裂、签名无效，或没有可用的信任锚。
    case broken(String)

    var isTrusted: Bool {
        if case .trusted = self { return true }
        return false
    }
}
