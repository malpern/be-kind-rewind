import Foundation
@preconcurrency import SQLite

/// SQLite-backed store for topics, video assignments, and the commit table.
public final class TopicStore: Sendable {
    private let db: Connection

    // Tables
    private let topics = Table("topics")
    private let videos = Table("videos")
    private let commitLog = Table("commit_log")
    private let channels = Table("channels")
    private let playlists = Table("playlists")
    private let playlistMemberships = Table("playlist_memberships")
    private let topicCandidates = Table("topic_candidates")
    private let candidateSources = Table("candidate_sources")
    private let candidateState = Table("candidate_state")

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
    private let playlistId = SQLite.Expression<String>("playlist_id")
    private let playlistTitle = SQLite.Expression<String>("title")
    private let playlistVisibility = SQLite.Expression<String?>("visibility")
    private let playlistVideoCount = SQLite.Expression<Int?>("video_count")
    private let playlistSource = SQLite.Expression<String?>("source")
    private let playlistFetchedAt = SQLite.Expression<String?>("fetched_at")
    private let membershipPlaylistId = SQLite.Expression<String>("playlist_id")
    private let membershipVideoId = SQLite.Expression<String>("video_id")
    private let membershipPosition = SQLite.Expression<Int?>("position")
    private let membershipVerifiedAt = SQLite.Expression<String?>("verified_at")

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

    // Commit log columns
    private let commitId = SQLite.Expression<Int64>("id")
    private let commitAction = SQLite.Expression<String>("action")
    private let commitVideoId = SQLite.Expression<String>("video_id")
    private let commitPlaylist = SQLite.Expression<String>("playlist")
    private let commitCreatedAt = SQLite.Expression<String>("created_at")
    private let commitSynced = SQLite.Expression<Bool>("synced")

    public init(path: String) throws {
        db = try Connection(path)
        try createTables()
    }

    public init(inMemory: Bool = true) throws {
        db = try Connection(.inMemory)
        try createTables()
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
        let existingColumns = Set(tableInfo.map { $0[1] as! String })
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
        let topicColumns = Set(topicInfo.map { $0[1] as! String })
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
        })

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

        try db.run("CREATE INDEX IF NOT EXISTS idx_topics_parent_id ON topics(parent_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_videos_topic_source ON videos(topic_id, source_index)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_videos_topic_channel_source ON videos(topic_id, channel_id, source_index)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_playlist_memberships_unique ON playlist_memberships(playlist_id, video_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_playlist_memberships_video ON playlist_memberships(video_id)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_topic_candidates_topic_video ON topic_candidates(topic_id, video_id)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_candidate_sources_unique ON candidate_sources(topic_id, video_id, source_kind, source_ref)")
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_candidate_state_unique ON candidate_state(topic_id, video_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_topic_candidates_topic_score ON topic_candidates(topic_id, score DESC)")
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
                id: row[0] as! Int64,
                name: row[1] as! String,
                videoCount: Int(row[2] as! Int64),
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
                id: row[0] as! Int64,
                name: row[1] as! String,
                videoCount: Int(row[2] as! Int64),
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
                id: row[0] as! Int64,
                name: row[1] as! String,
                videoCount: Int(row[2] as! Int64),
                parentId: row[3] as? Int64
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
                playlistId: row[0] as! String,
                title: row[1] as! String,
                visibility: row[2] as? String,
                videoCount: row[3] as? Int64 != nil ? Int(row[3] as! Int64) : nil,
                source: row[4] as? String,
                fetchedAt: row[5] as? String
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
            let videoId = row[0] as! String
            let playlist = PlaylistRecord(
                playlistId: row[1] as! String,
                title: row[2] as! String,
                visibility: row[3] as? String,
                videoCount: row[4] as? Int64 != nil ? Int(row[4] as! Int64) : nil,
                source: row[5] as? String,
                fetchedAt: row[6] as? String
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
            ORDER BY c.score DESC, c.published_at DESC
        """
        if let limit {
            query += " LIMIT \(limit)"
        }

        var results: [TopicCandidate] = []
        for row in try db.prepare(query, topicId) {
            results.append(TopicCandidate(
                topicId: row[0] as! Int64,
                videoId: row[1] as! String,
                title: row[2] as! String,
                channelId: row[3] as? String,
                channelName: row[4] as? String,
                videoUrl: row[5] as? String,
                viewCount: row[6] as? String,
                publishedAt: row[7] as? String,
                duration: row[8] as? String,
                channelIconUrl: row[9] as? String,
                score: row[10] as! Double,
                reason: row[11] as! String,
                state: row[12] as! String,
                discoveredAt: row[13] as? String
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
            LIMIT 1
        """

        for row in try db.prepare(query, topicId, vid) {
            return TopicCandidate(
                topicId: row[0] as! Int64,
                videoId: row[1] as! String,
                title: row[2] as! String,
                channelId: row[3] as? String,
                channelName: row[4] as? String,
                videoUrl: row[5] as? String,
                viewCount: row[6] as? String,
                publishedAt: row[7] as? String,
                duration: row[8] as? String,
                channelIconUrl: row[9] as? String,
                score: row[10] as! Double,
                reason: row[11] as! String,
                state: row[12] as! String,
                discoveredAt: row[13] as? String
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

    // MARK: - Commit Table

    public func queueCommit(action: String, videoId vid: String, playlist: String) throws {
        try db.run(commitLog.insert(
            commitAction <- action,
            commitVideoId <- vid,
            commitPlaylist <- playlist,
            commitCreatedAt <- ISO8601DateFormatter().string(from: Date()),
            commitSynced <- false
        ))
    }

    /// Returns the net-effect sync plan: collapsed, deduplicated, no-ops removed.
    public func pendingSyncPlan() throws -> [SyncAction] {
        let pending = commitLog.filter(commitSynced == false).order(commitCreatedAt)
        var latestAction: [String: (action: String, playlist: String)] = [:] // keyed by videoId

        for row in try db.prepare(pending) {
            let vid = row[commitVideoId]
            latestAction[vid] = (action: row[commitAction], playlist: row[commitPlaylist])
        }

        return latestAction.map { vid, entry in
            SyncAction(videoId: vid, action: entry.action, playlist: entry.playlist)
        }.sorted { $0.videoId < $1.videoId }
    }

    public func markSynced() throws {
        try db.run(commitLog.filter(commitSynced == false).update(commitSynced <- true))
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
    public let videoId: String
    public let action: String
    public let playlist: String
}
