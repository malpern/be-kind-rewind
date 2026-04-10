import Foundation
import TaggingKit

// MARK: - Display Mode Enums

enum TopicDisplayMode: String, CaseIterable, Sendable {
    case saved
    case watchCandidates

    var label: String {
        switch self {
        case .saved:
            return "Saved"
        case .watchCandidates:
            return "Watch"
        }
    }

    var symbolName: String {
        switch self {
        case .saved:
            return "square.stack"
        case .watchCandidates:
            return "sparkles.tv"
        }
    }
}

enum WatchPresentationMode: String, CaseIterable, Sendable {
    case byTopic
    case allTogether

    var label: String {
        switch self {
        case .byTopic:
            return "By Topic"
        case .allTogether:
            return "Show All"
        }
    }

    var symbolName: String {
        switch self {
        case .byTopic:
            return "square.grid.3x3.topleft.filled"
        case .allTogether:
            return "rectangle.stack"
        }
    }
}

// MARK: - Progress & State

struct CandidateProgressOverlayState: Equatable {
    let topicId: Int64
    let topicName: String
    let progress: Double
    let title: String
    let detail: String
}

// MARK: - Typeahead

struct TypeaheadSuggestion: Identifiable {
    enum Kind { case topic, subtopic, channel }
    let kind: Kind
    let text: String
    let count: Int
    let topicId: Int64?
    var parentName: String? = nil
    var id: String { "\(kind)-\(text)" }

    var icon: String {
        switch kind {
        case .topic: return TopicTheme.iconName(for: text)
        case .subtopic: return "arrow.turn.down.right"
        case .channel: return "person.circle.fill"
        }
    }

    var displayText: String {
        if let parent = parentName {
            return "\(text) — \(parent)"
        }
        return text
    }
}

struct QuickNavigatorItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case topic
        case subtopic
        case playlist
    }

    let kind: Kind
    let title: String
    let subtitle: String?
    let countText: String?
    let topicId: Int64?
    let parentTopicId: Int64?
    let playlist: PlaylistRecord?

    var id: String {
        switch kind {
        case .topic:
            return "topic:\(topicId ?? -1)"
        case .subtopic:
            return "subtopic:\(topicId ?? -1)"
        case .playlist:
            return "playlist:\(playlist?.playlistId ?? title)"
        }
    }

    var iconName: String {
        switch kind {
        case .topic:
            return TopicTheme.iconName(for: title)
        case .subtopic:
            return "arrow.turn.down.right"
        case .playlist:
            return "music.note.list"
        }
    }

    var sectionTitle: String {
        switch kind {
        case .topic:
            return "Topics"
        case .subtopic:
            return "Subtopics"
        case .playlist:
            return "Playlists"
        }
    }

    static func == (lhs: QuickNavigatorItem, rhs: QuickNavigatorItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Topic

struct TopicViewModel: Identifiable, Hashable {
    let id: Int64
    var name: String
    var videoCount: Int
    var parentId: Int64? = nil
    var subtopics: [TopicViewModel] = []

    static func == (lhs: TopicViewModel, rhs: TopicViewModel) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.videoCount == rhs.videoCount && lhs.subtopics.map(\.id) == rhs.subtopics.map(\.id)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Video

struct VideoViewModel: Identifiable, Hashable {
    let videoId: String
    let title: String
    let channelName: String?
    let videoUrl: String?
    let sourceIndex: Int
    let topicId: Int64?
    let viewCount: String?
    let publishedAt: String?
    let duration: String?
    let channelIconUrl: String?
    let channelId: String?

    var id: String { videoId }

    var youtubeUrl: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoId)")
    }

    var thumbnailUrl: URL? {
        guard let vid = videoUrl.flatMap({ URL(string: $0) })?.queryItems?["v"] ?? videoId.nilIfEmpty else {
            return nil
        }
        return URL(string: "https://i.ytimg.com/vi/\(vid)/mqdefault.jpg")
    }

    init(from stored: TaggingKit.StoredVideo) {
        self.videoId = stored.videoId
        self.title = stored.title ?? "Untitled"
        self.channelName = stored.channelName
        self.videoUrl = stored.videoUrl
        self.sourceIndex = stored.sourceIndex
        self.topicId = stored.topicId
        self.viewCount = stored.viewCount
        self.publishedAt = stored.publishedAt
        self.duration = stored.duration
        self.channelIconUrl = stored.channelIconUrl
        self.channelId = stored.channelId
    }

    init(videoId: String, title: String, channelName: String?, videoUrl: String?, sourceIndex: Int, topicId: Int64?, viewCount: String?, publishedAt: String?, duration: String?, channelIconUrl: String?, channelId: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.channelName = channelName
        self.videoUrl = videoUrl
        self.sourceIndex = sourceIndex
        self.topicId = topicId
        self.viewCount = viewCount
        self.publishedAt = publishedAt
        self.duration = duration
        self.channelIconUrl = channelIconUrl
        self.channelId = channelId
    }

    init(from candidate: CandidateVideoViewModel) {
        self.videoId = candidate.videoId
        self.title = candidate.title
        self.channelName = candidate.channelName
        self.videoUrl = "https://www.youtube.com/watch?v=\(candidate.videoId)"
        self.sourceIndex = -1
        self.topicId = candidate.topicId
        self.viewCount = candidate.viewCount
        self.publishedAt = candidate.publishedAt
        self.duration = candidate.duration
        self.channelIconUrl = candidate.channelIconUrl
        self.channelId = candidate.channelId
    }
}

