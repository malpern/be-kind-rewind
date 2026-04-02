import Foundation
@preconcurrency import SQLite

/// SQLite-backed store for topics, video assignments, and the commit table.
public final class TopicStore: Sendable {
    private let db: Connection

    // Tables
    private let topics = Table("topics")
    private let videos = Table("videos")
    private let commitLog = Table("commit_log")

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

        try db.run(commitLog.create(ifNotExists: true) { t in
            t.column(commitId, primaryKey: .autoincrement)
            t.column(commitAction) // "add_to_playlist", "remove_from_playlist", "create_playlist"
            t.column(commitVideoId)
            t.column(commitPlaylist)
            t.column(commitCreatedAt, defaultValue: ISO8601DateFormatter().string(from: Date()))
            t.column(commitSynced, defaultValue: false)
        })
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
        var allVideos = try videosForTopic(id: tid)
        for sid in subtopicIds {
            allVideos.append(contentsOf: try videosForTopic(id: sid))
        }
        return allVideos.sorted { $0.sourceIndex < $1.sourceIndex }
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
                channelIconUrl: row[videoChannelIconUrl]
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
                channelIconUrl: row[videoChannelIconUrl]
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
}

public struct SyncAction: Sendable {
    public let videoId: String
    public let action: String
    public let playlist: String
}
