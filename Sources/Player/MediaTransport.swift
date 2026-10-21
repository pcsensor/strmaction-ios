import Foundation
import KSPlayer

/// 把一次播放请求翻译成 KSPlayer 的选项。
///
/// 现在交给 FFmpeg 的地址是本地缓存层（`http://127.0.0.1:<port>`），
/// 所以这里不再需要 `ca_file`——证书校验移到了 `OriginClient` 回源那一侧，
/// 用的是同一份 `TLSTrustStore` 根证书，没有第二套信任策略。
///
/// 唯一必须显式关掉的是 `options.cache`：本地地址是 http，
/// KSPlayer 会给它加上 `async:cache:` 前缀再套一层内存缓存。
/// 那一层是多余的——数据已经在磁盘上了，再在内存里存一份只会白占内存。
enum MediaTransport {
    static func makeOptions(for request: PlaybackRequest) -> KSOptions {
        let options = KSOptions()

        // 1. 磁盘缓存已经做了，不要再套 KSPlayer 的内存缓存
        options.cache = false

        // 2. 缓冲
        //
        //    只有 maxBufferDuration 对 MEPlayer 真实生效：
        //    MEPlayerItem 在 loadedTime > maxBufferDuration 时暂停读取，
        //    降到一半以下再恢复。preferredForwardBufferDuration 只被 KSAVPlayer 读取，
        //    而这里是单一内核 KSMEPlayer，设了也是死配置。
        let bufferSeconds = PlaybackBufferPreference.seconds(
            limitMb: request.bufferLimitMb,
            bitRate: PlaybackBufferPreference.observedBitRate
        )
        options.maxBufferDuration = bufferSeconds

        // 3. 播放行为
        options.isSeekedAutoPlay = true
        options.registerRemoteControll = false
        options.canStartPictureInPictureAutomaticallyFromInline = true

        // 4. 单一内核。
        //    刻意把 secondPlayerType 也设为 KSMEPlayer：KSPlayer 的类型列表若为空，
        //    会退回 AVFoundation，而那会绕开我们的缓存层，变成一条不可控的隐式路径。
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.useSystemHTTPProxy = false

        D.log("transport", "本地缓存播放 缓冲目标=\(Int(bufferSeconds))s(\(request.bufferLimitMb)MB) "
            + "磁盘上限=\(request.diskCacheLimitMb)MB 源=\(request.url.host ?? "-")")

        return options
    }
}
