import Foundation

public enum YouTubeAPIOperation: String, Codable, Sendable, CaseIterable {
    case searchList
    case videosList
    case channelArchiveRefresh
    case channelsListSnippet
    case channelsListContentDetails
    case channelsListStatistics
    case playlistItemsList
    case playlistItemsInsert
    case playlistItemsDelete
    case unknown

    public var estimatedUnits: Int {
        switch self {
        case .searchList:
            return 100
        case .channelArchiveRefresh:
            return 6
        case .playlistItemsInsert, .playlistItemsDelete:
            return 50
        case .videosList, .channelsListSnippet, .channelsListContentDetails, .channelsListStatistics, .playlistItemsList, .unknown:
            return 1
        }
    }

    public var label: String {
        switch self {
        case .searchList:
            return "Search discovery"
        case .videosList:
            return "Video metadata"
        case .channelArchiveRefresh:
            return "Channel archive refresh"
        case .channelsListSnippet:
            return "Channel thumbnails"
        case .channelsListContentDetails:
            return "Channel uploads lookup"
        case .channelsListStatistics:
            return "Channel details"
        case .playlistItemsList:
            return "Playlist read"
        case .playlistItemsInsert:
            return "Add to playlist"
        case .playlistItemsDelete:
            return "Remove from playlist"
        case .unknown:
            return "Other YouTube API call"
        }
    }
}

public enum DiscoveryTelemetryKind: String, Codable, Sendable {
    case channelArchive
    case search
    case channelIcons
    case playlist
    case other
}

public enum DiscoveryTelemetryBackend: String, Codable, Sendable {
    case scrape
    case rss
    case api
}

public enum DiscoveryTelemetryOutcome: String, Codable, Sendable {
    case started
    case succeeded
    case failed
    case skipped
    case approvalRequested
    case approvalGranted
    case approvalDenied
}

public struct YouTubeQuotaEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let operation: YouTubeAPIOperation
    public let estimatedUnits: Int
    public let detail: String
    public let success: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        operation: YouTubeAPIOperation,
        estimatedUnits: Int,
        detail: String,
        success: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operation = operation
        self.estimatedUnits = estimatedUnits
        self.detail = detail
        self.success = success
    }
}

public struct DiscoveryTelemetryEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let kind: DiscoveryTelemetryKind
    public let backend: DiscoveryTelemetryBackend
    public let outcome: DiscoveryTelemetryOutcome
    public let detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        kind: DiscoveryTelemetryKind,
        backend: DiscoveryTelemetryBackend,
        outcome: DiscoveryTelemetryOutcome,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.backend = backend
        self.outcome = outcome
        self.detail = detail
    }
}

public struct YouTubeQuotaSnapshot: Sendable {
    public let dailyLimit: Int
    public let usedUnitsToday: Int
    public let remainingUnitsToday: Int
    public let resetAt: Date
    public let recentAPIEvents: [YouTubeQuotaEvent]
    public let recentDiscoveryEvents: [DiscoveryTelemetryEvent]
}

/// Phase 3: aggregated health signal computed from recent discovery events.
/// Surfaced in the UI so the user can see at a glance whether scraping is
/// working, occasionally failing, or consistently blocked. Computed lazily on
/// demand from the ledger's existing event log — no separate persistence.
public struct ScrapeHealthSnapshot: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case healthy        // most recent attempts succeeded
        case degraded       // some failures but not consistent
        case blocked        // sustained failures, likely blocked or rate limited
        case unknown        // no recent attempts on record
    }

    public let state: State
    public let recentAttempts: Int
    public let recentFailures: Int
    public let lastFailureMessage: String?
    public let lastFailureAt: Date?
    public let lastSuccessAt: Date?
    public let suspectedReason: String?

    public var failureRate: Double {
        recentAttempts > 0 ? Double(recentFailures) / Double(recentAttempts) : 0
    }
}

private struct YouTubeQuotaLedgerStore: Codable {
    var apiEvents: [YouTubeQuotaEvent] = []
    var discoveryEvents: [DiscoveryTelemetryEvent] = []
}

