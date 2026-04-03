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
    private(set) var candidateRefreshToken = 0

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

    // Channel / playlist filters
    var selectedChannelId: String?
    var selectedPlaylistId: String?
    var selectedPlaylistTitle: String?

    // Creator inspection — set when hovering/clicking a creator section header
    var inspectedCreatorName: String?

    // Search
    var searchText: String = ""
    var parsedQuery: SearchQuery { SearchQuery(searchText) }
    var searchResultCount: Int = 0

    // Per-topic center-pane mode
    var topicDisplayModes: [Int64: TopicDisplayMode] = [:]
    private(set) var candidateErrors: [Int64: String] = [:]
    private(set) var candidateLoadingTopics: Set<Int64> = []
    private(set) var candidateProgressByTopic: [Int64: Double] = [:]
    private(set) var candidateCompletedChannelsByTopic: [Int64: Int] = [:]
    private(set) var candidateTotalChannelsByTopic: [Int64: Int] = [:]
    private(set) var candidateCurrentChannelNameByTopic: [Int64: String] = [:]

    // Cached flat video map — rebuilt on loadTopics()
    private var videoMap: [String: VideoViewModel] = [:]
    private var videoTopicMap: [String: Int64] = [:]

    private let store: TopicStore
    private let suggester: TopicSuggester?
    private let youtubeClient: YouTubeClient?

    init(dbPath: String, claudeClient: ClaudeClient? = nil) throws {
        self.store = try TopicStore(path: dbPath)
        self.suggester = claudeClient.map { TopicSuggester(client: $0) }
        self.youtubeClient = try? YouTubeClient()
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
            rebuildPlaylistMaps()
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

    var inspectedCandidateVideo: CandidateVideoViewModel? {
        guard let videoId = inspectedVideoId,
              let topicId = selectedTopicId,
              displayMode(for: topicId) == .watchCandidates,
              let stored = try? store.candidateForTopic(id: topicId, videoId: videoId)
        else {
            return nil
        }
        return CandidateVideoViewModel(from: stored)
    }

    var inspectedItem: InspectedVideoViewModel? {
        if let video = inspectedVideo {
            return InspectedVideoViewModel(
                video: video,
                playlists: playlistsForVideo(video.videoId),
                isWatchCandidate: false
            )
        }

        if let candidate = inspectedCandidateVideo {
            return InspectedVideoViewModel(
                video: VideoViewModel(from: candidate),
                playlists: playlistsForVideo(candidate.videoId),
                isWatchCandidate: true
            )
        }

        return nil
    }

    func videoById(_ videoId: String) -> VideoViewModel? {
        videoMap[videoId]
    }

    func topicNameForVideo(_ videoId: String) -> String? {
        guard let topicId = videoTopicMap[videoId] else { return nil }
        return topics.first { $0.id == topicId }?.name
    }

    func playlistsForVideo(_ videoId: String) -> [PlaylistRecord] {
        playlistsByVideoId[videoId] ?? []
    }

    func videoIsInSelectedPlaylist(_ videoId: String) -> Bool {
        guard let selectedPlaylistId else { return true }
        return playlistsByVideoId[videoId]?.contains(where: { $0.playlistId == selectedPlaylistId }) ?? false
    }

    func applyPlaylistFilter(_ playlist: PlaylistRecord) {
        selectedPlaylistId = playlist.playlistId
        selectedPlaylistTitle = playlist.title
        selectedChannelId = nil
        selectedSubtopicId = nil
        AppLogger.discovery.info("Applied playlist filter \(playlist.playlistId, privacy: .public) (\(playlist.title, privacy: .public))")
    }

    func clearPlaylistFilter() {
        guard selectedPlaylistId != nil else { return }
        AppLogger.discovery.info("Cleared playlist filter \(self.selectedPlaylistId ?? "", privacy: .public)")
        selectedPlaylistId = nil
        selectedPlaylistTitle = nil
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
    private(set) var playlistsByVideoId: [String: [PlaylistRecord]] = [:]

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

    func displayMode(for topicId: Int64) -> TopicDisplayMode {
        topicDisplayModes[topicId] ?? .saved
    }

    func setDisplayMode(_ mode: TopicDisplayMode, for topicId: Int64) {
        topicDisplayModes[topicId] = mode
        AppLogger.discovery.info("Set topic \(topicId, privacy: .public) display mode to \(mode.rawValue, privacy: .public)")
        if mode == .watchCandidates {
            selectedChannelId = nil
            selectedSubtopicId = nil
            selectedVideoId = nil
            if selectedTopicId != topicId {
                selectedTopicId = topicId
            }
        }
    }

    func activateDisplayMode(_ mode: TopicDisplayMode, for topicId: Int64) async {
        setDisplayMode(mode, for: topicId)
        guard mode == .watchCandidates else {
            candidateRefreshToken += 1
            return
        }
        await ensureCandidates(for: topicId)
    }

    func candidateVideosForTopic(_ topicId: Int64) -> [CandidateVideoViewModel] {
        if candidateLoadingTopics.contains(topicId) {
            return [.placeholder(topicId: topicId, title: "Finding candidates…", message: "Pulling recent and popular videos from creators already associated with this topic.")]
        }

        if let error = candidateErrors[topicId] {
            return [.placeholder(topicId: topicId, title: "Could not load candidates", message: error)]
        }

        do {
            let storedCandidates = try store.candidatesForTopic(id: topicId, limit: 36)
            if storedCandidates.isEmpty {
                return [.placeholder(topicId: topicId, title: "No candidates yet", message: "No unseen candidates were found from the current topic creators.")]
            }
            return storedCandidates.map(CandidateVideoViewModel.init(from:))
        } catch {
            return [.placeholder(topicId: topicId, title: "Could not load candidates", message: error.localizedDescription)]
        }
    }

    func candidateProgress(for topicId: Int64) -> Double {
        candidateProgressByTopic[topicId] ?? 0
    }

    func candidateProgressTitle(for topicId: Int64) -> String {
        let completed = candidateCompletedChannelsByTopic[topicId] ?? 0
        let total = candidateTotalChannelsByTopic[topicId] ?? 0
        guard total > 0 else { return "Finding candidates for this topic" }
        return "Scanning top creators: \(completed) of \(total)"
    }

    func candidateProgressDetail(for topicId: Int64) -> String {
        let completed = candidateCompletedChannelsByTopic[topicId] ?? 0
        let total = candidateTotalChannelsByTopic[topicId] ?? 0
        let channelName = candidateCurrentChannelNameByTopic[topicId]

        guard total > 0 else {
            return "Preparing topic sources and candidate ranking."
        }

        if completed >= total {
            return "Finished checking \(total) creator\(total == 1 ? "" : "s"). Ranking the strongest matches now."
        }

        if let channelName, !channelName.isEmpty {
            return "Checking recent uploads first, plus a smaller popular back-catalog pass, for \(channelName)."
        }

        return "Checking recent uploads first, plus a smaller popular back-catalog pass."
    }

    var candidateProgressOverlay: CandidateProgressOverlayState? {
        let topicId: Int64?
        if let selectedTopicId, candidateLoadingTopics.contains(selectedTopicId) {
            topicId = selectedTopicId
        } else {
            topicId = candidateLoadingTopics.sorted().first
        }

        guard let topicId,
              let topic = topics.first(where: { $0.id == topicId })
        else {
            return nil
        }

        return CandidateProgressOverlayState(
            topicId: topicId,
            topicName: topic.name,
            progress: candidateProgress(for: topicId),
            title: candidateProgressTitle(for: topicId),
            detail: candidateProgressDetail(for: topicId)
        )
    }

    func setCandidateState(topicId: Int64, videoId: String, state: CandidateState) {
        do {
            try store.setCandidateState(topicId: topicId, videoId: videoId, state: state)
            AppLogger.discovery.info("Set candidate state for topic \(topicId, privacy: .public), video \(videoId, privacy: .public) to \(state.rawValue, privacy: .public)")
            candidateRefreshToken += 1
        } catch {
            AppLogger.discovery.error("Failed to set candidate state for topic \(topicId, privacy: .public), video \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
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

    private func rebuildPlaylistMaps() {
        playlistsByVideoId = (try? store.allPlaylistsByVideo()) ?? [:]
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

    private func ensureCandidates(for topicId: Int64) async {
        guard !candidateLoadingTopics.contains(topicId) else { return }
        candidateLoadingTopics.insert(topicId)
        candidateProgressByTopic[topicId] = 0
        candidateCompletedChannelsByTopic[topicId] = 0
        candidateTotalChannelsByTopic[topicId] = 0
        candidateCurrentChannelNameByTopic[topicId] = nil
        candidateErrors[topicId] = nil
        candidateRefreshToken += 1
        AppLogger.discovery.info("Starting candidate refresh for topic \(topicId, privacy: .public)")
        defer {
            candidateLoadingTopics.remove(topicId)
            candidateProgressByTopic[topicId] = nil
            candidateCompletedChannelsByTopic[topicId] = nil
            candidateTotalChannelsByTopic[topicId] = nil
            candidateCurrentChannelNameByTopic[topicId] = nil
            candidateRefreshToken += 1
            AppLogger.discovery.info("Finished candidate refresh for topic \(topicId, privacy: .public)")
        }

        guard let youtubeClient else {
            candidateErrors[topicId] = "No YouTube API key found. Configure `YOUTUBE_API_KEY` or `~/.config/youtube/api-key`."
            AppLogger.discovery.error("Cannot refresh candidates for topic \(topicId, privacy: .public): missing YouTube client")
            return
        }

        do {
            let scanLimit = candidateCreatorScanLimit(for: topicId)
            let channels = Array(channelsForTopic(topicId).prefix(scanLimit))
            let channelIds = channels.map(\.channelId)
            AppLogger.discovery.debug("Candidate refresh topic \(topicId, privacy: .public) using \(channels.count, privacy: .public) channels")
            guard !channelIds.isEmpty else {
                try store.replaceCandidates(forTopic: topicId, candidates: [], sources: [])
                AppLogger.discovery.info("Topic \(topicId, privacy: .public) has no associated channels; cleared candidates")
                return
            }

            let existingVideoIds = Set(videosForTopicIncludingSubtopics(topicId).map(\.videoId))
            var aggregate: [String: AggregatedCandidate] = [:]
            let totalChannels = max(channels.count, 1)
            var completedChannels = 0
            candidateTotalChannelsByTopic[topicId] = channels.count
            candidateCompletedChannelsByTopic[topicId] = 0
            candidateCurrentChannelNameByTopic[topicId] = channels.first?.name
            candidateRefreshToken += 1

            for channel in channels {
                candidateCurrentChannelNameByTopic[topicId] = channel.name
                candidateRefreshToken += 1
                AppLogger.discovery.debug("Fetching candidates from channel \(channel.channelId, privacy: .public) (\(channel.name, privacy: .public)) for topic \(topicId, privacy: .public)")
                let recent = try await youtubeClient.searchChannelVideos(channelId: channel.channelId, order: .date, maxResults: 8)
                let popular = try await youtubeClient.searchChannelVideos(channelId: channel.channelId, order: .viewCount, maxResults: 8)
                AppLogger.discovery.debug("Fetched \(recent.count, privacy: .public) recent and \(popular.count, privacy: .public) popular videos for channel \(channel.channelId, privacy: .public)")

                for video in recent {
                    accumulateCandidate(
                        video: video,
                        topicId: topicId,
                        channel: channel,
                        sourceKind: "channel_recent",
                        sourceRef: channel.channelId,
                        creatorAffinity: videoCountForChannel(channel.channelId, inTopic: topicId),
                        existingVideoIds: existingVideoIds,
                        aggregate: &aggregate
                    )
                }

                for video in popular {
                    accumulateCandidate(
                        video: video,
                        topicId: topicId,
                        channel: channel,
                        sourceKind: "channel_popular",
                        sourceRef: channel.channelId,
                        creatorAffinity: videoCountForChannel(channel.channelId, inTopic: topicId),
                        existingVideoIds: existingVideoIds,
                        aggregate: &aggregate
                    )
                }

                completedChannels += 1
                candidateCompletedChannelsByTopic[topicId] = completedChannels
                candidateProgressByTopic[topicId] = Double(completedChannels) / Double(totalChannels)
                candidateRefreshToken += 1
            }

            let ranked = aggregate.values
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    }
                    return lhs.score > rhs.score
                }
                .prefix(36)

            let candidates = ranked.map { value in
                TopicCandidate(
                    topicId: topicId,
                    videoId: value.videoId,
                    title: value.title,
                    channelId: value.channelId,
                    channelName: value.channelName,
                    videoUrl: "https://www.youtube.com/watch?v=\(value.videoId)",
                    viewCount: value.viewCount,
                    publishedAt: value.publishedAt,
                    duration: value.duration,
                    channelIconUrl: value.channelIconUrl,
                    score: value.score,
                    reason: value.reason
                )
            }

            let sources = ranked.flatMap { value in
                value.sources.map { source in
                    CandidateSourceRecord(
                        topicId: topicId,
                        videoId: value.videoId,
                        sourceKind: source.kind,
                        sourceRef: source.ref
                    )
                }
            }

            try store.replaceCandidates(forTopic: topicId, candidates: candidates, sources: sources)
            AppLogger.discovery.info("Stored \(candidates.count, privacy: .public) candidates and \(sources.count, privacy: .public) sources for topic \(topicId, privacy: .public)")
        } catch {
            candidateErrors[topicId] = error.localizedDescription
            AppLogger.discovery.error("Candidate refresh failed for topic \(topicId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accumulateCandidate(
        video: DiscoveredVideo,
        topicId: Int64,
        channel: ChannelRecord,
        sourceKind: String,
        sourceRef: String,
        creatorAffinity: Int,
        existingVideoIds: Set<String>,
        aggregate: inout [String: AggregatedCandidate]
    ) {
        guard !existingVideoIds.contains(video.videoId) else { return }

        let publishedDays = parseAge(video.publishedAt ?? "")
        let recencyBonus: Int
        if sourceKind == "channel_recent" {
            if publishedDays <= 7 {
                recencyBonus = 30
            } else if publishedDays <= 30 {
                recencyBonus = 24
            } else if publishedDays <= 90 {
                recencyBonus = 16
            } else if publishedDays <= 180 {
                recencyBonus = 8
            } else {
                recencyBonus = 2
            }
        } else {
            recencyBonus = 0
        }

        let archivalBonus = sourceKind == "channel_popular" ? min(max(publishedDays / 120, 0), 4) : 0
        let creatorBonus = min(creatorAffinity, 16)
        let qualityBonus = min(parseViewCount(video.viewCount ?? "") / 75_000, 6)
        let freshnessSourceBonus = sourceKind == "channel_recent" ? 10 : 0
        let score = Double(
            freshnessSourceBonus +
            recencyBonus * 4 +
            creatorBonus * 3 +
            archivalBonus * 2 +
            qualityBonus
        )

        let reason: String = if sourceKind == "channel_recent" {
            "Fresh upload from a creator already in this topic"
        } else {
            "Older popular video from a creator you already watch here"
        }

        if var existing = aggregate[video.videoId] {
            existing.score += score + 3
            existing.reason = existing.reason.contains("Recent upload") || reason.contains("Recent upload")
                ? "Recent and popular pick from a creator already in this topic"
                : existing.reason
            existing.sources.insert(CandidateSource(kind: sourceKind, ref: sourceRef))
            aggregate[video.videoId] = existing
        } else {
            aggregate[video.videoId] = AggregatedCandidate(
                videoId: video.videoId,
                title: video.title,
                channelId: video.channelId,
                channelName: video.channelTitle ?? channel.name,
                viewCount: video.viewCount,
                publishedAt: video.publishedAt,
                duration: video.duration,
                channelIconUrl: channel.iconUrl,
                score: score,
                reason: reason,
                sources: [CandidateSource(kind: sourceKind, ref: sourceRef)]
            )
        }
    }
}

private extension OrganizerStore {
    func candidateCreatorScanLimit(for topicId: Int64) -> Int {
        let count = channelsForTopic(topicId).count
        switch count {
        case 0...6:
            return 6
        case 7...12:
            return 10
        case 13...24:
            return 12
        default:
            return 16
        }
    }
}

enum TopicDisplayMode: String, CaseIterable, Sendable {
    case saved
    case watchCandidates

    var label: String {
        switch self {
        case .saved:
            return "Saved"
        case .watchCandidates:
            return "Watch Candidates"
        }
    }
}

struct CandidateProgressOverlayState: Equatable {
    let topicId: Int64
    let topicName: String
    let progress: Double
    let title: String
    let detail: String
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

private struct CandidateSource: Hashable {
    let kind: String
    let ref: String
}

private struct AggregatedCandidate {
    let videoId: String
    let title: String
    let channelId: String?
    let channelName: String?
    let viewCount: String?
    let publishedAt: String?
    let duration: String?
    let channelIconUrl: String?
    var score: Double
    var reason: String
    var sources: Set<CandidateSource>
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
}

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
    let isPlaceholder: Bool

    var id: String { "\(topicId)-\(videoId)" }

    var thumbnailUrl: URL? {
        guard !isPlaceholder else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
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
            isPlaceholder: true
        )
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
