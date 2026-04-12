import Foundation
@preconcurrency import SQLite

/// SQLite-backed store for topics, video assignments, and the commit table.
public final class TopicStore: Sendable {
    let db: Connection
    private let isInMemory: Bool

    // Tables
    private let topics = Table("topics")
    private let videos = Table("videos")
    let commitLog = Table("commit_log")
    private let channels = Table("channels")
    let playlists = Table("playlists")
    let playlistMemberships = Table("playlist_memberships")
    private let topicCandidates = Table("topic_candidates")
    private let candidateSources = Table("candidate_sources")
    private let candidateState = Table("candidate_state")
    private let channelDiscoveryArchive = Table("channel_discovery_archive")
    private let channelDiscoveryState = Table("channel_discovery_state")
    let seenVideos = Table("seen_videos")
    private let excludedChannels = Table("excluded_channels")
    private let favoriteChannels = Table("favorite_channels")
    private let creatorThemes = Table("creator_themes")
    private let creatorAbout = Table("creator_about")
    private let channelLinks = Table("channel_links")

    // Topic columns
    private let topicId = SQLite.Expression<Int64>("id")
    private let topicName = SQLite.Expression<String>("name")
    private let topicCreatedAt = SQLite.Expression<String>("created_at")
    private let topicParentId = SQLite.Expression<Int64?>("parent_id")

    // Video columns
    private let videoId = SQLite.Expression<String>("video_id")
    private let videoTitle = SQLite.Expression<String?>("title")
    private let videoChannel = SQLite.Expression<String?>("channel_name")
    private let videoUrl = SQLite.Expression<String?>("video_url")
    private let videoSourceIndex = SQLite.Expression<Int>("source_index")
    private let videoTopicId = SQLite.Expression<Int64?>("topic_id")
    private let videoViewCount = SQLite.Expression<String?>("view_count")
    private let videoPublishedAt = SQLite.Expression<String?>("published_at")
    private let videoDuration = SQLite.Expression<String?>("duration")
    private let videoChannelIconUrl = SQLite.Expression<String?>("channel_icon_url")
    private let videoChannelId = SQLite.Expression<String?>("channel_id")

    // Channel columns
    private let channelId = SQLite.Expression<String>("channel_id")
    private let channelName = SQLite.Expression<String>("name")
    private let channelHandle = SQLite.Expression<String?>("handle")
    private let channelUrl = SQLite.Expression<String?>("channel_url")
    private let channelIconUrl = SQLite.Expression<String?>("icon_url")
    private let channelIconData = SQLite.Expression<SQLite.Blob?>("icon_data")
    private let channelSubscriberCount = SQLite.Expression<String?>("subscriber_count")
    private let channelDescription = SQLite.Expression<String?>("description")
    private let channelVideoCountTotal = SQLite.Expression<Int?>("video_count_total")
    private let channelFetchedAt = SQLite.Expression<String?>("fetched_at")
    private let channelIconFetchedAt = SQLite.Expression<String?>("icon_fetched_at")

    // Playlist columns
    let playlistId = SQLite.Expression<String>("playlist_id")
    let playlistTitle = SQLite.Expression<String>("title")
    let playlistVisibility = SQLite.Expression<String?>("visibility")
    let playlistVideoCount = SQLite.Expression<Int?>("video_count")
    let playlistSource = SQLite.Expression<String?>("source")
    let playlistFetchedAt = SQLite.Expression<String?>("fetched_at")
    let membershipPlaylistId = SQLite.Expression<String>("playlist_id")
    let membershipVideoId = SQLite.Expression<String>("video_id")
    let membershipPosition = SQLite.Expression<Int?>("position")
    let membershipVerifiedAt = SQLite.Expression<String?>("verified_at")

    // Candidate columns
    private let candidateTopicId = SQLite.Expression<Int64>("topic_id")
    private let candidateVideoId = SQLite.Expression<String>("video_id")
    private let candidateTitle = SQLite.Expression<String>("title")
    private let candidateChannelId = SQLite.Expression<String?>("channel_id")
    private let candidateChannelName = SQLite.Expression<String?>("channel_name")
    private let candidateVideoUrl = SQLite.Expression<String?>("video_url")
    private let candidateViewCount = SQLite.Expression<String?>("view_count")
    private let candidatePublishedAt = SQLite.Expression<String?>("published_at")
    private let candidateDuration = SQLite.Expression<String?>("duration")
    private let candidateChannelIconUrl = SQLite.Expression<String?>("channel_icon_url")
    private let candidateScore = SQLite.Expression<Double>("score")
    private let candidateReason = SQLite.Expression<String>("reason")
    private let candidateDiscoveredAt = SQLite.Expression<String>("discovered_at")
    private let candidateSourceKind = SQLite.Expression<String>("source_kind")
    private let candidateSourceRef = SQLite.Expression<String>("source_ref")
    private let candidateStateValue = SQLite.Expression<String>("state")
    private let candidateStateUpdatedAt = SQLite.Expression<String>("updated_at")

    // Discovery archive columns
    private let archiveChannelId = SQLite.Expression<String>("channel_id")
    private let archiveVideoId = SQLite.Expression<String>("video_id")
    private let archiveTitle = SQLite.Expression<String>("title")
    private let archiveChannelName = SQLite.Expression<String?>("channel_name")
    private let archivePublishedAt = SQLite.Expression<String?>("published_at")
    private let archiveDuration = SQLite.Expression<String?>("duration")
    private let archiveViewCount = SQLite.Expression<String?>("view_count")
    private let archiveChannelIconUrl = SQLite.Expression<String?>("channel_icon_url")
    private let archiveFetchedAt = SQLite.Expression<String?>("fetched_at")
    private let discoveryStateLastScannedAt = SQLite.Expression<String?>("last_scanned_at")

    // Seen-history columns
    let seenEventId = SQLite.Expression<Int64>("id")
    let seenVideoId = SQLite.Expression<String?>("video_id")
    let seenTitle = SQLite.Expression<String?>("title")
    let seenChannelName = SQLite.Expression<String?>("channel_name")
    let seenRawURL = SQLite.Expression<String?>("raw_url")
    let seenAt = SQLite.Expression<String?>("seen_at")
    let seenSource = SQLite.Expression<String>("source")
    let seenConfidence = SQLite.Expression<String>("confidence")
    let seenImportedAt = SQLite.Expression<String>("imported_at")

    // Excluded-channel columns
    private let excludedChannelId = SQLite.Expression<String>("channel_id")
    private let excludedChannelName = SQLite.Expression<String>("channel_name")
    private let excludedChannelIconUrl = SQLite.Expression<String?>("icon_url")
    private let excludedChannelExcludedAt = SQLite.Expression<String>("excluded_at")
    private let excludedChannelReason = SQLite.Expression<String?>("reason")

    // Favorite channels columns (mirror of excluded; favoritedAt instead of excludedAt,
    // notes instead of reason — both optional, both small).
    private let favoriteChannelId = SQLite.Expression<String>("channel_id")
    private let favoriteChannelName = SQLite.Expression<String>("channel_name")
    private let favoriteChannelIconUrl = SQLite.Expression<String?>("icon_url")
    private let favoriteChannelFavoritedAt = SQLite.Expression<String>("favorited_at")
    private let favoriteChannelNotes = SQLite.Expression<String?>("notes")
    /// Phase 3: ISO8601 timestamp of the last time the user opened this creator's
    /// detail page. Nil for rows that predate this feature or were favorited but
    /// never visited. Used to compute "N new uploads since your last visit" on the
    /// creator detail page.
    private let favoriteChannelLastVisitedAt = SQLite.Expression<String?>("last_visited_at")

    // creator_themes columns — composite PK on (channel_id, theme_label).
    // Stores LLM-generated theme clusters from CreatorThemeClassifier.
    private let creatorThemeChannelId = SQLite.Expression<String>("channel_id")
    private let creatorThemeLabel = SQLite.Expression<String>("theme_label")
    private let creatorThemeDescription = SQLite.Expression<String?>("theme_description")
    private let creatorThemeOrder = SQLite.Expression<Int>("theme_order")
    private let creatorThemeVideoIds = SQLite.Expression<String>("video_ids")     // JSON array
    private let creatorThemeIsSeries = SQLite.Expression<Bool>("is_series")
    private let creatorThemeOrderingSignal = SQLite.Expression<String?>("ordering_signal")
    private let creatorThemeClassifiedAt = SQLite.Expression<String>("classified_at")
    private let creatorThemeClassifiedVideoCount = SQLite.Expression<Int>("classified_video_count")

