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

/// 交给引擎的一次播放请求。证书固定关系在进入引擎前已经建立完毕。
public struct PlaybackRequest: Equatable {
    public let url: URL
    public let headers: [String: String]
    public let resumeMs: Int64
    public let cacheLimitMb: Int

    public init(url: URL, headers: [String: String], resumeMs: Int64, cacheLimitMb: Int) {
        self.url = url
        self.headers = headers
        self.resumeMs = resumeMs
        self.cacheLimitMb = cacheLimitMb
    }

    /// 从服务端响应构造。URL 非法时返回 nil。
    public init?(playInfo: PlayResponse) {
        guard let url = URL(string: playInfo.playUrl) else { return nil }
        self.url = url
        self.headers = playInfo.safeHeaders
        self.resumeMs = max(0, playInfo.resumeMs)
        self.cacheLimitMb = playInfo.safeCacheLimitMb
    }
}
