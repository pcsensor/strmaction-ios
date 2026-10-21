import Foundation

// MARK: - 播放阶段

/// 一次播放的确定性阶段。
///
/// 刻意不提供「重试中」「回退到某通道」之类的状态：
/// 任一阶段失败就进入 `.failed`，并携带**底层原始错误文本**，不做静默降级。
public enum PlaybackPhase: Equatable {
    case idle
    /// 正在向服务端请求播放数据
    case resolving
    /// 正在建立或复核证书固定关系
    case pinning(hostKey: String)
    /// 播放器正在连接媒体源
    case connecting
    /// 已连接，等待首帧
    case buffering
    case ready
    case failed(String)

    public var isTerminalFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 供 UI 展示的一句话状态。
    public var displayText: String {
        switch self {
        case .idle: return "待播放"
        case .resolving: return "正在获取播放信息…"
        case .pinning(let hostKey): return "正在校验 \(hostKey) 的证书…"
        case .connecting: return "正在连接媒体源…"
        case .buffering: return "正在缓冲…"
        case .ready: return "播放中"
        case .failed(let reason): return reason
        }
    }
}

// MARK: - 播放请求

/// 交给引擎的一次播放请求。证书信任关系在进入引擎前已经建立完毕。
public struct PlaybackRequest: Equatable {
    public let url: URL
    public let headers: [String: String]
    public let resumeMs: Int64
    /// 缓冲目标时长（秒）。
    ///
    /// 用时间而不是 MB：KSPlayer 的缓冲控制本来就是时间维度——
    /// `MEPlayerItem` 拿解码容量层的 `loadedTime` 与 `options.maxBufferDuration`
    /// 比较来决定暂停/恢复读取。MB 只有在知道码率时才能折算成时间，绕一圈还会算错。
    public let bufferTargetSeconds: Double

    public init(url: URL, headers: [String: String], resumeMs: Int64, bufferTargetSeconds: Double) {
        self.url = url
        self.headers = headers
        self.resumeMs = resumeMs
        self.bufferTargetSeconds = bufferTargetSeconds
    }

    /// 从服务端响应构造。URL 非法时返回 nil。
    public init?(playInfo: PlayResponse) {
        guard let url = URL(string: playInfo.playUrl) else { return nil }
        self.url = url
        self.headers = playInfo.safeHeaders
        self.resumeMs = max(0, playInfo.resumeMs)
        self.bufferTargetSeconds = PlaybackBufferPreference.seconds
    }
}

// MARK: - 缓冲偏好

/// 缓冲目标时长的唯一来源。
///
/// 服务端下发的 `cache_limit_mb` 不再参与：那个值是 MB，而真正起作用的
/// `maxBufferDuration` 是秒，中间缺一个码率，硬换算只会得到一个没有意义的数字。
/// 想要磁盘级缓存得先让 KSPlayer 的 `async:cache:` 协议对 https 生效，那是另一件事。
enum PlaybackBufferPreference {
    static let defaultsKey = "buffer_target_seconds"
    /// 设置页可选项（秒）。
    static let options: [Double] = [15, 30, 60, 120]
    static let defaultSeconds: Double = 60

    static var seconds: Double {
        let value = UserDefaults.standard.double(forKey: defaultsKey)
        guard value > 0 else { return defaultSeconds }
        return min(600, max(5, value))
    }
}
