import Foundation
@preconcurrency import SQLite

extension TopicStore {
    @discardableResult
    public func importSeenVideoRecords(_ records: [SeenVideoRecord]) throws -> Int {
        guard !records.isEmpty else { return 0 }

        var imported = 0
        try db.transaction {
            for record in records {
                if try seenRecordExists(record) {
                    continue
                }

                try db.run(seenVideos.insert(
                    seenVideoId <- record.videoId,
                    seenTitle <- record.title,
                    seenChannelName <- record.channelName,
                    seenRawURL <- record.rawURL,
                    seenAt <- record.seenAt,
                    seenSource <- record.source.rawValue,
                    seenConfidence <- record.confidence.rawValue,
                    seenImportedAt <- (record.importedAt ?? ISO8601DateFormatter().string(from: Date()))
                ))
                imported += 1
            }
        }

        return imported
    }

    public func hasSeenVideo(videoId: String) throws -> Bool {
        try db.pluck(seenVideos.filter(seenVideoId == videoId).limit(1)) != nil
    }

    public func seenSummary(videoId: String) throws -> SeenVideoSummary? {
        let query = seenVideos
            .filter(seenVideoId == videoId)
            .order(seenAt.desc)

        var count = 0
        var latestSeenAt: String?
        var latestSource: SeenVideoSource?
        for row in try db.prepare(query) {
            count += 1
            if latestSeenAt == nil {
                latestSeenAt = row[seenAt]
                latestSource = SeenVideoSource(rawValue: row[seenSource])
            }
        }

        guard count > 0 else { return nil }
        return SeenVideoSummary(videoId: videoId, eventCount: count, latestSeenAt: latestSeenAt, latestSource: latestSource)
    }

    /// Bulk fetch seen summaries for a set of video IDs in one SQL pass.
    /// Returns a dictionary keyed by videoId. Videos with no seen history
    /// are omitted (not present in the result).
    public func seenSummaries(videoIds: Set<String>) throws -> [String: SeenVideoSummary] {
        guard !videoIds.isEmpty else { return [:] }
        // Single query with GROUP BY instead of N individual queries
        let placeholders = videoIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT video_id, COUNT(*) as cnt,
                   MAX(seen_at) as latest_at,
                   (SELECT source FROM seen_videos sv2
                    WHERE sv2.video_id = sv.video_id
                    ORDER BY seen_at DESC LIMIT 1) as latest_source
            FROM seen_videos sv
            WHERE video_id IN (\(placeholders))
            GROUP BY video_id
        """
        let bindings: [Binding] = videoIds.map { $0 as Binding }
        var result: [String: SeenVideoSummary] = [:]
        for row in try db.prepare(sql).bind(bindings) {
            guard let videoId = row[0] as? String,
                  let count = row[1] as? Int64 else { continue }
            let latestAt = row[2] as? String
            let latestSource = (row[3] as? String).flatMap(SeenVideoSource.init(rawValue:))
            result[videoId] = SeenVideoSummary(
                videoId: videoId,
                eventCount: Int(count),
                latestSeenAt: latestAt,
                latestSource: latestSource
            )
        }
        return result
    }

    public func seenVideoCount() throws -> Int {
        try db.scalar(seenVideos.count)
    }

    @discardableResult
    public func recordSeenVideo(
        videoId: String,
        title: String? = nil,
        channelName: String? = nil,
        rawURL: String? = nil,
        source: SeenVideoSource,
        confidence: SeenVideoConfidence = .probable
    ) throws -> Int {
        try importSeenVideoRecords([
            SeenVideoRecord(
                videoId: videoId,
                title: title,
                channelName: channelName,
                rawURL: rawURL,
                seenAt: ISO8601DateFormatter().string(from: Date()),
                source: source,
                confidence: confidence,
                importedAt: ISO8601DateFormatter().string(from: Date())
            )
        ])
    }

    func seenRecordExists(_ record: SeenVideoRecord) throws -> Bool {
        var query = seenVideos.filter(seenSource == record.source.rawValue)

        if let videoId = record.videoId {
            query = query.filter(seenVideoId == videoId)
        } else if let rawURL = record.rawURL {
            query = query.filter(seenRawURL == rawURL)
        } else if let title = record.title {
            query = query.filter(seenTitle == title)
        } else {
            return false
        }

        if let seenAt = record.seenAt {
            query = query.filter(self.seenAt == seenAt)
        }

        return try db.pluck(query.limit(1)) != nil
    }
}
