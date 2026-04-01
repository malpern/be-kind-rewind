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

    // Video columns
    private let videoId = SQLite.Expression<String>("video_id")
    private let videoTitle = SQLite.Expression<String?>("title")
    private let videoChannel = SQLite.Expression<String?>("channel_name")
    private let videoUrl = SQLite.Expression<String?>("video_url")
    private let videoSourceIndex = SQLite.Expression<Int>("source_index")
    private let videoTopicId = SQLite.Expression<Int64?>("topic_id")

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

    public func listTopics() throws -> [TopicSummary] {
        let query = """
            SELECT t.id, t.name, COUNT(v.video_id) as video_count
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
                videoCount: Int(row[2] as! Int64)
            ))
        }
        return results
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
                topicId: row[videoTopicId]
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
                topicId: row[videoTopicId]
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
}

public struct StoredVideo: Sendable {
    public let videoId: String
    public let title: String?
    public let channelName: String?
    public let videoUrl: String?
    public let sourceIndex: Int
    public let topicId: Int64?
}

public struct SyncAction: Sendable {
    public let videoId: String
    public let action: String
    public let playlist: String
}
