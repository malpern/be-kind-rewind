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
