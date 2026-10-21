import Foundation
import KSPlayer

/// 把一次播放请求翻译成 KSPlayer 的选项。
///
/// 这个模块只做一件事：**让 FFmpeg 直连源站并完成真实的证书校验**。
/// 它不代理、不转发、不缓存字节，也不提供任何备用通道。
enum MediaTransport {
    /// 组装播放选项。
    ///
    /// - Parameter request: 已确定证书固定关系的播放请求。
    /// - Throws: 信任库不可用（缺少公共根证书等）时抛出，由上层进入 `.failed`。
    static func makeOptions(for request: PlaybackRequest) throws -> KSOptions {
        let caBundlePath = try TLSTrustStore.shared.caBundlePath()

        let options = KSOptions()

        // 1. 请求头：服务端下发的（UA / Referer / Cookie 等）原样带给 FFmpeg。
        options.appendHeader(request.headers)

        // 2. TLS：真实的链校验，不是关闭校验。
        //    ca_file 会替换 FFmpeg 的默认信任库，因此 bundle 内同时包含
        //    公共根证书与已固定的自签名证书，覆盖「源站 → 302 → CDN」两跳。
        //
        //    这里只放 TLS 必需的两项，其余一律不再注入：
        //    - 不设 verifyhost：它是 AV_OPT_TYPE_STRING（期望主机名），
        //      留空时 tls.c 会取 URI 的主机名，这正是要的行为。
        //    - 不设 protocol_whitelist：它会锁死可用协议。一旦系统配置了代理，
        //      FFmpeg 会走 httpproxy，白名单里没有就直接失败；
        //      而 ca_file 的读取本身在 whitelist 为 nil 时才不受限制。
        //    - 不覆盖 reconnect / probesize：KSPlayer 的 KSOptions 已给出合理默认。
        options.formatContextOptions["ca_file"] = caBundlePath
        options.formatContextOptions["tls_verify"] = "1"

        // 5. 播放行为
        options.isSeekedAutoPlay = true
        options.registerRemoteControll = false
        options.canStartPictureInPictureAutomaticallyFromInline = true

        // 6. 缓存
        let cacheMb = max(0, request.cacheLimitMb)
        options.cache = cacheMb > 0
        if cacheMb > 0 {
            let seconds = min(300.0, max(15.0, Double(cacheMb)))
            options.maxBufferDuration = seconds
            options.preferredForwardBufferDuration = min(seconds, max(3.0, seconds / 4))
        }

        // 7. 单一内核。
        //    刻意把 secondPlayerType 也设为 KSMEPlayer：KSPlayer 的类型列表若为空，
        //    会退回 AVFoundation，而 AVFoundation 无法处理自签名证书，
        //    那会变成一条注定失败的隐式回退路径。
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.useSystemHTTPProxy = false

        let bundleAttrs = try? FileManager.default.attributesOfItem(atPath: caBundlePath)
        let bundleSize = (bundleAttrs?[.size] as? NSNumber)?.intValue ?? 0
        D.log("transport", "options ca_file=\(caBundlePath.split(separator: "/").last ?? "-") "
            + "存在=\(FileManager.default.fileExists(atPath: caBundlePath)) 大小=\(bundleSize) "
            + "cache=\(options.cache) maxBuffer=\(options.maxBufferDuration)s "
            + "probesize=1MB 请求头=\(request.headers.keys.sorted().joined(separator: ","))")

        return options
    }
}
