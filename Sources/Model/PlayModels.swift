import Foundation

/// 播放接口响应数据模型（对齐服务端 POST /api/play/{itemId}）
public struct PlayResponse: Codable {
    public let mode: String
    public let requestedMode: String?
    public let downgraded: Bool?
    public let downgradeReason: String?
    public let itemId: Int
    public let kind: String?
    public let seriesId: Int?
    public let seriesTitle: String?
    public let title: String
    public let library: String?
    public let playUrl: String
    public let resumeMs: Int64
    public let durationMs: Int64?
    public let headers: [String: String]
    public let headersHint: String?
    public let playToken: String
    public let playTokenExpiresAt: Double?
    public let progressIntervalMs: Int64
    public let cacheLimitMb: Int
    public let fallbackOnError: Bool
    public let mediaFileId: Int?
    public let nextItemId: Int?
    public let nextTitle: String?
    public let nextEpisodeCode: String?
    public let subtitles: [SubtitleEntry]
    public let playlist: [PlaylistItem]
    public let currentIndex: Int

    enum CodingKeys: String, CodingKey {
        case mode
        case requestedMode = "requested_mode"
        case downgraded
        case downgradeReason = "downgrade_reason"
        case itemId = "item_id"
        case kind
        case seriesId = "series_id"
        case seriesTitle = "series_title"
        case title
        case library
        case playUrl = "play_url"
        case resumeMs = "resume_ms"
        case durationMs = "duration_ms"
        case headers
        case headersHint = "headers_hint"
        case playToken = "play_token"
        case playTokenExpiresAt = "play_token_expires_at"
        case progressIntervalMs = "progress_interval_ms"
        case cacheLimitMb = "cache_limit_mb"
        case fallbackOnError = "fallback_on_error"
        case mediaFileId = "media_file_id"
        case nextItemId = "next_item_id"
        case nextTitle = "next_title"
        case nextEpisodeCode = "next_episode_code"
        case subtitles
        case playlist
        case currentIndex = "current_index"
    }
}

/// 选集列表条目
public struct PlaylistItem: Codable, Identifiable {
    public let id: Int
    public let title: String
    public let seasonNo: Int?
    public let episodeNo: Int?
    public let code: String?
    public let watched: Bool
    public let current: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case seasonNo = "season_no"
        case episodeNo = "episode_no"
        case code
        case watched
        case current
    }

    /// 友好展示标签
    public var displayLabel: String {
        let prefix = code ?? (episodeNo != nil ? "第 \(episodeNo!) 集" : "")
        if !prefix.isEmpty && !title.isEmpty && title != prefix {
            return "\(prefix)  \(title)"
        }
        return prefix.isEmpty ? title : prefix
    }
}

/// 字幕信息条目
public struct SubtitleEntry: Codable, Identifiable {
    public var id: String { url }
    public let label: String
    public let lang: String
    public let filename: String?
    public let format: String?
    public let mime: String?
    public let url: String
}

/// 健康检查响应
public struct HealthResponse: Codable {
    public let ok: Bool
    public let version: String?
}

/// 进度上报请求体
public struct ProgressReportBody: Codable {
    public let positionMs: Int64
    public let durationMs: Int64
    public let finished: Bool

    enum CodingKeys: String, CodingKey {
        case positionMs = "position_ms"
        case durationMs = "duration_ms"
        case finished
    }
}
