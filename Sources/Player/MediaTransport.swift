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

        // 1. 请求头
        //
        //    刻意不用 options.appendHeader()：它拼的是 "Key:Value\r\n"（冒号后没有空格），
        //    而 FFmpeg 的 http 协议用 has_header(s->headers, "\r\nUser-Agent: ") 判断
        //    是否已经带了 UA —— 那个判断是**带空格**的（has_header 内部只做
        //    av_stristart("/User-Agent: ") 与 av_stristr("\r\nUser-Agent: ")）。
        //    匹配不上时 FFmpeg 会再发一遍默认 UA（Lavf/x.y），请求里于是出现两个
        //    User-Agent，源站取第一个就拒了。
        //
        //    实测（同一 302 目标，1 字节 Range）：
        //      · 只有 pan.baidu.com          → 206
        //      · Lavf/60.16.100 + pan.baidu  → 403
        //      · 只有 Lavf/60.16.100         → 403
        //
        //    所以 UA 交给 http 协议的 user_agent 选项做唯一来源（它会生成格式正确、
        //    且只有一条的 User-Agent），其余头按 "Key: Value" 自己拼。
        let userAgent = request.headers
            .first { $0.key.lowercased() == "user-agent" }?
            .value
        if let userAgent, !userAgent.isEmpty {
            options.formatContextOptions["user_agent"] = userAgent
        }

        var headerLines = ""
        for (key, value) in request.headers.sorted(by: { $0.key < $1.key })
        where key.lowercased() != "user-agent" && !value.isEmpty {
            headerLines += "\(key): \(value)\r\n"
        }
        if !headerLines.isEmpty {
            options.formatContextOptions["headers"] = headerLines
        }

        // 2. TLS：真实的链校验，不是关闭校验。
        //    ca_file 会替换 FFmpeg 的默认信任库，因此 bundle 内同时包含
        //    公共根证书与用户导入的自签名根证书，覆盖「源站 → 302 → CDN」两跳。
        //
        //    这里放的是**根**，不是叶子：
        //    openssl 会顺着「叶子 → 中间 → 根」往上构建链，链顶端必须落在信任库里。
        //    中间证书当不了锚（FFmpeg 没开 X509_V_FLAG_PARTIAL_CHAIN），
        //    叶子证书更不行（它既不是 CA，还可能每 12 小时轮换一次）。
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
        // 真机验证看这一行：UA 必须是服务端下发的那个值，
        // 若显示「默认」说明服务端没下发 UA，FFmpeg 会用 Lavf/xx → 源站可能 403。
        let injectedUA = (options.formatContextOptions["user_agent"] as? String) ?? "默认"
        let extraHeaders = request.headers.keys
            .filter { $0.lowercased() != "user-agent" }
            .sorted()
            .joined(separator: ",")
        D.log("transport", "options ca_file=\(caBundlePath.split(separator: "/").last ?? "-") "
            + "存在=\(FileManager.default.fileExists(atPath: caBundlePath)) 大小=\(bundleSize) "
            + "受信任根=\(TLSTrustStore.shared.snapshot().count) "
            + "cache=\(options.cache) maxBuffer=\(options.maxBufferDuration)s "
            + "UA=\(injectedUA) 额外头=\(extraHeaders.isEmpty ? "无" : extraHeaders)")

        return options
    }
}
