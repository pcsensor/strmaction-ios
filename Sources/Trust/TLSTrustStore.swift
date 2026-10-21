import Foundation
import Security
import CryptoKit

// MARK: - 固定证书

/// 一条已固定的服务器证书。
///
/// 固定的对象是**叶子证书的 SHA-256 指纹**，而不是「是否信任」这个布尔值。
/// 指纹不符即握手失败，不做静默降级。
struct PinnedCertificate: Codable, Identifiable, Equatable {
    /// 形如 `211.101.246.235:15244`；443 端口省略，避免同一主机出现两条记录。
    let hostKey: String
    /// 大写、冒号分隔的 SHA-256，例如 `A1:B2:…`
    let fingerprint: String
    /// 叶子证书 PEM，用于拼进 FFmpeg 的 CA bundle。
    let pem: String
    /// 证书主体摘要，仅用于 UI 展示。
    let subject: String
    let notAfter: Date?
    let pinnedAt: Date
    /// 该证书能否作为锚点通过「链 + 主机名」校验。
    ///
    /// 为 false 说明证书没有绑定当前地址（缺 subjectAltName），
    /// 此时 FFmpeg 的 `tls_verify=1` 必然失败。用可选类型保持对旧记录的兼容。
    var chainUsable: Bool?

    var id: String { hostKey }

    /// 供 UI 展示的短指纹。
    var shortFingerprint: String {
        fingerprint.split(separator: ":").prefix(8).joined(separator: ":")
    }
}

// MARK: - 信任库

/// 证书固定库：持久化每个主机的固定证书，并生成 FFmpeg 使用的 CA bundle。
///
/// 这是整个自签名方案**唯一**的信任来源：API 通道（URLSession 委托）与
/// 媒体通道（FFmpeg 的 `ca_file`）都从这里取同一份数据，不存在第二套策略。
///
/// 线程模型：内部状态由 `lock` 保护，任意线程可同步读取（`snapshot()`）；
/// `pins` 这个 `@Published` 仅在主线程更新，供 SwiftUI 观察。
final class TLSTrustStore: ObservableObject {
    static let shared = TLSTrustStore()

    /// 供 SwiftUI 观察的镜像，只在主线程写入。
    @Published private(set) var pins: [PinnedCertificate] = []

    private let lock = NSLock()
    private var storage: [PinnedCertificate] = []

    private let defaultsKey = "tls_pinned_certificates"
    private let bundleFileName = "ca-bundle.pem"
    private var cachedBundlePath: String?

    private init() {
        load()
    }

    // MARK: 查询

    /// 端口 443 视为默认端口，不参与 key。
    static func hostKey(host: String, port: Int?) -> String {
        let normalizedHost = host.lowercased()
        guard let port, port > 0, port != 443 else { return normalizedHost }
        return "\(normalizedHost):\(port)"
    }

    /// 线程安全的快照，任意线程可调用。
    func snapshot() -> [PinnedCertificate] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func pin(forHostKey key: String) -> PinnedCertificate? {
        lock.lock()
        defer { lock.unlock() }
        return storage.first { $0.hostKey == key }
    }

    func pin(host: String, port: Int?) -> PinnedCertificate? {
        pin(forHostKey: Self.hostKey(host: host, port: port))
    }

    // MARK: 写入

    func store(_ certificate: PinnedCertificate) {
        lock.lock()
        storage.removeAll { $0.hostKey == certificate.hostKey }
        storage.append(certificate)
        storage.sort { $0.hostKey < $1.hostKey }
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
        invalidateBundle()
        publishOnMain(snapshot)
        D.log("trust", "已固定 \(certificate.hostKey) 指纹=\(certificate.shortFingerprint)…")
    }

    func remove(hostKey: String) {
        lock.lock()
        guard storage.contains(where: { $0.hostKey == hostKey }) else {
            lock.unlock()
            return
        }
        storage.removeAll { $0.hostKey == hostKey }
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
        invalidateBundle()
        publishOnMain(snapshot)
        D.log("trust", "已撤销固定 \(hostKey)")
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()

        persist([])
        invalidateBundle()
        publishOnMain([])
        D.log("trust", "已清空全部固定证书")
    }

