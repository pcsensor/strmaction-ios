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
    /// 缓冲上限（MB）。
    ///
    /// 用户按容量设置，引擎按时间执行：`MEPlayerItem` 拿 `loadedTime` 与
    /// `options.maxBufferDuration` 比较来决定暂停/恢复读取。
    /// 两者之间靠码率折算，见 `PlaybackBufferPreference.seconds(limitMb:bitRate:)`。
    public let bufferLimitMb: Int
    /// 磁盘缓存上限（MB）。一次播放会话用多少磁盘存已拉取的数据。
    public let diskCacheLimitMb: Int

    public init(
        url: URL,
        headers: [String: String],
        resumeMs: Int64,
        bufferLimitMb: Int,
        diskCacheLimitMb: Int
    ) {
        self.url = url
        self.headers = headers
        self.resumeMs = resumeMs
        self.bufferLimitMb = bufferLimitMb
        self.diskCacheLimitMb = diskCacheLimitMb
    }

    /// 从服务端响应构造。URL 非法时返回 nil。
    public init?(playInfo: PlayResponse) {
        guard let url = URL(string: playInfo.playUrl) else { return nil }
        self.url = url
        self.headers = playInfo.safeHeaders
        self.resumeMs = max(0, playInfo.resumeMs)
        self.bufferLimitMb = PlaybackBufferPreference.limitMb
        self.diskCacheLimitMb = DiskCachePreference.limitMb
    }
}

// MARK: - 磁盘缓存偏好

/// 一次播放会话可用的磁盘缓存上限。
///
/// 会话结束时整目录删除，所以这个值只需要装得下「当前这一部片子已经看过的部分」。
enum DiskCachePreference {
    static let defaultsKey = "disk_cache_limit_mb"
    static let presets: [Int] = [512, 1024, 2048, 4096, 8192]
    static let defaultLimitMb = 2048
    static let minLimitMb = 128
    static let maxLimitMb = 32768

    static var limitMb: Int {
        let value = UserDefaults.standard.integer(forKey: defaultsKey)
        guard value > 0 else { return defaultLimitMb }
        return clamp(value)
    }

    static func clamp(_ value: Int) -> Int {
        min(maxLimitMb, max(minLimitMb, value))
    }
}

// MARK: - 缓冲偏好

/// 缓冲设置的唯一来源：**按 MB 配置，按秒执行**。
///
/// - 用户输入的是容量（MB），因为那才是他关心的"占多少内存"；
/// - 引擎需要的是时间（秒），因为 `maxBufferDuration` 是时间窗口；
/// - 两者靠码率换算：`秒 = MB × 8 × 1024 × 1024 ÷ 码率bps`。
///
/// 码率必须等 `avformat_open_input` 解析完轨道才有，所以首帧之前先用
/// 上一次观测到的码率估算（`observedBitRate`），ready 之后再用真实值校正。
enum PlaybackBufferPreference {
    static let defaultsKey = "buffer_limit_mb"
    /// 设置页固定档位（MB）。
    static let presets: [Int] = [64, 128, 256, 512]
    static let defaultLimitMb = 128
    static let minLimitMb = 16
    static let maxLimitMb = 4096

    static var limitMb: Int {
        let value = UserDefaults.standard.integer(forKey: defaultsKey)
        guard value > 0 else { return defaultLimitMb }
        return clamp(value)
    }

    static func clamp(_ value: Int) -> Int {
        min(maxLimitMb, max(minLimitMb, value))
    }

    // MARK: 码率

    private static let bitRateKey = "buffer_observed_bitrate"
    /// 没有任何观测值时的保守估计。
    static let fallbackBitRate: Double = 8_000_000

    static var observedBitRate: Double {
        let value = UserDefaults.standard.double(forKey: bitRateKey)
        return value > 0 ? value : fallbackBitRate
    }

    static func rememberBitRate(_ bitRate: Double) {
        guard bitRate.isFinite, bitRate > 0 else { return }
        UserDefaults.standard.set(bitRate, forKey: bitRateKey)
    }

    // MARK: 换算

    /// 把「缓冲上限 MB」折算成 `maxBufferDuration` 需要的秒数。
    static func seconds(limitMb: Int, bitRate: Double) -> Double {
        let bytes = Double(clamp(limitMb)) * 1024 * 1024
        let rate = bitRate > 0 ? bitRate : fallbackBitRate
        let raw = bytes * 8 / rate
        return min(3600, max(5, raw))
    }

    /// 按最近观测到的码率折算当前设置。
    static func secondsForCurrentLimit() -> Double {
        seconds(limitMb: limitMb, bitRate: observedBitRate)
    }
}