public actor YouTubeQuotaLedger {
    public static let shared = YouTubeQuotaLedger()

    public static let defaultDailyLimit = 10_000

    private let fileURL: URL
    private var store: YouTubeQuotaLedgerStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let pacificCalendar: Calendar

    public init(environment: RuntimeEnvironment = RuntimeEnvironment()) {
        let directoryURL = environment.defaultDatabaseURL().deletingLastPathComponent()
            .appendingPathComponent("Telemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.fileURL = directoryURL.appendingPathComponent("youtube-quota-ledger.json")

        let calendar = Calendar(identifier: .gregorian)
        self.pacificCalendar = calendar

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let initialStore: YouTubeQuotaLedgerStore
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode(YouTubeQuotaLedgerStore.self, from: data) {
            initialStore = decoded
        } else {
            initialStore = YouTubeQuotaLedgerStore()
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        var prunedStore = initialStore
        prunedStore.apiEvents.removeAll { $0.timestamp < cutoff }
        prunedStore.discoveryEvents.removeAll { $0.timestamp < cutoff }
        if prunedStore.apiEvents.count > 1000 {
            prunedStore.apiEvents = Array(prunedStore.apiEvents.suffix(1000))
        }
        if prunedStore.discoveryEvents.count > 1000 {
            prunedStore.discoveryEvents = Array(prunedStore.discoveryEvents.suffix(1000))
        }
        self.store = prunedStore

        if let data = try? encoder.encode(prunedStore) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func recordAPIEvent(
        operation: YouTubeAPIOperation,
        detail: String,
        success: Bool,
        timestamp: Date = Date()
    ) {
        store.apiEvents.append(
            YouTubeQuotaEvent(
                timestamp: timestamp,
                operation: operation,
                estimatedUnits: operation.estimatedUnits,
                detail: detail,
                success: success
            )
        )
        pruneOldEvents()
        persist()
    }

    public func recordDiscoveryEvent(
        kind: DiscoveryTelemetryKind,
        backend: DiscoveryTelemetryBackend,
        outcome: DiscoveryTelemetryOutcome,
        detail: String,
        timestamp: Date = Date()
    ) {
        store.discoveryEvents.append(
            DiscoveryTelemetryEvent(
                timestamp: timestamp,
                kind: kind,
                backend: backend,
                outcome: outcome,
                detail: detail
            )
        )
        pruneOldEvents()
        persist()
    }

    /// Phase 3: derive a scrape health summary from the most recent discovery
    /// events. Looks at attempts in the last `windowMinutes` (default 60) and
    /// classifies the state by failure rate + pattern matching on the most
    /// recent failure message:
    ///
    /// - **healthy**: no failures, or failure rate < 30%
    /// - **degraded**: failure rate 30-70%, or sustained failures with mixed
    ///   success
    /// - **blocked**: failure rate ≥ 70% with at least 3 attempts, OR the most
    ///   recent failure message matches a blocking pattern (HTTP 429, captcha,
    ///   "Sign in to confirm")
    ///
    /// Only counts terminal outcomes (succeeded/failed). `started` events
    /// without a follow-up are ignored. Returns `.unknown` when there are no
    /// recent attempts at all.
    public func scrapeHealth(now: Date = Date(), windowMinutes: Int = 60) -> ScrapeHealthSnapshot {
        let cutoff = now.addingTimeInterval(-Double(windowMinutes) * 60)
        let recent = store.discoveryEvents
            .filter { $0.timestamp >= cutoff }
            .filter { $0.outcome == .succeeded || $0.outcome == .failed }

        guard !recent.isEmpty else {
            return ScrapeHealthSnapshot(
                state: .unknown,
                recentAttempts: 0,
                recentFailures: 0,
                lastFailureMessage: nil,
                lastFailureAt: nil,
                lastSuccessAt: nil,
                suspectedReason: nil
            )
        }

        let failures = recent.filter { $0.outcome == .failed }
        let lastFailure = failures.last
        let lastSuccess = recent.last { $0.outcome == .succeeded }
        let failureRate = Double(failures.count) / Double(recent.count)

        // Pattern detection on the most recent failure message — these
        // substrings indicate the scrape is being actively rejected by YouTube,
        // not just an intermittent timeout.
        let lastMessage = lastFailure?.detail ?? ""
        let lower = lastMessage.lowercased()
        let blockedPatterns: [(String, String)] = [
            ("http 429", "Rate limited (HTTP 429)"),
            ("too many requests", "Rate limited (too many requests)"),
            ("captcha", "Captcha challenge"),
            ("sign in to confirm", "YouTube sign-in challenge"),
            ("err_blocked", "Network blocked"),
            ("forbidden", "Forbidden by upstream"),
            ("403", "HTTP 403"),
        ]
        let matchedReason = blockedPatterns.first(where: { lower.contains($0.0) })?.1

        let state: ScrapeHealthSnapshot.State
        if matchedReason != nil {
            state = .blocked
        } else if failureRate >= 0.7 && recent.count >= 3 {
            state = .blocked
        } else if failureRate >= 0.3 {
            state = .degraded
        } else {
            state = .healthy
        }

        return ScrapeHealthSnapshot(
            state: state,
            recentAttempts: recent.count,
            recentFailures: failures.count,
            lastFailureMessage: lastFailure?.detail,
            lastFailureAt: lastFailure?.timestamp,
            lastSuccessAt: lastSuccess?.timestamp,
            suspectedReason: matchedReason
        )
    }

    public func snapshot(now: Date = Date(), recentLimit: Int = 25) -> YouTubeQuotaSnapshot {
        let dayWindow = pacificDayWindow(containing: now)
        let usedUnits = store.apiEvents
            .filter { $0.timestamp >= dayWindow.start && $0.timestamp < dayWindow.end }
            .reduce(0) { $0 + $1.estimatedUnits }
        return YouTubeQuotaSnapshot(
            dailyLimit: Self.defaultDailyLimit,
            usedUnitsToday: usedUnits,
            remainingUnitsToday: max(0, Self.defaultDailyLimit - usedUnits),
            resetAt: dayWindow.end,
            recentAPIEvents: Array(store.apiEvents.suffix(recentLimit).reversed()),
            recentDiscoveryEvents: Array(store.discoveryEvents.suffix(recentLimit).reversed())
        )
    }

    private func pruneOldEvents(now: Date = Date()) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        store.apiEvents.removeAll { $0.timestamp < cutoff }
        store.discoveryEvents.removeAll { $0.timestamp < cutoff }
        if store.apiEvents.count > 1000 {
            store.apiEvents = Array(store.apiEvents.suffix(1000))
        }
        if store.discoveryEvents.count > 1000 {
            store.discoveryEvents = Array(store.discoveryEvents.suffix(1000))
        }
    }

    private func pacificDayWindow(containing date: Date) -> (start: Date, end: Date) {
        var calendar = pacificCalendar
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        return (start, end)
    }

    private func persist() {
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
