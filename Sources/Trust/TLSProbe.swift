import Foundation
import Network
import Security

// MARK: - 捕获结果

/// 一次 TLS 探测捕获到的证书信息。
///
/// 探测只完成 TLS 握手，不发送任何业务数据，因此不会产生额外流量。
struct TLSCapture {
    let hostKey: String
    let leafDER: Data
    let chainDER: [Data]
    let subject: String
    let notAfter: Date?
    /// 该链能否被系统公共根验证通过。
    let isPubliclyTrusted: Bool
    /// 链上最高一级证书的主体，用于「请导入这个 CA 的根证书」这类提示。
    ///
    /// 服务器按惯例不发送自签名根，所以这里通常拿到的是中间证书的名字。
    let issuerName: String

    var fingerprint: String {
        CertificateTools.sha256Fingerprint(of: leafDER)
    }

    var pem: String {
        CertificateTools.pem(from: leafDER)
    }
}

// MARK: - 错误

enum TLSProbeError: LocalizedError {
    case invalidPort(UInt16)
    case connectFailed(String)
    case timedOut(String)
    case noCertificate(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "无效端口 \(port)"
        case .connectFailed(let detail):
            return "TLS 连接失败：\(detail)"
        case .timedOut(let hostKey):
            return "\(hostKey) 的 TLS 握手超时"
        case .noCertificate(let hostKey):
            return "\(hostKey) 未返回证书"
        }
    }
}

// MARK: - 探针

/// 用 `NWConnection` 对目标主机做一次 TLS 握手，取回证书链。
///
/// 这是信任判定的数据来源（握一次手，看看对方拿出了哪些证书）。
/// 校验由 `SecurityPolicy` 统一决策，探针本身只负责「拿到证书」，不做信任判断。
enum TLSProbe {
    static func capture(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> TLSCapture {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TLSProbeError.invalidPort(port)
        }

        let hostKey = TLSTrustStore.hostKey(host: host, port: Int(port))
        D.log("probe", "开始 TLS 探测 \(hostKey)")

        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_add_tls_application_protocol(secOptions, "http/1.1")

        let box = TrustBox()
        sec_protocol_options_set_verify_block(secOptions, { _, secTrustRef, complete in
            // 只捕获证书链，不做信任判断；放行握手以便拿到完整链。
            let trust = sec_trust_copy_ref(secTrustRef).takeRetainedValue()
            box.set(trust)
            complete(true)
        }, DispatchQueue.global(qos: .userInitiated))

        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )

        let outcome: Result<SecTrust, Error> = await withCheckedContinuation { continuation in
            let once = ResumeGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if let trust = box.get() {
                        continuation.resume(returning: .success(trust))
                    } else {
                        continuation.resume(returning: .failure(TLSProbeError.noCertificate(hostKey)))
                    }
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(returning: .failure(TLSProbeError.connectFailed(error.localizedDescription)))
                case .waiting(let error):
                    guard once.claim() else { return }
                    continuation.resume(returning: .failure(TLSProbeError.connectFailed(error.localizedDescription)))
                default:
                    break
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                continuation.resume(returning: .failure(TLSProbeError.timedOut(hostKey)))
            }

            connection.start(queue: DispatchQueue(label: "top.strmaction.tls-probe", qos: .userInitiated))
        }

        connection.cancel()

        switch outcome {
        case .failure(let error):
            D.log("probe", "探测失败 \(hostKey): \(error.localizedDescription)")
            throw error
        case .success(let trust):
            let chain = CertificateTools.chain(from: trust)
            guard let leaf = chain.first else {
                throw TLSProbeError.noCertificate(hostKey)
            }
            // 链上第二张就是叶子的签发者；只有一张时它本身是自签名的。
            let issuerName = CertificateTools.subject(of: chain.count > 1 ? chain[1] : leaf)
            let capture = TLSCapture(
                hostKey: hostKey,
                leafDER: CertificateTools.der(from: leaf),
                chainDER: chain.map { CertificateTools.der(from: $0) },
                subject: CertificateTools.subject(of: leaf),
                notAfter: CertificateTools.notAfter(of: leaf),
                isPubliclyTrusted: CertificateTools.isPubliclyTrusted(trust),
                issuerName: issuerName
            )

            D.log("probe", "探测成功 \(hostKey) 公共CA=\(capture.isPubliclyTrusted) "
                + "链长=\(chain.count) 颁发者=\(issuerName) 主体=\(capture.subject)")
            if !capture.isPubliclyTrusted {
                D.log("probe", "私有 CA：链能否成立取决于是否已导入对应根证书，由 SecurityPolicy 判定")
            }
            return capture
        }
    }
}

// MARK: - 并发小工具

/// 跨队列持有 `SecTrust`。
private final class TrustBox {
    private let lock = NSLock()
    private var trust: SecTrust?

    func set(_ value: SecTrust) {
        lock.lock()
        trust = value
        lock.unlock()
    }

    func get() -> SecTrust? {
        lock.lock()
        defer { lock.unlock() }
        return trust
    }
}

/// 保证 continuation 只被 resume 一次。
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