    // creator_about columns — one row per channel.
    private let creatorAboutChannelId = SQLite.Expression<String>("channel_id")
    private let creatorAboutSummary = SQLite.Expression<String>("summary")
    private let creatorAboutGeneratedAt = SQLite.Expression<String>("generated_at")
    private let creatorAboutSourceVideoCount = SQLite.Expression<Int>("source_video_count")

    // Channel links columns (Phase 3 — scraped from channel home page)
    private let channelLinksChannelId = SQLite.Expression<String>("channel_id")
    private let channelLinksJSON = SQLite.Expression<String>("links_json")
    private let channelLinksFetchedAt = SQLite.Expression<String>("fetched_at")

    // Commit log columns
    let commitId = SQLite.Expression<Int64>("id")
    let commitAction = SQLite.Expression<String>("action")
    let commitVideoId = SQLite.Expression<String>("video_id")
    let commitPlaylist = SQLite.Expression<String>("playlist")
    let commitCreatedAt = SQLite.Expression<String>("created_at")
    let commitSynced = SQLite.Expression<Bool>("synced")
    let commitState = SQLite.Expression<String>("state")
    let commitAttempts = SQLite.Expression<Int>("attempts")
    let commitLastError = SQLite.Expression<String?>("last_error")
    let commitNextAttemptAt = SQLite.Expression<String?>("next_attempt_at")
    let commitExecutor = SQLite.Expression<String>("executor")
    let commitStateUpdatedAt = SQLite.Expression<String>("state_updated_at")

    public init(path: String) throws {
        db = try Connection(path)
        isInMemory = false
        try configureDatabase()
        try createTables()
    }

    public init(inMemory: Bool = true) throws {
        db = try Connection(.inMemory)
        isInMemory = true
        try configureDatabase()
        try createTables()
    }

    private func configureDatabase() throws {
        try db.run("PRAGMA foreign_keys = ON")
        try db.run("PRAGMA busy_timeout = 5000")
        if !isInMemory {
            try db.run("PRAGMA journal_mode = WAL")
        }
    }

