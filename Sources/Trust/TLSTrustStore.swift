import Foundation
import Security

// MARK: - 受信任根证书

/// 一条用户显式导入的信任锚。
///
/// 关键约束：**必须是自签名证书**。
/// FFmpeg 的 TLS 后端没有开启 `X509_V_FLAG_PARTIAL_CHAIN`，
/// 中间证书当不了信任锚，放进去照样报 `unable to get issuer certificate`。
///
/// 之所以不再固定「叶子证书」：Caddy 内部 CA 签发的叶子证书有效期只有 12 小时，
/// 固定它的指纹等于装了一个每半天响一次的闹钟。证书轮换时 CA 不变，
/// 所以信任对象应该是 CA。
struct TrustedCA: Codable, Identifiable, Equatable {
    /// 大写、冒号分隔的 SHA-256，同时作为唯一标识。
    let fingerprint: String
    /// 证书主体摘要，仅用于 UI 展示。
    let subject: String
    /// 证书 PEM，用于拼进 FFmpeg 的 CA bundle。
    let pem: String
    let addedAt: Date

    var id: String { fingerprint }

    /// 供 UI 展示的短指纹。
    var shortFingerprint: String {
        fingerprint.split(separator: ":").prefix(8).joined(separator: ":")
    }
}

// MARK: - 导入错误

enum TrustAnchorError: LocalizedError {
    case noCertificate
    case noSelfSignedCertificate(String)

    var errorDescription: String? {
        switch self {
        case .noCertificate:
            return "没有解析到任何证书，请确认内容是 PEM 格式（-----BEGIN CERTIFICATE-----）。"
        case .noSelfSignedCertificate(let detail):
            return "\(detail)\n\n里面没有自签名证书。FFmpeg 只认自签名的根证书，"
                + "中间证书放进信任库依然会报 unable to get issuer certificate。请改导根证书。"
        }
    }
}

// MARK: - 信任库

/// 证书信任库：保存用户导入的自签名根证书，并生成 FFmpeg 使用的 CA bundle。
///
/// 这是整个私有 CA 方案**唯一**的信任来源：API 通道（URLSession 委托）与
/// 媒体通道（FFmpeg 的 `ca_file`）都从这里取同一份数据，不存在第二套策略。
///
/// 线程模型：内部状态由 `lock` 保护，任意线程可同步读取（`snapshot()`）；
/// `anchors` 这个 `@Published` 仅在主线程更新，供 SwiftUI 观察。
final class TLSTrustStore: ObservableObject {
    static let shared = TLSTrustStore()

    /// 供 SwiftUI 观察的镜像，只在主线程写入。
    @Published private(set) var anchors: [TrustedCA] = []

    private let lock = NSLock()
    private var storage: [TrustedCA] = []

    private let defaultsKey = "tls_trusted_anchors_v1"
    /// 旧版按主机固定叶子证书的键。语义已废弃，仅用于一次性清理。
    private let legacyKey = "tls_pinned_certificates"
    private let bundleFileName = "ca-bundle.pem"
    private var cachedBundlePath: String?