    // MARK: FFmpeg 用的 CA bundle

    private var bundleURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches
            .appendingPathComponent("strmaction", isDirectory: true)
            .appendingPathComponent(bundleFileName)
    }

    private func invalidateBundle() {
        lock.lock()
        cachedBundlePath = nil
        lock.unlock()
    }

    /// 生成（或复用）CA bundle，内容 = 公共根证书 + 全部固定证书。
    ///
    /// FFmpeg 一旦设置 `ca_file` 就不再加载系统默认信任库，
    /// 因此公共根必须一并写进去，否则 302 跳转到公共 CA 的 CDN 会校验失败。
    func caBundlePath() throws -> String {
        lock.lock()
        let cached = cachedBundlePath
        let currentPins = storage
        lock.unlock()

        if let cached, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        guard let url = bundleURL else {
            throw TrustError.bundleUnavailable("无法定位缓存目录")
        }

        var contents = try publicRootsPEM()
        for pin in currentPins {
            contents += "\n# pinned: \(pin.hostKey)\n"
            contents += pin.pem.hasSuffix("\n") ? pin.pem : pin.pem + "\n"
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)

        let path = url.path
        lock.lock()
        cachedBundlePath = path
        lock.unlock()
        D.log("trust", "CA bundle 就绪 固定证书=\(currentPins.count) 路径=\(path)")
        return path
    }

    private func publicRootsPEM() throws -> String {
        // XcodeGen 会把 Resources 下的文件平铺到 bundle 根目录，同时保留子目录结构兜底。
        let candidates = [
            Bundle.main.url(forResource: "roots", withExtension: "pem"),
            Bundle.main.url(forResource: "roots", withExtension: "pem", subdirectory: "ca"),
        ].compactMap { $0 }

        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        throw TrustError.bundleUnavailable("缺少公共根证书 roots.pem")
    }

    // MARK: 持久化

    private func publishOnMain(_ value: [PinnedCertificate]) {
        if Thread.isMainThread {
            pins = value
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pins = value
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([PinnedCertificate].self, from: data)
        else {
            lock.lock()
            storage = []
            lock.unlock()
            return
        }
        let sorted = decoded.sorted { $0.hostKey < $1.hostKey }
        lock.lock()
        storage = sorted
        lock.unlock()
        publishOnMain(sorted)
    }

    private func persist(_ value: [PinnedCertificate]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - 错误

enum TrustError: LocalizedError {
    case bundleUnavailable(String)
    case fingerprintMismatch(hostKey: String, expected: String, actual: String)
    case noCertificate(hostKey: String)

    var errorDescription: String? {
        switch self {
        case .bundleUnavailable(let detail):
            return "证书信任库不可用：\(detail)"
        case .fingerprintMismatch(let hostKey, let expected, let actual):
            return "\(hostKey) 的证书指纹与固定值不符（固定 \(expected)，实际 \(actual)）"
        case .noCertificate(let hostKey):
            return "\(hostKey) 未返回任何证书"
        }
    }
}

// MARK: - 证书工具

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
    /// 这里返回 nil，UI 会自动隐藏该项；指纹固定本身不依赖有效期。
    static func notAfter(of certificate: SecCertificate) -> Date? {
        nil
    }

    /// 该链能否被系统公共根验证通过。
    /// 通过 → 公共 CA 签发，无需固定；失败 → 自签名或私有 CA，需要固定。
    static func isPubliclyTrusted(_ trust: SecTrust) -> Bool {
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// 以链上的叶子证书为唯一锚点，按 SSL 策略（含主机名）重新评估一次。
    ///
    /// 这正好模拟 FFmpeg 侧 `tls_verify=1` + `ca_file=<该证书>` 时的判定：
    /// 返回 false 说明即使证书文件正确，FFmpeg 仍会因主机名不匹配而握手失败。
    static func validatesAsAnchor(chain: [SecCertificate], host: String) -> Bool {
        guard let leaf = chain.first else { return false }
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            chain as CFArray,
            SecPolicyCreateSSL(true, host as CFString),
            &trust
        )
        guard status == errSecSuccess, let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
