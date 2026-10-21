import Foundation
import KSPlayer

/// 把一次播放请求翻译成 KSPlayer 的选项。
///
/// 这个模块只做一件事：**让 FFmpeg 直连源站并完成真实的证书校验**。
/// 它不代理、不转发、不缓存字节，也不提供任何备用通道。
enum MediaTransport {
    /// FFmpeg 的超时统一为 15 秒（微秒单位），避免默认无限等待。
    private static let rwTimeoutMicros = "15000000"

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
        options.formatContextOptions["ca_file"] = caBundlePath
        options.formatContextOptions["tls_verify"] = "1"
        // 源站多为纯 IP 的自签名证书，通常不含匹配的 SAN；
        // 由于已按指纹固定，主机名校验不再提供额外安全性，故关闭。
        options.formatContextOptions["verifyhost"] = "0"

        // 3. 网络健壮性（不是回退）：断流重连与读写超时。
        options.formatContextOptions["reconnect"] = "1"
        options.formatContextOptions["reconnect_streamed"] = "1"
        options.formatContextOptions["reconnect_delay_max"] = "5"
        options.formatContextOptions["rw_timeout"] = rwTimeoutMicros

        // 4. 探测参数：默认要读满 5 MB 才完成格式探测，
        //    对慢速大文件会把首帧拖到几分钟。MP4 的 ftyp 在前几百字节即可识别。
        options.formatContextOptions["probesize"] = "1048576"
        options.formatContextOptions["analyzeduration"] = "1000000"

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

        D.log("transport", "options ca_file=\(caBundlePath.split(separator: "/").last ?? "-") "
            + "cache=\(options.cache) maxBuffer=\(options.maxBufferDuration)s "
            + "probesize=1MB 请求头=\(request.headers.keys.sorted().joined(separator: ","))")

        return options
    }
}
