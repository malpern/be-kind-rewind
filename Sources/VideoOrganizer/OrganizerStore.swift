import Foundation
import Observation
import TaggingKit

/// Main data store bridging TaggingKit's SQLite backend to SwiftUI's Observation.
@MainActor
@Observable
final class OrganizerStore {
    private(set) var topics: [TopicViewModel] = []
    private(set) var totalVideoCount: Int = 0
    private(set) var unassignedCount: Int = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    // Selected state
    var selectedTopicId: Int64? {
        didSet {
            if oldValue != selectedTopicId {
                selectedChannelId = nil
            }
        }
    }
    var selectedSubtopicId: Int64?
    var selectedVideoId: String?
    var hoveredVideoId: String?

    // Channel filter
    var selectedChannelId: String?

    // Creator inspection — set when hovering/clicking a creator section header
    var inspectedCreatorName: String?

    // Search
    var searchText: String = ""
    var parsedQuery: SearchQuery { SearchQuery(searchText) }
    var searchResultCount: Int = 0

    // Cached flat video map — rebuilt on loadTopics()
    private var videoMap: [String: VideoViewModel] = [:]
    private var videoTopicMap: [String: Int64] = [:]

    private let store: TopicStore
    private let suggester: TopicSuggester?

    init(dbPath: String, claudeClient: ClaudeClient? = nil) throws {
        self.store = try TopicStore(path: dbPath)
        self.suggester = claudeClient.map { TopicSuggester(client: $0) }
        loadTopics()
    }

    // MARK: - Loading