    private func createTables() throws {
        try db.run(topics.create(ifNotExists: true) { t in
            t.column(topicId, primaryKey: .autoincrement)
            t.column(topicName, unique: true)
            t.column(topicCreatedAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
        })

        try db.run(videos.create(ifNotExists: true) { t in
            t.column(videoId, primaryKey: true)
            t.column(videoTitle)
            t.column(videoChannel)
            t.column(videoUrl)
            t.column(videoSourceIndex)
            t.column(videoTopicId, references: topics, topicId)
        })

        // Migrate: add metadata columns if missing
        let tableInfo = try db.prepare("PRAGMA table_info(videos)")
        let existingColumns = try Set(tableInfo.map { try requiredValue($0, at: 1, as: String.self, context: "videos schema") })
        if !existingColumns.contains("view_count") {
            try db.run("ALTER TABLE videos ADD COLUMN view_count TEXT")
        }
        if !existingColumns.contains("published_at") {
            try db.run("ALTER TABLE videos ADD COLUMN published_at TEXT")
        }
        if !existingColumns.contains("duration") {
            try db.run("ALTER TABLE videos ADD COLUMN duration TEXT")
        }
        if !existingColumns.contains("channel_icon_url") {
            try db.run("ALTER TABLE videos ADD COLUMN channel_icon_url TEXT")
        }

        // Migrate: add parent_id to topics if missing
        let topicInfo = try db.prepare("PRAGMA table_info(topics)")
        let topicColumns = try Set(topicInfo.map { try requiredValue($0, at: 1, as: String.self, context: "topics schema") })
        if !topicColumns.contains("parent_id") {
            try db.run("ALTER TABLE topics ADD COLUMN parent_id INTEGER REFERENCES topics(id)")
        }

        // Migrate: add channel_id to videos if missing
        if !existingColumns.contains("channel_id") {
            try db.run("ALTER TABLE videos ADD COLUMN channel_id TEXT REFERENCES channels(channel_id)")
        }

        // Create channels table
        try db.run(channels.create(ifNotExists: true) { t in
            t.column(channelId, primaryKey: true)
            t.column(channelName)
            t.column(channelHandle)
            t.column(channelUrl)
            t.column(channelIconUrl)
            t.column(channelIconData)
            t.column(channelSubscriberCount)
            t.column(channelDescription)
            t.column(channelVideoCountTotal)
            t.column(channelFetchedAt)
            t.column(channelIconFetchedAt)
        })

        try db.run(playlists.create(ifNotExists: true) { t in
            t.column(playlistId, primaryKey: true)
            t.column(playlistTitle)
            t.column(playlistVisibility)
            t.column(playlistVideoCount)
            t.column(playlistSource)
            t.column(playlistFetchedAt)
        })

        try db.run(playlistMemberships.create(ifNotExists: true) { t in
            t.column(membershipPlaylistId)
            t.column(membershipVideoId)
            t.column(membershipPosition)
            t.column(membershipVerifiedAt)
        })

        try db.run(commitLog.create(ifNotExists: true) { t in
            t.column(commitId, primaryKey: .autoincrement)
            t.column(commitAction) // "add_to_playlist", "remove_from_playlist", "create_playlist"
            t.column(commitVideoId)
            t.column(commitPlaylist)
            t.column(commitCreatedAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
            t.column(commitSynced, defaultValue: false)
            t.column(commitState, defaultValue: SyncQueueState.queued.rawValue)
            t.column(commitAttempts, defaultValue: 0)
            t.column(commitLastError)
            t.column(commitNextAttemptAt)
            t.column(commitExecutor, defaultValue: SyncExecutorKind.api.rawValue)
            t.column(commitStateUpdatedAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
        })

        let commitInfo = try db.prepare("PRAGMA table_info(commit_log)")
        let commitColumns = try Set(commitInfo.map { try requiredValue($0, at: 1, as: String.self, context: "commit_log schema") })
        if !commitColumns.contains("state") {
            try db.run("ALTER TABLE commit_log ADD COLUMN state TEXT DEFAULT 'queued'")
        }
        if !commitColumns.contains("attempts") {
            try db.run("ALTER TABLE commit_log ADD COLUMN attempts INTEGER DEFAULT 0")
        }
        if !commitColumns.contains("last_error") {
            try db.run("ALTER TABLE commit_log ADD COLUMN last_error TEXT")
        }
        if !commitColumns.contains("next_attempt_at") {
            try db.run("ALTER TABLE commit_log ADD COLUMN next_attempt_at TEXT")
        }
        if !commitColumns.contains("executor") {
            try db.run("ALTER TABLE commit_log ADD COLUMN executor TEXT DEFAULT 'api'")
        }
        if !commitColumns.contains("state_updated_at") {
            let now = ISO8601DateFormatter().string(from: Date())
            try db.run("ALTER TABLE commit_log ADD COLUMN state_updated_at TEXT DEFAULT '\(now)'")
            try db.run(commitLog.update(commitStateUpdatedAt <- commitCreatedAt))
        }

        try db.run(topicCandidates.create(ifNotExists: true) { t in
            t.column(candidateTopicId)
            t.column(candidateVideoId)
            t.column(candidateTitle)
            t.column(candidateChannelId)
            t.column(candidateChannelName)
            t.column(candidateVideoUrl)
            t.column(candidateViewCount)
            t.column(candidatePublishedAt)
            t.column(candidateDuration)
            t.column(candidateChannelIconUrl)
            t.column(candidateScore)
            t.column(candidateReason)
            t.column(candidateDiscoveredAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
        })

        try db.run(candidateSources.create(ifNotExists: true) { t in
            t.column(candidateTopicId)
            t.column(candidateVideoId)
            t.column(candidateSourceKind)
            t.column(candidateSourceRef)
        })

        try db.run(candidateState.create(ifNotExists: true) { t in
            t.column(candidateTopicId)
            t.column(candidateVideoId)
            t.column(candidateStateValue)
            t.column(candidateStateUpdatedAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
        })

        try db.run(channelDiscoveryArchive.create(ifNotExists: true) { t in
            t.column(archiveChannelId)
            t.column(archiveVideoId)
            t.column(archiveTitle)
            t.column(archiveChannelName)
            t.column(archivePublishedAt)
            t.column(archiveDuration)
            t.column(archiveViewCount)
            t.column(archiveChannelIconUrl)
            t.column(archiveFetchedAt)
        })

        try db.run(channelDiscoveryState.create(ifNotExists: true) { t in
            t.column(archiveChannelId, primaryKey: true)
            t.column(discoveryStateLastScannedAt)
        })

        try db.run(seenVideos.create(ifNotExists: true) { t in
            t.column(seenEventId, primaryKey: .autoincrement)
            t.column(seenVideoId)
            t.column(seenTitle)
            t.column(seenChannelName)
            t.column(seenRawURL)
            t.column(seenAt)
            t.column(seenSource)
            t.column(seenConfidence)
            t.column(seenImportedAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
        })

        try db.run(excludedChannels.create(ifNotExists: true) { t in
            t.column(excludedChannelId, primaryKey: true)
            t.column(excludedChannelName)
            t.column(excludedChannelIconUrl)
            t.column(excludedChannelExcludedAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
            t.column(excludedChannelReason)
        })

        try db.run(favoriteChannels.create(ifNotExists: true) { t in
            t.column(favoriteChannelId, primaryKey: true)
            t.column(favoriteChannelName)
            t.column(favoriteChannelIconUrl)
            t.column(favoriteChannelFavoritedAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
            t.column(favoriteChannelNotes)
            t.column(favoriteChannelLastVisitedAt)
        })

        // Migrate: add last_visited_at to favorite_channels for older databases
        // (the column was introduced in Phase 3 for "new uploads since last visit").
        let favoriteInfo = try db.prepare("PRAGMA table_info(favorite_channels)")
        let favoriteColumns = try Set(favoriteInfo.map { try requiredValue($0, at: 1, as: String.self, context: "favorite_channels schema") })
        if !favoriteColumns.contains("last_visited_at") {
            try db.run("ALTER TABLE favorite_channels ADD COLUMN last_visited_at TEXT")
        }

        try db.run(creatorThemes.create(ifNotExists: true) { t in
            t.column(creatorThemeChannelId)
            t.column(creatorThemeLabel)
            t.column(creatorThemeDescription)
            t.column(creatorThemeOrder)
            t.column(creatorThemeVideoIds)
            t.column(creatorThemeIsSeries, defaultValue: false)
            t.column(creatorThemeOrderingSignal)
            t.column(creatorThemeClassifiedAt)
            t.column(creatorThemeClassifiedVideoCount)
            t.primaryKey(creatorThemeChannelId, creatorThemeLabel)
        })

        try db.run(creatorAbout.create(ifNotExists: true) { t in
            t.column(creatorAboutChannelId, primaryKey: true)
            t.column(creatorAboutSummary)
            t.column(creatorAboutGeneratedAt)
            t.column(creatorAboutSourceVideoCount)
        })

        try db.run(channelLinks.create(ifNotExists: true) { t in
            t.column(channelLinksChannelId, primaryKey: true)
            t.column(channelLinksJSON)
            t.column(channelLinksFetchedAt)
        })

        try db.run("CREATE INDEX IF NOT EXISTS idx_topics_parent_id ON topics(parent_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_videos_topic_source ON videos(topic_id, source_index)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_videos_topic_channel_source ON videos(topic_id, channel_id, source_index)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_playlist_memberships_unique ON playlist_memberships(playlist_id, video_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_playlist_memberships_video ON playlist_memberships(video_id)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_topic_candidates_topic_video ON topic_candidates(topic_id, video_id)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_candidate_sources_unique ON candidate_sources(topic_id, video_id, source_kind, source_ref)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_candidate_state_unique ON candidate_state(topic_id, video_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_topic_candidates_topic_score ON topic_candidates(topic_id, score DESC)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_channel_discovery_archive_unique ON channel_discovery_archive(channel_id, video_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_channel_discovery_archive_channel_published ON channel_discovery_archive(channel_id, published_at DESC)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_commit_log_sync_queue ON commit_log(synced, executor, state, next_attempt_at, created_at)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_seen_videos_video_id ON seen_videos(video_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_seen_videos_seen_at ON seen_videos(seen_at DESC)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_excluded_channels_excluded_at ON excluded_channels(excluded_at DESC)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_favorite_channels_favorited_at ON favorite_channels(favorited_at DESC)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_creator_themes_channel_order ON creator_themes(channel_id, theme_order)")
    }

    // MARK: - Import

    public func importVideos(_ items: [VideoItem]) throws {
        try db.transaction {
            for item in items {
                guard let vid = item.videoId else { continue }
                try db.run(videos.insert(or: .replace,
                    videoId <- vid,
                    videoTitle <- item.title,
                    videoChannel <- item.channelName,
                    videoUrl <- item.videoUrl,
                    videoSourceIndex <- item.sourceIndex,
                    videoTopicId <- nil as Int64?
                ))
            }
        }
    }

    // MARK: - Topics

    public func createTopic(name: String) throws -> Int64 {
        try db.run(topics.insert(
            topicName <- name,
            topicCreatedAt <- ISO8601DateFormatter().string(from: Date())
        ))
    }

    public func renameTopic(id: Int64, to newName: String) throws {
        try db.run(topics.filter(topicId == id).update(topicName <- newName))
    }

    public func deleteTopic(id: Int64) throws {
        // Unassign videos first
        try db.run(videos.filter(videoTopicId == id).update(videoTopicId <- nil as Int64?))
        try db.run(topics.filter(topicId == id).delete())
    }

    public func mergeTopic(sourceId: Int64, intoId: Int64) throws {
        try db.run(videos.filter(videoTopicId == sourceId).update(videoTopicId <- intoId))
        try db.run(topics.filter(topicId == sourceId).delete())
    }

    /// List top-level topics (parent_id IS NULL) with video counts including subtopics.
    public func listTopics() throws -> [TopicSummary] {
        // Count includes videos in subtopics
        let query = """
            SELECT t.id, t.name,
                (SELECT COUNT(*) FROM videos v WHERE v.topic_id = t.id
                 OR v.topic_id IN (SELECT s.id FROM topics s WHERE s.parent_id = t.id)
                ) as video_count
            FROM topics t
            WHERE t.parent_id IS NULL
            ORDER BY video_count DESC
        """
        var results: [TopicSummary] = []
        for row in try db.prepare(query) {
            results.append(TopicSummary(
                id: try requiredValue(row, at: 0, as: Int64.self, context: "listTopics.id"),
                name: try requiredValue(row, at: 1, as: String.self, context: "listTopics.name"),
                videoCount: Int(try requiredValue(row, at: 2, as: Int64.self, context: "listTopics.videoCount")),
                parentId: nil
            ))
        }
        return results
    }

    /// List subtopics for a given parent topic.
    public func subtopicsForTopic(id parentTopicId: Int64) throws -> [TopicSummary] {
        let query = """
            SELECT t.id, t.name, COUNT(v.video_id) as video_count
            FROM topics t
            LEFT JOIN videos v ON v.topic_id = t.id
            WHERE t.parent_id = ?
            GROUP BY t.id
            ORDER BY video_count DESC
        """
        var results: [TopicSummary] = []
        for row in try db.prepare(query, parentTopicId) {
            results.append(TopicSummary(
                id: try requiredValue(row, at: 0, as: Int64.self, context: "subtopicsForTopic.id"),
                name: try requiredValue(row, at: 1, as: String.self, context: "subtopicsForTopic.name"),
                videoCount: Int(try requiredValue(row, at: 2, as: Int64.self, context: "subtopicsForTopic.videoCount")),
                parentId: parentTopicId
            ))
        }
        return results
    }

    /// Create a subtopic under a parent topic. Disambiguates name if it already exists.
    public func createSubtopic(name: String, parentId: Int64) throws -> Int64 {
        var finalName = name
        if try db.pluck(topics.filter(topicName == name)) != nil {
            let parentName = try db.pluck(topics.filter(topicId == parentId)).map { $0[topicName] } ?? ""
            finalName = "\(name) (\(parentName))"
        }
        return try db.run(topics.insert(
            topicName <- finalName,
            topicCreatedAt <- ISO8601DateFormatter().string(from: Date()),
            topicParentId <- parentId
        ))
    }

    /// Delete all subtopics for a parent topic, reassigning their videos to the parent.
    public func deleteSubtopics(parentId: Int64) throws {
        let subtopicIds = try db.prepare(topics.filter(topicParentId == parentId).select(topicId)).map { $0[topicId] }
        for sid in subtopicIds {
            try db.run(videos.filter(videoTopicId == sid).update(videoTopicId <- parentId))
            try db.run(topics.filter(topicId == sid).delete())
        }
    }

    /// List all topics flat (both top-level and subtopics).
    public func listAllTopicsFlat() throws -> [TopicSummary] {
        let query = """
            SELECT t.id, t.name, COUNT(v.video_id) as video_count, t.parent_id
            FROM topics t
            LEFT JOIN videos v ON v.topic_id = t.id
            GROUP BY t.id
            ORDER BY video_count DESC
        """
        var results: [TopicSummary] = []
        for row in try db.prepare(query) {
            results.append(TopicSummary(
                id: try requiredValue(row, at: 0, as: Int64.self, context: "listAllTopicsFlat.id"),
                name: try requiredValue(row, at: 1, as: String.self, context: "listAllTopicsFlat.name"),
                videoCount: Int(try requiredValue(row, at: 2, as: Int64.self, context: "listAllTopicsFlat.videoCount")),
                parentId: try optionalValue(row, at: 3, as: Int64.self, context: "listAllTopicsFlat.parentId")
            ))
        }
        return results
    }

    /// Get all videos for a topic and its subtopics.
    public func videosForTopicIncludingSubtopics(id tid: Int64) throws -> [StoredVideo] {
        let subtopicIds = try db.prepare(topics.filter(topicParentId == tid).select(topicId)).map { $0[topicId] }
        let allIds = [tid] + subtopicIds
        let query = videos.filter(allIds.contains(videoTopicId)).order(videoSourceIndex)
        return try db.prepare(query).map { row in
            StoredVideo(
                videoId: row[videoId],
                title: row[videoTitle],
                channelName: row[videoChannel],
                videoUrl: row[videoUrl],
                sourceIndex: row[videoSourceIndex],
                topicId: row[videoTopicId],
                viewCount: row[videoViewCount],
                publishedAt: row[videoPublishedAt],
                duration: row[videoDuration],
                channelIconUrl: row[videoChannelIconUrl],
                channelId: row[videoChannelId]
            )
        }
    }

    // MARK: - Assignments

    public func assignVideo(videoId vid: String, toTopic tid: Int64) throws {
        try db.run(videos.filter(videoId == vid).update(videoTopicId <- tid))
    }

    public func assignVideos(indices: [Int], toTopic tid: Int64) throws {
        try db.transaction {
            for idx in indices {
                try db.run(videos.filter(videoSourceIndex == idx).update(videoTopicId <- tid))
            }
        }
    }

    public func videosForTopic(id tid: Int64, limit: Int? = nil) throws -> [StoredVideo] {
        var query = videos.filter(videoTopicId == tid).order(videoSourceIndex)
        if let limit { query = query.limit(limit) }

        return try db.prepare(query).map { row in
            StoredVideo(
                videoId: row[videoId],
                title: row[videoTitle],
                channelName: row[videoChannel],
                videoUrl: row[videoUrl],
                sourceIndex: row[videoSourceIndex],
                topicId: row[videoTopicId],
                viewCount: row[videoViewCount],
                publishedAt: row[videoPublishedAt],
                duration: row[videoDuration],
                channelIconUrl: row[videoChannelIconUrl],
                channelId: row[videoChannelId]
            )
        }
    }

    public func unassignedVideos(limit: Int? = nil) throws -> [StoredVideo] {
        var query = videos.filter(videoTopicId == nil as Int64?).order(videoSourceIndex)
        if let limit { query = query.limit(limit) }

        return try db.prepare(query).map { row in
            StoredVideo(
                videoId: row[videoId],
                title: row[videoTitle],
                channelName: row[videoChannel],
                videoUrl: row[videoUrl],
                sourceIndex: row[videoSourceIndex],
                topicId: row[videoTopicId],
                viewCount: row[videoViewCount],
                publishedAt: row[videoPublishedAt],
                duration: row[videoDuration],
                channelIconUrl: row[videoChannelIconUrl],
                channelId: row[videoChannelId]
            )
        }
    }

    public func unassignedCount() throws -> Int {
        try db.scalar(videos.filter(videoTopicId == nil as Int64?).count)
    }

    public func unassignedVideoItems() throws -> [VideoItem] {
        try db.prepare(videos.filter(videoTopicId == nil as Int64?).order(videoSourceIndex)).map { row in
            VideoItem(
                sourceIndex: row[videoSourceIndex],
                title: row[videoTitle],
                videoUrl: row[videoUrl],
                videoId: row[videoId],
                channelName: row[videoChannel],
                metadataText: nil,
                unavailableKind: "none"
            )
        }
    }

    public func topicIdByName(_ name: String) throws -> Int64? {
        try db.pluck(topics.filter(topicName == name)).map { $0[topicId] }
    }

    public func totalVideoCount() throws -> Int {
        try db.scalar(videos.count)
    }

    // MARK: - Channels

    /// Insert or update a channel record.
    public func upsertChannel(_ channel: ChannelRecord) throws {
        try db.run(channels.insert(or: .replace,
            channelId <- channel.channelId,
            channelName <- channel.name,
            channelHandle <- channel.handle,
            channelUrl <- channel.channelUrl,
            channelIconUrl <- channel.iconUrl,
            channelIconData <- channel.iconData.map { SQLite.Blob(bytes: [UInt8]($0)) },
            channelSubscriberCount <- channel.subscriberCount,
            channelDescription <- channel.description,
            channelVideoCountTotal <- channel.videoCountTotal,
            channelFetchedAt <- channel.fetchedAt,
            channelIconFetchedAt <- channel.iconFetchedAt
        ))
    }

    /// Look up a single channel by ID.
    public func channelById(_ id: String) throws -> ChannelRecord? {
        guard let row = try db.pluck(channels.filter(channelId == id)) else { return nil }
        return channelFromRow(row)
    }

    public func excludeChannel(channelId id: String, channelName name: String, iconUrl: String? = nil, reason: String? = nil) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(excludedChannels.insert(or: .replace,
            excludedChannelId <- id,
            excludedChannelName <- name,
            excludedChannelIconUrl <- iconUrl,
            excludedChannelExcludedAt <- now,
            excludedChannelReason <- reason
        ))
    }

    public func restoreExcludedChannel(channelId id: String) throws {
        try db.run(excludedChannels.filter(excludedChannelId == id).delete())
    }

    public func excludedChannelsList() throws -> [ExcludedChannelRecord] {
        try db.prepare(excludedChannels.order(excludedChannelExcludedAt.desc)).map { row in
            ExcludedChannelRecord(
                channelId: row[excludedChannelId],
                channelName: row[excludedChannelName],
                iconUrl: row[excludedChannelIconUrl],
                excludedAt: row[excludedChannelExcludedAt],
                reason: row[excludedChannelReason]
            )
        }
    }

    public func excludedChannelIDs() throws -> Set<String> {
        Set(try db.prepare(excludedChannels.select(excludedChannelId)).map { $0[excludedChannelId] })
    }

    public func isChannelExcluded(_ id: String) throws -> Bool {
        try db.pluck(excludedChannels.filter(excludedChannelId == id)) != nil
    }

    // MARK: - Favorite channels

    /// Insert or update a favorite channel record. The user has explicitly pinned this
    /// creator. Used by the creator detail page Pin toolbar action and consumed in Phase 3
    /// by Watch refresh ranking to boost favorited creators.
    ///
    /// On re-favorite of an existing row, preserves the previously stored `notes` and
    /// `last_visited_at` fields so a Pin click doesn't clobber data the user (or other
    /// code paths) wrote earlier. The favoritedAt timestamp is always refreshed.
    public func favoriteChannel(
        channelId id: String,
        channelName name: String,
        iconUrl: String? = nil,
        notes: String? = nil
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let existing = try db.pluck(favoriteChannels.filter(favoriteChannelId == id))
        let preservedNotes = notes ?? existing?[favoriteChannelNotes]
        let preservedLastVisited = existing?[favoriteChannelLastVisitedAt]
        try db.run(favoriteChannels.insert(or: .replace,
            favoriteChannelId <- id,
            favoriteChannelName <- name,
            favoriteChannelIconUrl <- iconUrl,
            favoriteChannelFavoritedAt <- now,
            favoriteChannelNotes <- preservedNotes,
            favoriteChannelLastVisitedAt <- preservedLastVisited
        ))
    }

    /// Phase 3: stamp the last_visited_at column for the given channel. Idempotent —
    /// updates the timestamp on each call. No-op if the channel is not favorited
    /// (visit tracking is scoped to favorited creators since they have the row).
    public func markChannelVisited(channelId id: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(favoriteChannels
            .filter(favoriteChannelId == id)
            .update(favoriteChannelLastVisitedAt <- now))
    }

    /// Phase 3: read the previous last_visited_at for a channel without updating it.
    /// Used by the creator page builder to compute "new uploads since last visit"
    /// before the page-open then bumps the timestamp.
    public func lastVisitedAt(channelId id: String) throws -> String? {
        guard let row = try db.pluck(favoriteChannels.filter(favoriteChannelId == id)) else {
            return nil
        }
        return row[favoriteChannelLastVisitedAt]
    }

    /// Remove a favorite channel by ID. No-op if the channel was not favorited.
    public func unfavoriteChannel(channelId id: String) throws {
        try db.run(favoriteChannels.filter(favoriteChannelId == id).delete())
    }

    /// Update only the notes field for an existing favorite. Throws if the channel is not
    /// favorited (the caller should call `favoriteChannel(...)` first to upsert).
    public func updateFavoriteChannelNotes(channelId id: String, notes: String?) throws {
        try db.run(favoriteChannels
            .filter(favoriteChannelId == id)
            .update(favoriteChannelNotes <- notes))
    }

    /// Returns all favorited channels, most recently favorited first.
    public func favoriteChannelsList() throws -> [FavoriteChannelRecord] {
        try db.prepare(favoriteChannels.order(favoriteChannelFavoritedAt.desc)).map { row in
            FavoriteChannelRecord(
                channelId: row[favoriteChannelId],
                channelName: row[favoriteChannelName],
                iconUrl: row[favoriteChannelIconUrl],
                favoritedAt: row[favoriteChannelFavoritedAt],
                notes: row[favoriteChannelNotes],
                lastVisitedAt: row[favoriteChannelLastVisitedAt]
            )
        }
    }

    /// Set of all favorited channel IDs. Useful for fast membership checks when
    /// rendering many videos that need a favorite indicator.
    public func favoriteChannelIDs() throws -> Set<String> {
        Set(try db.prepare(favoriteChannels.select(favoriteChannelId)).map { $0[favoriteChannelId] })
    }

    /// Single-channel membership check.
    public func isChannelFavorite(_ id: String) throws -> Bool {
        try db.pluck(favoriteChannels.filter(favoriteChannelId == id)) != nil
    }

    // MARK: - Creator themes (LLM-cached)

    /// Replace all theme rows for a channel with a fresh classification result. Done
    /// in a single transaction so the cache never sits in a half-updated state.
    public func replaceCreatorThemes(channelId id: String, themes: [CreatorThemeRecord]) throws {
        try db.transaction {
            try db.run(creatorThemes.filter(creatorThemeChannelId == id).delete())
            for theme in themes {
                let videoIdsJSON = try jsonStringForArray(theme.videoIds)
                try db.run(creatorThemes.insert(
                    creatorThemeChannelId <- theme.channelId,
                    creatorThemeLabel <- theme.label,
                    creatorThemeDescription <- theme.description,
                    creatorThemeOrder <- theme.order,
                    creatorThemeVideoIds <- videoIdsJSON,
                    creatorThemeIsSeries <- theme.isSeries,
                    creatorThemeOrderingSignal <- theme.orderingSignal,
                    creatorThemeClassifiedAt <- theme.classifiedAt,
                    creatorThemeClassifiedVideoCount <- theme.classifiedVideoCount
                ))
            }
        }
    }

    /// Returns all themes for a channel, ordered by `theme_order`.
    public func creatorThemes(channelId id: String) throws -> [CreatorThemeRecord] {
        let query = creatorThemes
            .filter(creatorThemeChannelId == id)
            .order(creatorThemeOrder.asc)

        return try db.prepare(query).map { row in
            let videoIds = (try? jsonArrayFromString(row[creatorThemeVideoIds])) ?? []
            return CreatorThemeRecord(
                channelId: row[creatorThemeChannelId],
                label: row[creatorThemeLabel],
                description: row[creatorThemeDescription],
                order: row[creatorThemeOrder],
                videoIds: videoIds,
                isSeries: row[creatorThemeIsSeries],
                orderingSignal: row[creatorThemeOrderingSignal],
                classifiedAt: row[creatorThemeClassifiedAt],
                classifiedVideoCount: row[creatorThemeClassifiedVideoCount]
            )
        }
    }

    public func deleteCreatorThemes(channelId id: String) throws {
        try db.run(creatorThemes.filter(creatorThemeChannelId == id).delete())
    }

    // MARK: - Creator about (LLM-cached)

    /// Insert or update the about paragraph for a channel. One row per channel.
    public func upsertCreatorAbout(_ record: CreatorAboutRecord) throws {
        try db.run(creatorAbout.insert(or: .replace,
            creatorAboutChannelId <- record.channelId,
            creatorAboutSummary <- record.summary,
            creatorAboutGeneratedAt <- record.generatedAt,
            creatorAboutSourceVideoCount <- record.sourceVideoCount
        ))
    }

    public func creatorAbout(channelId id: String) throws -> CreatorAboutRecord? {
        guard let row = try db.pluck(creatorAbout.filter(creatorAboutChannelId == id)) else {
            return nil
        }
        return CreatorAboutRecord(
            channelId: row[creatorAboutChannelId],
            summary: row[creatorAboutSummary],
            generatedAt: row[creatorAboutGeneratedAt],
            sourceVideoCount: row[creatorAboutSourceVideoCount]
        )
    }

    public func deleteCreatorAbout(channelId id: String) throws {
        try db.run(creatorAbout.filter(creatorAboutChannelId == id).delete())
    }

    // MARK: - Channel links (Phase 3)

    /// Replace a channel's cached external links. Stores the JSON-encoded
    /// `[ChannelLink]` array verbatim plus a fetched_at timestamp so the
    /// caller can decide when to re-scrape. Empty array is a valid value
    /// (the channel may have no published links).
    public func setChannelLinks(channelId id: String, links: [ChannelLink]) throws {
        let data = try JSONEncoder().encode(links)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(channelLinks.insert(or: .replace,
            channelLinksChannelId <- id,
            channelLinksJSON <- json,
            channelLinksFetchedAt <- now
        ))
    }

    /// Read a channel's cached external links. Returns nil when there's no
    /// cached row at all (caller knows to scrape). Returns an empty array
    /// when there's a row but the creator has no links — distinguishes "not
    /// scraped yet" from "scraped, no links found".
    public func channelLinksForChannel(_ id: String) throws -> [ChannelLink]? {
        guard let row = try db.pluck(channelLinks.filter(channelLinksChannelId == id)) else {
            return nil
        }
        let json = row[channelLinksJSON]
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ChannelLink].self, from: data)) ?? []
    }

    /// Read the fetched_at timestamp for the cached link row, used by the
    /// caller to decide whether to re-scrape stale data.
    public func channelLinksFetchedAtFor(_ id: String) throws -> String? {
        guard let row = try db.pluck(channelLinks.filter(channelLinksChannelId == id)) else {
            return nil
        }
        return row[channelLinksFetchedAt]
    }

    // MARK: - JSON helpers (used by creator_themes video_ids)

    private func jsonStringForArray(_ array: [String]) throws -> String {
        let data = try JSONEncoder().encode(array)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func jsonArrayFromString(_ jsonString: String) throws -> [String] {
        guard let data = jsonString.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Return all channels that have at least one video in the given topic.
    public func channelsForTopic(id topicId: Int64) throws -> [ChannelRecord] {
        let query = """
            SELECT c.*, COUNT(v.video_id) AS topic_video_count
            FROM channels c
            INNER JOIN videos v ON v.channel_id = c.channel_id
            WHERE v.topic_id = ?
            GROUP BY c.channel_id
            ORDER BY topic_video_count DESC
        """
        return try channelsFromRawQuery(query, bindings: [topicId])
    }

    /// Return all channels that have videos in the given topic or its subtopics.
    public func channelsForTopicIncludingSubtopics(id topicId: Int64) throws -> [ChannelRecord] {
        let subtopicIds = try db.prepare(topics.filter(topicParentId == topicId).select(self.topicId)).map { $0[self.topicId] }
        let allIds = [topicId] + subtopicIds
        let placeholders = allIds.map { _ in "?" }.joined(separator: ",")
        let query = """
            SELECT c.*, COUNT(v.video_id) AS topic_video_count
            FROM channels c
            INNER JOIN videos v ON v.channel_id = c.channel_id
            WHERE v.topic_id IN (\(placeholders))
            GROUP BY c.channel_id
            ORDER BY topic_video_count DESC
        """
        let bindings: [Binding] = allIds.map { $0 as Binding }
        return try channelsFromRawQuery(query, bindings: bindings)
    }

    /// Update the cached icon image data for a channel.
    public func updateChannelIcon(channelId cid: String, iconData: Data) throws {
        let blob = SQLite.Blob(bytes: [UInt8](iconData))
        try db.run(channels.filter(channelId == cid).update(
            channelIconData <- blob,
            channelIconFetchedAt <- ISO8601DateFormatter().string(from: Date())
        ))
    }

    /// Set the channel_id foreign key on a video.
    public func setVideoChannelId(videoId vid: String, channelId cid: String) throws {
        try db.run(videos.filter(videoId == vid).update(videoChannelId <- cid))
    }

    /// Return all channel IDs in the channels table.
    public func allChannelIds() throws -> [String] {
        try db.prepare(channels.select(channelId)).map { $0[channelId] }
    }

    /// Return every channel record in the channels table, regardless of whether
    /// the channel is currently referenced by any topic. Used by the offline
    /// backfill to find channels with missing `iconData` blobs that the
    /// per-topic loaders never see (e.g., creators discovered via candidate
    /// search but never saved into a topic).
    public func allChannels() throws -> [ChannelRecord] {
        try db.prepare(channels).map(channelFromRow)
    }

    /// Return video IDs that don't have a channel_id set yet.
    public func videoIdsMissingChannelId() throws -> [String] {
        try db.prepare(videos.filter(videoChannelId == nil as String?).select(videoId)).map { $0[videoId] }
    }

    /// Return videos for a specific channel within a topic (including subtopics).
    public func videosForTopicByChannel(topicId tid: Int64, channelId cid: String) throws -> [StoredVideo] {
        let subtopicIds = try db.prepare(topics.filter(topicParentId == tid).select(topicId)).map { $0[topicId] }
        let allIds = [tid] + subtopicIds
        let query = videos.filter(allIds.contains(videoTopicId) && videoChannelId == cid).order(videoSourceIndex)
        return try db.prepare(query).map { row in
            StoredVideo(
                videoId: row[videoId],
                title: row[videoTitle],
                channelName: row[videoChannel],
                videoUrl: row[videoUrl],
                sourceIndex: row[videoSourceIndex],
                topicId: row[videoTopicId],
                viewCount: row[videoViewCount],
                publishedAt: row[videoPublishedAt],
                duration: row[videoDuration],
                channelIconUrl: row[videoChannelIconUrl],
                channelId: row[videoChannelId]
            )
        }
    }

    /// Count videos for a channel within a topic (including subtopics).
    public func videoCountForChannel(channelId cid: String, inTopic tid: Int64) throws -> Int {
        let subtopicIds = try db.prepare(topics.filter(topicParentId == tid).select(topicId)).map { $0[topicId] }
        let allIds = [tid] + subtopicIds
        return try db.scalar(videos.filter(allIds.contains(videoTopicId) && videoChannelId == cid).count)
    }

    private func channelFromRow(_ row: Row) -> ChannelRecord {
        ChannelRecord(
            channelId: row[channelId],
            name: row[channelName],
            handle: row[channelHandle],
            channelUrl: row[channelUrl],
            iconUrl: row[channelIconUrl],
            iconData: row[channelIconData].map { Data($0.bytes) },
            subscriberCount: row[channelSubscriberCount],
            description: row[channelDescription],
            videoCountTotal: row[channelVideoCountTotal],
            fetchedAt: row[channelFetchedAt],
            iconFetchedAt: row[channelIconFetchedAt]
        )
    }

    private func channelsFromRawQuery(_ query: String, bindings: [Binding]) throws -> [ChannelRecord] {
        var results: [ChannelRecord] = []
        let stmt = try db.prepare(query)
        for row in stmt.bind(bindings) {
            // Raw query columns match channels table order
            guard let cid = row[0] as? String,
                  let name = row[1] as? String else { continue }
            results.append(ChannelRecord(
                channelId: cid,
                name: name,
                handle: row[2] as? String,
                channelUrl: row[3] as? String,
                iconUrl: row[4] as? String,
                iconData: (row[5] as? SQLite.Blob).map { Data($0.bytes) },
                subscriberCount: row[6] as? String,
                description: row[7] as? String,
                videoCountTotal: (row[8] as? Int64).map { Int($0) },
                fetchedAt: row[9] as? String,
                iconFetchedAt: row[10] as? String
            ))
        }
        return results
    }

    // MARK: - Video Metadata

    /// Returns video IDs that are missing metadata (view_count is NULL).
    public func videoIdsMissingMetadata() throws -> [String] {
        try db.prepare(videos.filter(videoViewCount == nil as String?).select(videoId)).map { $0[videoId] }
    }

    /// Returns all videos as VideoItems for classification.
    public func allVideoItems() throws -> [VideoItem] {
        try db.prepare(videos.order(videoSourceIndex)).map { row in
            VideoItem(
                sourceIndex: row[videoSourceIndex],
                title: row[videoTitle],
                videoUrl: row[videoUrl],
                videoId: row[videoId],
                channelName: row[videoChannel],
                metadataText: nil,
                unavailableKind: "none"
            )
        }
    }

    /// Returns all video IDs.
    public func allVideoIds() throws -> [String] {
        try db.prepare(videos.select(videoId)).map { $0[videoId] }
    }

    public func updateVideoMetadata(videoId vid: String, viewCount: String?, publishedAt: String?, duration: String?, channelIconUrl: String? = nil) throws {
        try db.run(videos.filter(videoId == vid).update(
            videoViewCount <- viewCount,
            videoPublishedAt <- publishedAt,
            videoDuration <- duration,
            videoChannelIconUrl <- channelIconUrl
        ))
    }

    // MARK: - Playlists

    public func upsertPlaylist(_ playlist: PlaylistRecord) throws {
        try db.run(playlists.insert(or: .replace,
            playlistId <- playlist.playlistId,
            playlistTitle <- playlist.title,
            playlistVisibility <- playlist.visibility,
            playlistVideoCount <- playlist.videoCount,
            playlistSource <- playlist.source,
            playlistFetchedAt <- playlist.fetchedAt
        ))
    }

    public func replacePlaylistMemberships(playlistId pid: String, memberships: [PlaylistMembershipRecord]) throws {
        try db.transaction {
            try db.run(playlistMemberships.filter(membershipPlaylistId == pid).delete())
            for membership in memberships {
                try db.run(playlistMemberships.insert(or: .replace,
                    membershipPlaylistId <- membership.playlistId,
                    membershipVideoId <- membership.videoId,
                    membershipPosition <- membership.position,
                    membershipVerifiedAt <- membership.verifiedAt
                ))
            }
        }
    }

    public func playlistsForVideo(videoId vid: String) throws -> [PlaylistRecord] {
        let query = """
            SELECT p.playlist_id, p.title, p.visibility, p.video_count, p.source, p.fetched_at
            FROM playlists p
            INNER JOIN playlist_memberships pm ON pm.playlist_id = p.playlist_id
            WHERE pm.video_id = ?
            ORDER BY p.title ASC
        """
        var results: [PlaylistRecord] = []
        for row in try db.prepare(query, vid) {
            results.append(PlaylistRecord(
                playlistId: try requiredValue(row, at: 0, as: String.self, context: "playlistsForVideo.playlistId"),
                title: try requiredValue(row, at: 1, as: String.self, context: "playlistsForVideo.title"),
                visibility: try optionalValue(row, at: 2, as: String.self, context: "playlistsForVideo.visibility"),
                videoCount: try optionalIntValue(row, at: 3, context: "playlistsForVideo.videoCount"),
                source: try optionalValue(row, at: 4, as: String.self, context: "playlistsForVideo.source"),
                fetchedAt: try optionalValue(row, at: 5, as: String.self, context: "playlistsForVideo.fetchedAt")
            ))
        }
        return results
    }

    public func knownPlaylists() throws -> [PlaylistRecord] {
        try db.prepare(playlists.order(playlistTitle.asc)).map { row in
            PlaylistRecord(
                playlistId: row[playlistId],
                title: row[playlistTitle],
                visibility: row[playlistVisibility],
                videoCount: row[playlistVideoCount],
                source: row[playlistSource],
                fetchedAt: row[playlistFetchedAt]
            )
        }
    }

    public func allPlaylistsByVideo() throws -> [String: [PlaylistRecord]] {
        let query = """
            SELECT pm.video_id, p.playlist_id, p.title, p.visibility, p.video_count, p.source, p.fetched_at
            FROM playlist_memberships pm
            INNER JOIN playlists p ON p.playlist_id = pm.playlist_id
            ORDER BY pm.video_id ASC, p.title ASC
        """

        var results: [String: [PlaylistRecord]] = [:]
        for row in try db.prepare(query) {
            let videoId = try requiredValue(row, at: 0, as: String.self, context: "allPlaylistsByVideo.videoId")
            let playlist = PlaylistRecord(
                playlistId: try requiredValue(row, at: 1, as: String.self, context: "allPlaylistsByVideo.playlistId"),
                title: try requiredValue(row, at: 2, as: String.self, context: "allPlaylistsByVideo.title"),
                visibility: try optionalValue(row, at: 3, as: String.self, context: "allPlaylistsByVideo.visibility"),
                videoCount: try optionalIntValue(row, at: 4, context: "allPlaylistsByVideo.videoCount"),
                source: try optionalValue(row, at: 5, as: String.self, context: "allPlaylistsByVideo.source"),
                fetchedAt: try optionalValue(row, at: 6, as: String.self, context: "allPlaylistsByVideo.fetchedAt")
            )
            results[videoId, default: []].append(playlist)
        }
        return results
    }

    // MARK: - Topic Candidates

    public func replaceCandidates(
        forTopic topicId: Int64,
        candidates: [TopicCandidate],
        sources: [CandidateSourceRecord]
    ) throws {
        try db.transaction {
            try db.run(topicCandidates.filter(candidateTopicId == topicId).delete())
            try db.run(candidateSources.filter(candidateTopicId == topicId).delete())

            for candidate in candidates {
                try db.run(topicCandidates.insert(or: .replace,
                    candidateTopicId <- candidate.topicId,
                    candidateVideoId <- candidate.videoId,
                    candidateTitle <- candidate.title,
                    candidateChannelId <- candidate.channelId,
                    candidateChannelName <- candidate.channelName,
                    candidateVideoUrl <- candidate.videoUrl,
                    candidateViewCount <- candidate.viewCount,
                    candidatePublishedAt <- candidate.publishedAt,
                    candidateDuration <- candidate.duration,
                    candidateChannelIconUrl <- candidate.channelIconUrl,
                    candidateScore <- candidate.score,
                    candidateReason <- candidate.reason,
                    candidateDiscoveredAt <- (candidate.discoveredAt ?? ISO8601DateFormatter().string(from: Date()))
                ))
            }

            for source in sources {
                try db.run(candidateSources.insert(or: .replace,
                    candidateTopicId <- source.topicId,
                    candidateVideoId <- source.videoId,
                    candidateSourceKind <- source.sourceKind,
                    candidateSourceRef <- source.sourceRef
                ))
            }
        }
    }

    public func candidatesForTopic(id topicId: Int64, limit: Int? = nil) throws -> [TopicCandidate] {
        var query = """
            SELECT c.topic_id, c.video_id, c.title, c.channel_id, c.channel_name, c.video_url,
                   c.view_count, c.published_at, c.duration, c.channel_icon_url, c.score, c.reason,
                   COALESCE(s.state, 'candidate') AS state, c.discovered_at
            FROM topic_candidates c
            LEFT JOIN candidate_state s
              ON s.topic_id = c.topic_id AND s.video_id = c.video_id
            WHERE c.topic_id = ?
              AND COALESCE(s.state, 'candidate') NOT IN ('dismissed', 'watched')
              AND NOT EXISTS (
                  SELECT 1
                  FROM seen_videos sv
                  WHERE sv.video_id = c.video_id
                    AND sv.video_id IS NOT NULL
                    AND sv.source != 'app'
              )
            ORDER BY c.score DESC, c.published_at DESC
        """
        if let limit {
            query += " LIMIT \(limit)"
        }

        var results: [TopicCandidate] = []
        for row in try db.prepare(query, topicId) {
            results.append(TopicCandidate(
                topicId: try requiredValue(row, at: 0, as: Int64.self, context: "candidatesForTopic.topicId"),
                videoId: try requiredValue(row, at: 1, as: String.self, context: "candidatesForTopic.videoId"),
                title: try requiredValue(row, at: 2, as: String.self, context: "candidatesForTopic.title"),
                channelId: try optionalValue(row, at: 3, as: String.self, context: "candidatesForTopic.channelId"),
                channelName: try optionalValue(row, at: 4, as: String.self, context: "candidatesForTopic.channelName"),
                videoUrl: try optionalValue(row, at: 5, as: String.self, context: "candidatesForTopic.videoUrl"),
                viewCount: try optionalValue(row, at: 6, as: String.self, context: "candidatesForTopic.viewCount"),
                publishedAt: try optionalValue(row, at: 7, as: String.self, context: "candidatesForTopic.publishedAt"),
                duration: try optionalValue(row, at: 8, as: String.self, context: "candidatesForTopic.duration"),
                channelIconUrl: try optionalValue(row, at: 9, as: String.self, context: "candidatesForTopic.channelIconUrl"),
                score: try requiredValue(row, at: 10, as: Double.self, context: "candidatesForTopic.score"),
                reason: try requiredValue(row, at: 11, as: String.self, context: "candidatesForTopic.reason"),
                state: try requiredValue(row, at: 12, as: String.self, context: "candidatesForTopic.state"),
                discoveredAt: try optionalValue(row, at: 13, as: String.self, context: "candidatesForTopic.discoveredAt")
            ))
        }
        return results
    }

    public func candidateForTopic(id topicId: Int64, videoId vid: String) throws -> TopicCandidate? {
        let query = """
            SELECT c.topic_id, c.video_id, c.title, c.channel_id, c.channel_name, c.video_url,
                   c.view_count, c.published_at, c.duration, c.channel_icon_url, c.score, c.reason,
                   COALESCE(s.state, 'candidate') AS state, c.discovered_at
            FROM topic_candidates c
            LEFT JOIN candidate_state s
              ON s.topic_id = c.topic_id AND s.video_id = c.video_id
            WHERE c.topic_id = ?
              AND c.video_id = ?
              AND COALESCE(s.state, 'candidate') NOT IN ('dismissed', 'watched')
              AND NOT EXISTS (
                  SELECT 1
                  FROM seen_videos sv
                  WHERE sv.video_id = c.video_id
                    AND sv.video_id IS NOT NULL
                    AND sv.source != 'app'
              )
            LIMIT 1
        """

        for row in try db.prepare(query, topicId, vid) {
            return TopicCandidate(
                topicId: try requiredValue(row, at: 0, as: Int64.self, context: "candidateForTopic.topicId"),
                videoId: try requiredValue(row, at: 1, as: String.self, context: "candidateForTopic.videoId"),
                title: try requiredValue(row, at: 2, as: String.self, context: "candidateForTopic.title"),
                channelId: try optionalValue(row, at: 3, as: String.self, context: "candidateForTopic.channelId"),
                channelName: try optionalValue(row, at: 4, as: String.self, context: "candidateForTopic.channelName"),
                videoUrl: try optionalValue(row, at: 5, as: String.self, context: "candidateForTopic.videoUrl"),
                viewCount: try optionalValue(row, at: 6, as: String.self, context: "candidateForTopic.viewCount"),
                publishedAt: try optionalValue(row, at: 7, as: String.self, context: "candidateForTopic.publishedAt"),
                duration: try optionalValue(row, at: 8, as: String.self, context: "candidateForTopic.duration"),
                channelIconUrl: try optionalValue(row, at: 9, as: String.self, context: "candidateForTopic.channelIconUrl"),
                score: try requiredValue(row, at: 10, as: Double.self, context: "candidateForTopic.score"),
                reason: try requiredValue(row, at: 11, as: String.self, context: "candidateForTopic.reason"),
                state: try requiredValue(row, at: 12, as: String.self, context: "candidateForTopic.state"),
                discoveredAt: try optionalValue(row, at: 13, as: String.self, context: "candidateForTopic.discoveredAt")
            )
        }

        return nil
    }

    public func setCandidateState(topicId: Int64, videoId: String, state: CandidateState) throws {
        try db.run(candidateState.insert(or: .replace,
            candidateTopicId <- topicId,
            candidateVideoId <- videoId,
            candidateStateValue <- state.rawValue,
            candidateStateUpdatedAt <- ISO8601DateFormatter().string(from: Date())
        ))
    }

    public func latestCandidateDiscoveredAt(topicId: Int64) throws -> String? {
        let query = """
            SELECT MAX(discovered_at)
            FROM topic_candidates
            WHERE topic_id = ?
        """
        for row in try db.prepare(query, topicId) {
            return row[0] as? String
        }
        return nil
    }

    public func upsertChannelDiscoveryArchive(channelId: String, videos: [ArchivedChannelVideo], scannedAt: String) throws {
        try db.transaction {
            for video in videos {
                try db.run(channelDiscoveryArchive.insert(or: .replace,
                    archiveChannelId <- channelId,
                    archiveVideoId <- video.videoId,
                    archiveTitle <- video.title,
                    archiveChannelName <- video.channelName,
                    archivePublishedAt <- video.publishedAt,
                    archiveDuration <- video.duration,
                    archiveViewCount <- video.viewCount,
                    archiveChannelIconUrl <- video.channelIconUrl,
                    archiveFetchedAt <- (video.fetchedAt ?? scannedAt)
                ))
            }

            try db.run(channelDiscoveryState.insert(or: .replace,
                archiveChannelId <- channelId,
                discoveryStateLastScannedAt <- scannedAt
            ))
        }
    }

    public func archivedVideosForChannels(_ channelIds: [String], perChannelLimit: Int = 24) throws -> [ArchivedChannelVideo] {
        guard !channelIds.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: channelIds.count).joined(separator: ",")
        let query = """
            WITH ranked AS (
                SELECT channel_id, video_id, title, channel_name, published_at, duration, view_count, channel_icon_url, fetched_at,
                       ROW_NUMBER() OVER (
                           PARTITION BY channel_id
                           ORDER BY COALESCE(published_at, fetched_at) DESC, video_id DESC
                       ) AS row_number
                FROM channel_discovery_archive
                WHERE channel_id IN (\(placeholders))
            )
            SELECT channel_id, video_id, title, channel_name, published_at, duration, view_count, channel_icon_url, fetched_at
            FROM ranked
            WHERE row_number <= ?
            ORDER BY COALESCE(published_at, fetched_at) DESC, video_id DESC
        """

        var bindings: [Binding?] = channelIds.map { $0 }
        bindings.append(perChannelLimit)

        var results: [ArchivedChannelVideo] = []
        for row in try db.prepare(query, bindings) {
            results.append(ArchivedChannelVideo(
                channelId: try requiredValue(row, at: 0, as: String.self, context: "archivedVideosForChannels.channelId"),
                videoId: try requiredValue(row, at: 1, as: String.self, context: "archivedVideosForChannels.videoId"),
                title: try requiredValue(row, at: 2, as: String.self, context: "archivedVideosForChannels.title"),
                channelName: try optionalValue(row, at: 3, as: String.self, context: "archivedVideosForChannels.channelName"),
                publishedAt: try optionalValue(row, at: 4, as: String.self, context: "archivedVideosForChannels.publishedAt"),
                duration: try optionalValue(row, at: 5, as: String.self, context: "archivedVideosForChannels.duration"),
                viewCount: try optionalValue(row, at: 6, as: String.self, context: "archivedVideosForChannels.viewCount"),
                channelIconUrl: try optionalValue(row, at: 7, as: String.self, context: "archivedVideosForChannels.channelIconUrl"),
                fetchedAt: try optionalValue(row, at: 8, as: String.self, context: "archivedVideosForChannels.fetchedAt")
            ))
        }
        return results
    }

    public func archivedVideoIDsForChannel(_ channelId: String) throws -> Set<String> {
        let query = channelDiscoveryArchive
            .filter(archiveChannelId == channelId)
            .select(archiveVideoId)

        return Set(try db.prepare(query).map { $0[archiveVideoId] })
    }

    /// Phase 3 migration helper: rows where `published_at` looks like a relative
    /// date string ("5 years ago" / "2 months ago" / "Just now") instead of an
    /// ISO 8601 timestamp. The Phase 3 archive normalizer rewrites these on
    /// next-write but historical rows need a one-shot backfill.
    public func archiveRowsWithRelativePublishedAt() throws -> [(channelId: String, videoId: String, publishedAt: String)] {
        let query = """
            SELECT channel_id, video_id, published_at
            FROM channel_discovery_archive
            WHERE published_at IS NOT NULL
              AND (published_at LIKE '% ago%' OR published_at LIKE '%y ago%' OR published_at LIKE '%mo ago%' OR published_at = 'Just now')
        """
        var results: [(String, String, String)] = []
        for row in try db.prepare(query) {
            guard let channelId = row[0] as? String,
                  let videoId = row[1] as? String,
                  let publishedAt = row[2] as? String else { continue }
            results.append((channelId, videoId, publishedAt))
        }
        return results
    }

    /// Phase 3 migration helper: rewrite a single archive row's `published_at`
    /// in place. Used by the relative-date backfill — the caller computes the
    /// normalized ISO 8601 string in Swift and passes it here.
    public func updateArchivePublishedAt(channelId: String, videoId: String, publishedAt: String) throws {
        try db.run(channelDiscoveryArchive
            .filter(archiveChannelId == channelId && archiveVideoId == videoId)
            .update(archivePublishedAt <- publishedAt))
    }

    public func channelDiscoveryLastScannedAt(channelId: String) throws -> String? {
        for row in try db.prepare(channelDiscoveryState.filter(archiveChannelId == channelId).select(discoveryStateLastScannedAt)) {
            return row[discoveryStateLastScannedAt]
        }
        return nil
    }

}

// MARK: - Models

public struct TopicSummary: Sendable {
    public let id: Int64
    public let name: String
    public let videoCount: Int
    public let parentId: Int64?

    public init(id: Int64, name: String, videoCount: Int, parentId: Int64? = nil) {
        self.id = id
        self.name = name
        self.videoCount = videoCount
        self.parentId = parentId
    }
}

public struct StoredVideo: Sendable {
    public let videoId: String
    public let title: String?
    public let channelName: String?
    public let videoUrl: String?
    public let sourceIndex: Int
    public let topicId: Int64?
    public let viewCount: String?
    public let publishedAt: String?
    public let duration: String?
    public let channelIconUrl: String?
    public let channelId: String?
}

public struct SyncAction: Sendable {
    public let id: Int64
    public let videoId: String
    public let action: String
    public let playlist: String
    public let playlistTitle: String?
    public let executor: SyncExecutorKind
    public let attempts: Int
    public let lastError: String?
}

public enum SyncExecutorKind: String, Sendable {
    case api
    case browser
}

public enum SyncQueueState: String, Sendable {
    case queued
    case inProgress = "in_progress"
    case retrying
    case deferred
    case synced
}

public struct SyncFailureRecord: Sendable {
    public let id: Int64
    public let message: String

    public init(id: Int64, message: String) {
        self.id = id
        self.message = message
    }
}

public struct SyncQueueSummary: Sendable {
    public let queued: Int
    public let retrying: Int
    public let deferred: Int
    public let inProgress: Int
    public let browserDeferred: Int

    public init(queued: Int, retrying: Int, deferred: Int, inProgress: Int, browserDeferred: Int) {
        self.queued = queued
        self.retrying = retrying
        self.deferred = deferred
        self.inProgress = inProgress
        self.browserDeferred = browserDeferred
    }
}
