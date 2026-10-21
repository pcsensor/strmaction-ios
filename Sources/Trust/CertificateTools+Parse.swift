import Foundation
import Security

// MARK: - 证书解析

/// 证书解析扩展。
///
/// 存在的唯一理由：**openssl 只把自签名证书当作信任锚**。
/// FFmpeg 的 TLS 后端没有开启 `X509_V_FLAG_PARTIAL_CHAIN`，
/// 因此放进 `ca_file` 的必须是自签名的根证书；中间证书放进去照样报
/// `unable to get issuer certificate`。
///
/// iOS 的 `SecTrust` 比 openssl 宽松得多（允许把待验证链的任意一张证书设成锚点，
/// 甚至允许「自我锚定」），所以它**不能**用来判断一张证书能否当锚。
/// 这里直接读证书的 issuer / subject 原始编码，用「两者是否相同」来判定自签名，
/// 这是一条与 openssl 一致的硬标准。
extension CertificateTools {
    /// 从 PEM 文本解析出全部证书，顺序与文件一致。
    ///
    /// 支持单个文件里包含多张证书（CA bundle 的常见形态）。
    static func certificates(fromPEM text: String) -> [SecCertificate] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"

        var result: [SecCertificate] = []
        var rest = text[text.startIndex...]

        while let beginRange = rest.range(of: begin) {
            let afterBegin = rest[beginRange.upperBound...]
            guard let endRange = afterBegin.range(of: end) else { break }

            let body = afterBegin[..<endRange.lowerBound]
            let base64 = body.filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: String(base64)),
               let certificate = certificate(fromDER: data) {
                result.append(certificate)
            }
            rest = afterBegin[endRange.upperBound...]
        }
        return result
    }

    static func certificate(fromDER der: Data) -> SecCertificate? {
        SecCertificateCreateWithData(nil, der as CFData)
    }

    /// 证书的 issuer 与 subject 的原始 DER 编码（含 TLV 头），用于判断是否自签名。
    static func issuerAndSubjectDER(of certificate: SecCertificate) -> (issuer: Data, subject: Data)? {
        let bytes = [UInt8](der(from: certificate))

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        guard let outer = readTLV(bytes, at: 0), outer.tag == tagSequence else { return nil }
        guard let tbs = readTLV(bytes, at: outer.contentStart), tbs.tag == tagSequence else { return nil }

        var cursor = tbs.contentStart
        // version [0] EXPLICIT，v1 时缺席
        if let version = readTLV(bytes, at: cursor), version.tag == tagContext0 {
            cursor = version.end
        }
        // serialNumber INTEGER
        guard let serial = readTLV(bytes, at: cursor), serial.tag == tagInteger else { return nil }
        cursor = serial.end
        // signature AlgorithmIdentifier
        guard let signature = readTLV(bytes, at: cursor), signature.tag == tagSequence else { return nil }
        cursor = signature.end
        // issuer Name
        guard let issuer = readTLV(bytes, at: cursor), issuer.tag == tagSequence else { return nil }
        cursor = issuer.end
        // validity
        guard let validity = readTLV(bytes, at: cursor), validity.tag == tagSequence else { return nil }
        cursor = validity.end
        // subject Name
        guard let subject = readTLV(bytes, at: cursor), subject.tag == tagSequence else { return nil }

        return (
            Data(bytes[issuer.start..<issuer.end]),
            Data(bytes[subject.start..<subject.end])
        )
    }

    /// 是否自签名（issuer 与 subject 完全相同）。
    ///
    /// 只有返回 true 的证书才有资格作为 FFmpeg `ca_file` 里的信任锚。
    static func isSelfSigned(_ certificate: SecCertificate) -> Bool {
        guard let pair = issuerAndSubjectDER(of: certificate) else { return false }
        return pair.issuer == pair.subject
    }

    // MARK: 最小 ASN.1 读取

    private static let tagSequence: UInt8 = 0x30
    private static let tagInteger: UInt8 = 0x02
    private static let tagContext0: UInt8 = 0xA0

    private struct TLV {
        let tag: UInt8
        let start: Int
        let contentStart: Int
        let end: Int
    }

    /// 读取一个 TLV（tag + 长度 + 内容）。长度支持短形式与长形式。
    private static func readTLV(_ bytes: [UInt8], at index: Int) -> TLV? {
        guard index < bytes.count else { return nil }
        let tag = bytes[index]
        var cursor = index + 1
        guard cursor < bytes.count else { return nil }

        let first = bytes[cursor]
        cursor += 1
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let byteCount = Int(first & 0x7F)
            guard byteCount >= 1, byteCount <= 4, cursor + byteCount <= bytes.count else { return nil }
            for _ in 0..<byteCount {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }

        let contentStart = cursor
        let end = contentStart + length
        guard end <= bytes.count else { return nil }
        return TLV(tag: tag, start: index, contentStart: contentStart, end: end)
    }
}