    func loadTopics() {
        do {
            let summaries = try store.listTopics()
            topics = summaries.map { summary in
                let subtopicSummaries = (try? store.subtopicsForTopic(id: summary.id)) ?? []
                let subtopics = subtopicSummaries.map {
                    TopicViewModel(id: $0.id, name: $0.name, videoCount: $0.videoCount, parentId: summary.id)
                }
                return TopicViewModel(id: summary.id, name: summary.name, videoCount: summary.videoCount, subtopics: subtopics)
            }
            totalVideoCount = try store.totalVideoCount()
            unassignedCount = try store.unassignedCount()
            if selectedTopicId == nil, let first = topics.first {
                selectedTopicId = first.id
            }
            rebuildVideoMaps()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Get videos for a topic including its subtopics.
    func videosForTopicIncludingSubtopics(_ topicId: Int64) -> [VideoViewModel] {
        do {
            let stored = try store.videosForTopicIncludingSubtopics(id: topicId)
            return stored.map { VideoViewModel(from: $0) }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func videosForTopic(_ topicId: Int64, limit: Int? = nil) -> [VideoViewModel] {
        do {
            let stored = try store.videosForTopic(id: topicId, limit: limit)
            return stored.map { VideoViewModel(from: $0) }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    // MARK: - Video Lookup (O(1) via cached map)

    /// The video currently shown in the inspector — hovered takes priority, else selected.
    var inspectedVideoId: String? {
        hoveredVideoId ?? selectedVideoId
    }

    var inspectedVideo: VideoViewModel? {
        inspectedVideoId.flatMap { videoMap[$0] }
    }

    func videoById(_ videoId: String) -> VideoViewModel? {
        videoMap[videoId]
    }

    func topicNameForVideo(_ videoId: String) -> String? {
        guard let topicId = videoTopicMap[videoId] else { return nil }
        return topics.first { $0.id == topicId }?.name
    }

    func moreFromChannel(videoId: String, limit: Int = 6) -> [VideoViewModel] {
        guard let video = videoMap[videoId],
              let channel = video.channelName else { return [] }
        return Array(
            videoMap.values
                .filter { $0.channelName == channel && $0.videoId != videoId }
                .prefix(limit)
        )
    }

    // Cached channel counts — rebuilt with video maps
    private(set) var channelCounts: [String: Int] = [:]

    // Cached channels per topic — rebuilt on loadTopics()
    private(set) var topicChannels: [Int64: [ChannelRecord]] = [:]

    // Cached per-topic channel video counts: [topicId: [channelId: count]]
    private var topicChannelCounts: [Int64: [String: Int]] = [:]

    // Cached per-topic channel recency: [topicId: Set<channelId>]
    private var topicChannelRecent: [Int64: Set<String>] = [:]

    /// Returns channels with videos in the given topic (including subtopics), sorted by video count desc.
    func channelsForTopic(_ topicId: Int64) -> [ChannelRecord] {
        topicChannels[topicId] ?? []
    }

    /// Video count for a channel within a topic. O(1) from cache.
    func videoCountForChannel(_ channelId: String, inTopic topicId: Int64) -> Int {
        topicChannelCounts[topicId]?[channelId] ?? 0
    }

    /// Whether a channel has recent content in a topic. O(1) from cache.
    func channelHasRecentContent(_ channelId: String, inTopic topicId: Int64) -> Bool {
        topicChannelRecent[topicId]?.contains(channelId) ?? false
    }

    /// Toggle channel filter. If already selected, deselects.
    func toggleChannelFilter(_ channelId: String) {
        if selectedChannelId == channelId {
            selectedChannelId = nil
        } else {
            selectedChannelId = channelId
        }
    }

    /// Clear channel filter.
    func clearChannelFilter() {
        selectedChannelId = nil
    }

    /// Get all videos by a creator name, grouped by topic.
    func creatorDetail(channelName: String) -> CreatorDetailViewModel {
        var videosByTopic: [(topicName: String, videos: [VideoViewModel])] = []
        var totalViews = 0
        var oldestDays = 0
        var newestDays = Int.max
        var recentCount = 0  // videos from last 30 days

        for topic in topics {
            let videos = videosForTopicIncludingSubtopics(topic.id).filter { $0.channelName == channelName }
            if !videos.isEmpty {
                videosByTopic.append((topicName: topic.name, videos: videos))
                for v in videos {
                    if let vc = v.viewCount { totalViews += parseViewCount(vc) }
                    if let pa = v.publishedAt {
                        let days = parseAge(pa)
                        oldestDays = max(oldestDays, days)
                        newestDays = min(newestDays, days)
                        if days <= 30 { recentCount += 1 }
                    }
                }
            }
        }

        let channelIconUrl = videosByTopic.flatMap(\.videos).first(where: { $0.channelIconUrl != nil })?.channelIconUrl
        let totalCount = videosByTopic.reduce(0) { $0 + $1.videos.count }

        // Look up channel record for subscriber count and total uploads
        let channelId = videosByTopic.flatMap(\.videos).first(where: { $0.channelId != nil })?.channelId
        let channelRecord = channelId.flatMap { cId in topicChannels.values.flatMap { $0 }.first(where: { $0.channelId == cId }) }

        let subscriberCount = channelRecord?.subscriberCount.flatMap { Int($0) }
        let totalUploads = channelRecord?.videoCountTotal

        return CreatorDetailViewModel(
            channelName: channelName,
            channelIconUrl: channelIconUrl,
            channelIconData: channelRecord?.iconData,
            totalVideoCount: totalCount,
            totalViews: totalViews,
            newestAge: newestDays == Int.max ? nil : formatAge(newestDays),
            oldestAge: oldestDays == 0 ? nil : formatAge(oldestDays),
            recentCount: recentCount,
            subscriberCount: subscriberCount,
            totalUploads: totalUploads,
            videosByTopic: videosByTopic
        )
    }

    private func parseViewCount(_ str: String) -> Int {
        let cleaned = str.replacingOccurrences(of: " views", with: "")
        if cleaned.hasSuffix("M") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000_000)
        } else if cleaned.hasSuffix("K") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000)
        }
        return Int(cleaned) ?? 0
    }

    private func parseAge(_ str: String) -> Int {
        if str == "today" { return 0 }
        let parts = str.split(separator: " ")
        guard parts.count >= 2, let num = Int(parts[0]) else { return Int.max }
        let unit = String(parts[1])
        if unit.hasPrefix("day") { return num }
        if unit.hasPrefix("month") { return num * 30 }
        if unit.hasPrefix("year") { return num * 365 }
        return Int.max
    }

    private func formatAge(_ days: Int) -> String {
        if days == 0 { return "today" }
        if days == 1 { return "1 day ago" }
        if days < 30 { return "\(days) days ago" }
        let months = days / 30
        if months == 1 { return "1 month ago" }
        if months < 12 { return "\(months) months ago" }
        let years = months / 12
        if years == 1 { return "1 year ago" }
        return "\(years) years ago"
    }

    private func rebuildVideoMaps() {
        var vMap: [String: VideoViewModel] = [:]
        var tMap: [String: Int64] = [:]
        var cCounts: [String: Int] = [:]
        var tChannels: [Int64: [ChannelRecord]] = [:]
        var tChannelCounts: [Int64: [String: Int]] = [:]
        var tChannelRecent: [Int64: Set<String>] = [:]

        for topic in topics {
            var perTopicCounts: [String: Int] = [:]
            var perTopicRecent: Set<String> = []

            for video in videosForTopicIncludingSubtopics(topic.id) {
                vMap[video.videoId] = video
                tMap[video.videoId] = topic.id
                if let channel = video.channelName {
                    cCounts[channel, default: 0] += 1
                }
                if let cid = video.channelId {
                    perTopicCounts[cid, default: 0] += 1
                    if let pa = video.publishedAt, parseAge(pa) <= 7 {
                        perTopicRecent.insert(cid)
                    }
                }
            }

            tChannelCounts[topic.id] = perTopicCounts
            tChannelRecent[topic.id] = perTopicRecent

            if let channels = try? store.channelsForTopicIncludingSubtopics(id: topic.id) {
                tChannels[topic.id] = channels
            }
        }
        videoMap = vMap
        videoTopicMap = tMap
        channelCounts = cCounts
        topicChannels = tChannels
        topicChannelCounts = tChannelCounts
        topicChannelRecent = tChannelRecent
    }

    /// Typeahead suggestions matching the current search text.
    func typeaheadSuggestions(limit: Int = 8) -> [TypeaheadSuggestion] {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return [] }
        // Don't show suggestions for exclude terms
        guard !text.hasPrefix("-") else { return [] }

        var results: [TypeaheadSuggestion] = []

        // Match topics and subtopics
        for topic in topics {
            if topic.name.localizedStandardContains(text) {
                results.append(TypeaheadSuggestion(
                    kind: .topic,
                    text: topic.name,
                    count: topic.videoCount,
                    topicId: topic.id
                ))
            }
            for sub in topic.subtopics where sub.name.localizedStandardContains(text) {
                results.append(TypeaheadSuggestion(
                    kind: .subtopic,
                    text: sub.name,
                    count: sub.videoCount,
                    topicId: sub.id,
                    parentName: topic.name
                ))
            }
        }

        // Match channels
        for (channel, count) in channelCounts where channel.localizedStandardContains(text) {
            results.append(TypeaheadSuggestion(
                kind: .channel,
                text: channel,
                count: count,
                topicId: nil
            ))
        }

        // Sort by count descending, take limit
        results.sort { $0.count > $1.count }
        return Array(results.prefix(limit))
    }

    // MARK: - Topic Operations

    func renameTopic(_ topicId: Int64, to newName: String) {
        do {
            try store.renameTopic(id: topicId, to: newName)
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTopic(_ topicId: Int64) {
        do {
            try store.deleteTopic(id: topicId)
            if selectedTopicId == topicId { selectedTopicId = nil }
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func mergeTopics(sourceId: Int64, intoId: Int64) {
        do {
            try store.mergeTopic(sourceId: sourceId, intoId: intoId)
            if selectedTopicId == sourceId { selectedTopicId = intoId }
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveVideo(videoId: String, toTopicId: Int64) {
        do {
            try store.assignVideo(videoId: videoId, toTopic: toTopicId)
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveVideos(videoIds: Set<String>, toTopicId: Int64) {
        do {
            for vid in videoIds {
                try store.assignVideo(videoId: vid, toTopic: toTopicId)
            }
            selectedVideoId = nil
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - AI Operations

    func splitTopic(_ topicId: Int64, into count: Int = 3) async {
        guard let suggester else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let videos = try store.videosForTopic(id: topicId)
            let topic = topics.first { $0.id == topicId }
            let videoItems = videos.map { v in
                VideoItem(sourceIndex: v.sourceIndex, title: v.title, videoUrl: v.videoUrl,
                          videoId: v.videoId, channelName: v.channelName, metadataText: nil, unavailableKind: "none")
            }

            let subTopics = try await suggester.splitTopic(
                topicName: topic?.name ?? "",
                videos: videoItems,
                videoIndices: videos.map(\.sourceIndex),
                targetSubTopics: count
            )

            try store.deleteTopic(id: topicId)
            for sub in subTopics {
                let newId = try store.createTopic(name: sub.name)
                try store.assignVideos(indices: sub.videoIndices, toTopic: newId)
            }

            selectedTopicId = nil
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - View Models

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
}

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

struct SubTopicSuggestion: Identifiable {
    let id = UUID()
    let name: String
    let estimatedCount: Int
    let description: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension URL {
    var queryItems: [String: String]? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}