    private init() {
        dropLegacyPins()
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
    func snapshot() -> [TrustedCA] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isEmpty: Bool { snapshot().isEmpty }

    /// 把已导入的根证书还原成 `SecCertificate`，供 `SecTrust` 作为锚点使用。
    func anchorCertificates() -> [SecCertificate] {
        snapshot().compactMap { CertificateTools.certificates(fromPEM: $0.pem).first }
    }

    // MARK: 写入

    /// 导入 PEM 文本，返回成功导入的自签名根证书。
    ///
    /// 允许一次导入 CA bundle（多张证书）：其中非自签名的中间证书会被跳过，
    /// 因为它们在 FFmpeg 侧起不到信任锚的作用。
    @discardableResult
    func addAnchor(pem: String) throws -> [TrustedCA] {
        let certificates = CertificateTools.certificates(fromPEM: pem)
        guard !certificates.isEmpty else {
            throw TrustAnchorError.noCertificate
        }

        var imported: [TrustedCA] = []
        var skipped: [String] = []
        var duplicated = 0

        for certificate in certificates {
            guard CertificateTools.isSelfSigned(certificate) else {
                skipped.append(CertificateTools.subject(of: certificate))
                continue
            }
            let der = CertificateTools.der(from: certificate)
            let fingerprint = CertificateTools.sha256Fingerprint(of: der)
            lock.lock()
            let exists = storage.contains { $0.fingerprint == fingerprint }
            lock.unlock()
            if exists {
                duplicated += 1
                continue
            }
            imported.append(
                TrustedCA(
                    fingerprint: fingerprint,
                    subject: CertificateTools.subject(of: certificate),
                    pem: CertificateTools.pem(from: der),
                    addedAt: Date()
                )
            )
        }

        guard !imported.isEmpty else {
            let detail = skipped.isEmpty
                ? "这 \(duplicated) 张证书此前已经导入过。"
                : "已跳过的中间证书：\(skipped.joined(separator: "、"))"
            throw TrustAnchorError.noSelfSignedCertificate(detail)
        }

        lock.lock()
        for anchor in imported where !storage.contains(where: { $0.fingerprint == anchor.fingerprint }) {
            storage.append(anchor)
        }
        storage.sort { $0.subject < $1.subject }
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
        invalidateBundle()
        publishOnMain(snapshot)

        for anchor in imported {
            D.log("trust", "已信任根证书 \(anchor.subject) 指纹=\(anchor.shortFingerprint)…")
        }
        if !skipped.isEmpty {
            D.log("trust", "导入时跳过非自签名证书 \(skipped.count) 张（中间证书不能当信任锚）")
        }
        return imported
    }

    func removeAnchor(fingerprint: String) {
        lock.lock()
        guard let index = storage.firstIndex(where: { $0.fingerprint == fingerprint }) else {
            lock.unlock()
            return
        }
        let removed = storage.remove(at: index)
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
        invalidateBundle()
        publishOnMain(snapshot)
        D.log("trust", "已移除根证书 \(removed.subject) 指纹=\(removed.shortFingerprint)…")
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()

        persist([])
        invalidateBundle()
        publishOnMain([])
        D.log("trust", "已清空全部受信任根证书")
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

    /// 生成（或复用）CA bundle，内容 = 公共根证书 + 全部受信任根证书。
    ///
    /// FFmpeg 一旦设置 `ca_file` 就不再加载系统默认信任库，
    /// 因此公共根必须一并写进去，否则跳转到公共 CA 的 CDN 会校验失败。
    ///
    /// 这里放的是**根证书**而不是叶子证书：openssl 会顺着
    /// 叶子 → 中间 → 根 往上构建链，只有链顶端落在信任库里才算通过。
    func caBundlePath() throws -> String {
        lock.lock()
        let cached = cachedBundlePath
        let currentAnchors = storage
        lock.unlock()

        if let cached, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        guard let url = bundleURL else {
            throw TrustError.bundleUnavailable("无法定位缓存目录")
        }

        var contents = try publicRootsPEM()
        for anchor in currentAnchors {
            contents += "\n# trusted CA: \(anchor.subject)\n"
            contents += anchor.pem.hasSuffix("\n") ? anchor.pem : anchor.pem + "\n"
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
        D.log("trust", "CA bundle 就绪 受信任根证书=\(currentAnchors.count) 路径=\(path)")
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

    private func publishOnMain(_ value: [TrustedCA]) {
        if Thread.isMainThread {
            anchors = value
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.anchors = value
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([TrustedCA].self, from: data)
        else {
            lock.lock()
            storage = []
            lock.unlock()
            return
        }
        let sorted = decoded.sorted { $0.subject < $1.subject }
        lock.lock()
        storage = sorted
        lock.unlock()
        publishOnMain(sorted)
    }

    private func persist(_ value: [TrustedCA]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// 旧版按主机固定叶子证书。叶子证书会周期性轮换，那套数据留着只会误事。
    private func dropLegacyPins() {
        guard UserDefaults.standard.data(forKey: legacyKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: legacyKey)
        D.log("trust", "已清除旧版叶子证书固定记录（叶子证书会轮换），"
            + "请改为导入站点的自签名根证书。")
    }
}

// MARK: - 错误

enum TrustError: LocalizedError {
    case bundleUnavailable(String)
    /// 证书链无法落到任何一个已导入的自签名根上。
    case anchorMissing(hostKey: String, issuer: String)
    /// 链本身成立，但证书没有绑定当前访问的地址。
    case hostnameMismatch(hostKey: String)
    /// 链断裂或签名无效。
    case chainInvalid(hostKey: String, detail: String)
    case noCertificate(hostKey: String)

    var errorDescription: String? {
        switch self {
        case .bundleUnavailable(let detail):
            return "证书信任库不可用：\(detail)"
        case .anchorMissing(let hostKey, let issuer):
            return "\(hostKey) 的证书由私有 CA 签发（链上最高一级：\(issuer)），"
                + "但还没有导入它的自签名根证书。\n\n"
                + "在服务器上取根证书（任选一条）：\n"
                + "· curl -s http://127.0.0.1:2019/pki/ca/local\n"
                + "· Caddy 数据目录下的 pki/authorities/local/root.crt\n"
                + "然后在「设置 → 证书信任」里导入。\n\n"
                + "注意：必须是自签名的根证书。FFmpeg 不认中间证书当信任锚，"
        case .hostnameMismatch(let hostKey):
            return "\(hostKey) 的证书没有绑定这个地址（缺少对应的 subjectAltName）。"
                + "请为证书添加 SAN=IP 或改用域名后重新连接。"
        case .chainInvalid(let hostKey, let detail):
            return "\(hostKey) 的证书链校验失败：\(detail)"
        case .noCertificate(let hostKey):
            return "\(hostKey) 未返回任何证书"
        }
    }
}