struct InspectedVideoViewModel {
    let video: VideoViewModel
    let playlists: [PlaylistRecord]
    let isWatchCandidate: Bool
    let seenSummary: SeenVideoSummary?
}

struct ChannelPresentation {
    let name: String?
    let channelUrl: String?
    let iconUrl: String?
    let iconData: Data?
}

// MARK: - Candidate

struct CandidateVideoViewModel: Identifiable, Hashable {
    let topicId: Int64
    let videoId: String
    let title: String
    let channelId: String?
    let channelName: String?
    let viewCount: String?
    let publishedAt: String?
    let duration: String?
    let channelIconUrl: String?
    let score: Double
    let secondaryText: String?
    let state: String
    let isPlaceholder: Bool

    var id: String { "\(topicId)-\(videoId)" }

    var thumbnailUrl: URL? {
        guard !isPlaceholder else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }

    var assignmentStrength: Int {
        guard let secondaryText else { return 0 }
        if secondaryText.contains("creator already in this topic") || secondaryText.contains("connected to this topic and your saved playlists") {
            return 3
        }
        if secondaryText.contains("matched a topic search") || secondaryText.contains("search match for this topic") {
            return 2
        }
        if secondaryText.contains("adjacent to this topic") || secondaryText.contains("related creator") {
            return 1
        }
        return 0
    }

    init(
        topicId: Int64,
        videoId: String,
        title: String,
        channelId: String?,
        channelName: String?,
        viewCount: String?,
        publishedAt: String?,
        duration: String?,
        channelIconUrl: String?,
        score: Double,
        secondaryText: String?,
        state: String,
        isPlaceholder: Bool
    ) {
        self.topicId = topicId
        self.videoId = videoId
        self.title = title
        self.channelId = channelId
        self.channelName = channelName
        self.viewCount = viewCount
        self.publishedAt = publishedAt
        self.duration = duration
        self.channelIconUrl = channelIconUrl
        self.score = score
        self.secondaryText = secondaryText
        self.state = state
        self.isPlaceholder = isPlaceholder
    }

    init(from stored: TopicCandidate) {
        self.init(
            topicId: stored.topicId,
            videoId: stored.videoId,
            title: stored.title,
            channelId: stored.channelId,
            channelName: stored.channelName,
            viewCount: stored.viewCount,
            publishedAt: stored.publishedAt,
            duration: stored.duration,
            channelIconUrl: stored.channelIconUrl,
            score: stored.score,
            secondaryText: stored.reason,
            state: stored.state,
            isPlaceholder: false
        )
    }

    static func placeholder(topicId: Int64, title: String, message: String) -> CandidateVideoViewModel {
        CandidateVideoViewModel(
            topicId: topicId,
            videoId: "candidate-placeholder-\(topicId)-\(title)",
            title: title,
            channelId: nil,
            channelName: nil,
            viewCount: nil,
            publishedAt: nil,
            duration: nil,
            channelIconUrl: nil,
            score: 0,
            secondaryText: message,
            state: CandidateState.candidate.rawValue,
            isPlaceholder: true
        )
    }
}

// MARK: - Creator Detail

struct CreatorDetailViewModel {
    let channelName: String
    let channelIconUrl: String?
    let channelIconData: Data?
    let totalVideoCount: Int
    let totalViews: Int
    let newestAge: String?
    let oldestAge: String?
    let recentCount: Int           // videos from last 30 days
    let subscriberCount: Int?      // from channel record
    let totalUploads: Int?         // total videos on their channel
    let videosByTopic: [(topicName: String, videos: [VideoViewModel])]

    var formattedViews: String {
        if totalViews >= 1_000_000 {
            return String(format: "%.1fM views", Double(totalViews) / 1_000_000)
        } else if totalViews >= 1_000 {
            return String(format: "%.0fK views", Double(totalViews) / 1_000)
        }
        return "\(totalViews) views"
    }

    var formattedSubscribers: String? {
        guard let subs = subscriberCount else { return nil }
        if subs >= 1_000_000 {
            return String(format: "%.1fM subscribers", Double(subs) / 1_000_000)
        } else if subs >= 1_000 {
            return String(format: "%.0fK subscribers", Double(subs) / 1_000)
        }
        return "\(subs) subscribers"
    }

    var subscriberTier: String? {
        guard let subs = subscriberCount else { return nil }
        if subs >= 10_000_000 { return "mega creator" }
        if subs >= 1_000_000 { return "large creator" }
        if subs >= 100_000 { return "mid-tier creator" }
        if subs >= 10_000 { return "growing creator" }
        return "small creator"
    }

    var coverageText: String? {
        guard let total = totalUploads, total > 0 else { return nil }
        let pct = Int(Double(totalVideoCount) / Double(total) * 100)
        return "You've saved \(totalVideoCount) of \(total) videos (\(pct)%)"
    }

    var velocityText: String? {
        if recentCount == 0 { return nil }
        return "\(recentCount) new video\(recentCount == 1 ? "" : "s") in last 30 days"
    }
}

// MARK: - Subtopic Suggestion

struct SubTopicSuggestion: Identifiable {
    let id = UUID()
    let name: String
    let estimatedCount: Int
    let description: String
}

// MARK: - Helpers

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension URL {
    var queryItems: [String: String]? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}
