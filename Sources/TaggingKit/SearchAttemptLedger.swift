import Foundation

/// Tracks the most recent time a topic's search-discovery lane was attempted.
///
/// The Watch refresh runs ~4 search queries per topic, and the YouTube `search.list`
/// endpoint costs 100 estimated units per call when API fallback is enabled. Even with
/// scrape-first discovery the work is non-trivial — Python child processes, network IO,
/// and rate limits — so this ledger throttles each topic to one search lane attempt per
/// 24-hour window.
public final class SearchAttemptLedger: @unchecked Sendable {
    public static let shared = SearchAttemptLedger()

    public static let throttleInterval: TimeInterval = 24 * 60 * 60

    private let fileURL: URL
    private let queue = DispatchQueue(label: "SearchAttemptLedger")
    private var attemptsByTopicId: [Int64: Date] = [:]

    public init(environment: RuntimeEnvironment = RuntimeEnvironment()) {
        let directoryURL = environment.defaultDatabaseURL().deletingLastPathComponent()
            .appendingPathComponent("Telemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.fileURL = directoryURL.appendingPathComponent("search-attempt-ledger.json")
        load()
    }

    public func wasRecentlyAttempted(topicId: Int64, now: Date = Date()) -> Bool {
        queue.sync {
            guard let last = attemptsByTopicId[topicId] else { return false }
            return now.timeIntervalSince(last) < Self.throttleInterval
        }
    }

    public func markAttempted(topicId: Int64, now: Date = Date()) {
        queue.sync {
            attemptsByTopicId[topicId] = now
            persistLocked()
        }
    }

    public func clear(topicId: Int64) {
        queue.sync {
            attemptsByTopicId.removeValue(forKey: topicId)
            persistLocked()
        }
    }

    public func clearAll() {
        queue.sync {
            attemptsByTopicId.removeAll()
            persistLocked()
        }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var attemptsByTopicId: [String: Date]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        var migrated: [Int64: Date] = [:]
        for (key, value) in snapshot.attemptsByTopicId {
            if let id = Int64(key) {
                migrated[id] = value
            }
        }
        queue.sync { attemptsByTopicId = migrated }
    }

    private func persistLocked() {
        let mapped = Dictionary(uniqueKeysWithValues: attemptsByTopicId.map { (String($0.key), $0.value) })
        let snapshot = Snapshot(attemptsByTopicId: mapped)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
