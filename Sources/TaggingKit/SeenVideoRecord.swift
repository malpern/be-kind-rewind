import Foundation

public struct SeenVideoRecord: Sendable, Identifiable {
    public let videoId: String?
    public let title: String?
    public let channelName: String?
    public let rawURL: String?
    public let seenAt: String?
    public let source: SeenVideoSource
    public let confidence: SeenVideoConfidence
    public let importedAt: String?

    public var id: String {
        [videoId, rawURL, seenAt, source.rawValue]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    public init(
        videoId: String?,
        title: String? = nil,
        channelName: String? = nil,
        rawURL: String? = nil,
        seenAt: String? = nil,
        source: SeenVideoSource,
        confidence: SeenVideoConfidence,
        importedAt: String? = nil
    ) {
        self.videoId = videoId
        self.title = title
        self.channelName = channelName
        self.rawURL = rawURL
        self.seenAt = seenAt
        self.source = source
        self.confidence = confidence
        self.importedAt = importedAt
    }
}

public enum SeenVideoSource: String, Sendable, CaseIterable {
    case takeout
    case myActivity
    case manual
    case browser
}

public enum SeenVideoConfidence: String, Sendable, CaseIterable {
    case confirmed
    case probable
}

public struct SeenVideoSummary: Sendable {
    public let videoId: String
    public let eventCount: Int
    public let latestSeenAt: String?
    public let latestSource: SeenVideoSource?

    public init(videoId: String, eventCount: Int, latestSeenAt: String?, latestSource: SeenVideoSource?) {
        self.videoId = videoId
        self.eventCount = eventCount
        self.latestSeenAt = latestSeenAt
        self.latestSource = latestSource
    }
}

public enum SeenHistoryImportError: Error, LocalizedError {
    case unsupportedFile(URL)
    case noRecognizedRecords(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            return "Unsupported seen-history file: \(url.lastPathComponent)"
        case .noRecognizedRecords(let url):
            return "No YouTube watch-history records were recognized in \(url.lastPathComponent)"
        }
    }
}

public enum SeenHistoryImporter {
    public static func loadRecords(from url: URL, source: SeenVideoSource? = nil) throws -> [SeenVideoRecord] {
        let ext = url.pathExtension.lowercased()
        if ext == "json" {
            let chosenSource = source ?? .takeout
            let records = try loadJSONRecords(from: url, source: chosenSource)
            guard !records.isEmpty else { throw SeenHistoryImportError.noRecognizedRecords(url) }
            return records
        }

        if ["html", "htm", "txt"].contains(ext) {
            let chosenSource = source ?? .takeout
            let records = try loadHTMLRecords(from: url, source: chosenSource)
            guard !records.isEmpty else { throw SeenHistoryImportError.noRecognizedRecords(url) }
            return records
        }

        throw SeenHistoryImportError.unsupportedFile(url)
    }

    private static func loadJSONRecords(from url: URL, source: SeenVideoSource) throws -> [SeenVideoRecord] {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        var records: [SeenVideoRecord] = []
        collectJSONRecords(from: json, source: source, into: &records)
        return dedupe(records)
    }

    private static func collectJSONRecords(from value: Any, source: SeenVideoSource, into records: inout [SeenVideoRecord]) {
        if let dict = value as? [String: Any] {
            if let record = makeJSONRecord(from: dict, source: source) {
                records.append(record)
            }

            for nested in dict.values {
                collectJSONRecords(from: nested, source: source, into: &records)
            }
            return
        }

        if let array = value as? [Any] {
            for element in array {
                collectJSONRecords(from: element, source: source, into: &records)
            }
        }
    }

    private static func makeJSONRecord(from dict: [String: Any], source: SeenVideoSource) -> SeenVideoRecord? {
        let importedAt = ISO8601DateFormatter().string(from: Date())

        let directURL = firstString(in: dict, keys: ["titleUrl", "url", "link", "raw_url"])
        let nestedSubtitle = subtitleChannelName(from: dict)
        let title = firstString(in: dict, keys: ["title", "name"])
        let seenAt = normalizedTimestamp(
            firstString(in: dict, keys: ["time", "seenAt", "time_usec", "timestamp", "date"])
        )

        let rawURL = extractYouTubeURL(from: directURL)
            ?? extractYouTubeURL(from: title)
            ?? firstYouTubeURL(in: dict)
        let videoId = rawURL.flatMap(extractVideoID(from:))

        let looksLikeWatchRecord =
            videoId != nil ||
            ((title?.localizedCaseInsensitiveContains("watched") ?? false) && rawURL != nil) ||
            ((firstString(in: dict, keys: ["header"])?.localizedCaseInsensitiveContains("youtube") ?? false) && rawURL != nil)

        guard looksLikeWatchRecord else { return nil }

        return SeenVideoRecord(
            videoId: videoId,
            title: normalizedTitle(title),
            channelName: nestedSubtitle,
            rawURL: rawURL,
            seenAt: seenAt,
            source: source,
            confidence: videoId != nil ? .confirmed : .probable,
            importedAt: importedAt
        )
    }

    private static func loadHTMLRecords(from url: URL, source: SeenVideoSource) throws -> [SeenVideoRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let importedAt = ISO8601DateFormatter().string(from: Date())
        let pattern = #"<a\s+href="([^"]*youtube\.com/watch\?[^"]+|[^"]*youtu\.be/[^"]+)".*?>(.*?)</a>(?s)(.*?)(?:</div>|<br>)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        let records: [SeenVideoRecord] = matches.compactMap { match in
            guard match.numberOfRanges >= 4 else { return nil }
            let rawURL = htmlDecoded(nsText.substring(with: match.range(at: 1)))
            let title = htmlDecoded(strippingTags(from: nsText.substring(with: match.range(at: 2))))
            let trailing = htmlDecoded(strippingTags(from: nsText.substring(with: match.range(at: 3))))
            let videoId = extractVideoID(from: rawURL)
            let seenAt = normalizedTimestamp(firstDateLikeString(in: trailing))

            return SeenVideoRecord(
                videoId: videoId,
                title: normalizedTitle(title),
                channelName: nil,
                rawURL: rawURL,
                seenAt: seenAt,
                source: source,
                confidence: videoId != nil ? .confirmed : .probable,
                importedAt: importedAt
            )
        }

        if !records.isEmpty {
            return dedupe(records)
        }

        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var fallbackRecords: [SeenVideoRecord] = []
        detector.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let url = match?.url?.absoluteString,
                  let normalizedURL = extractYouTubeURL(from: url),
                  let videoId = extractVideoID(from: normalizedURL)
            else {
                return
            }

            fallbackRecords.append(SeenVideoRecord(
                videoId: videoId,
                title: nil,
                channelName: nil,
                rawURL: normalizedURL,
                seenAt: nil,
                source: source,
                confidence: .confirmed,
                importedAt: importedAt
            ))
        }

        return dedupe(fallbackRecords)
    }

    private static func dedupe(_ records: [SeenVideoRecord]) -> [SeenVideoRecord] {
        var seen: Set<String> = []
        var deduped: [SeenVideoRecord] = []
        for record in records {
            let key = [
                record.videoId ?? "",
                record.rawURL ?? "",
                record.seenAt ?? "",
                record.source.rawValue
            ].joined(separator: "|")

            if seen.insert(key).inserted {
                deduped.append(record)
            }
        }
        return deduped
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func subtitleChannelName(from dict: [String: Any]) -> String? {
        if let subtitles = dict["subtitles"] as? [[String: Any]] {
            for subtitle in subtitles {
                if let name = firstString(in: subtitle, keys: ["name", "title"]) {
                    return name
                }
            }
        }

        if let subtitle = dict["subtitle"] as? [String: Any] {
            return firstString(in: subtitle, keys: ["name", "title"])
        }

        return nil
    }

    private static func firstYouTubeURL(in dict: [String: Any]) -> String? {
        for value in dict.values {
            if let string = value as? String,
               let url = extractYouTubeURL(from: string) {
                return url
            }

            if let nested = value as? [String: Any],
               let url = firstYouTubeURL(in: nested) {
                return url
            }

            if let nestedArray = value as? [Any] {
                for item in nestedArray {
                    if let nested = item as? [String: Any],
                       let url = firstYouTubeURL(in: nested) {
                        return url
                    }
                    if let string = item as? String,
                       let url = extractYouTubeURL(from: string) {
                        return url
                    }
                }
            }
        }
        return nil
    }

    private static func extractYouTubeURL(from value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let patterns = [
            #"https?://(?:www\.)?youtube\.com/watch\?[^\s"'<>]+"#,
            #"https?://youtu\.be/[A-Za-z0-9_-]{11}[^\s"'<>]*"#
        ]

        for pattern in patterns {
            if let range = value.range(of: pattern, options: .regularExpression) {
                return String(value[range])
            }
        }
        return nil
    }

    public static func extractVideoID(from url: String) -> String? {
        if let range = url.range(of: #"(?<=[?&]v=)[A-Za-z0-9_-]{11}"#, options: .regularExpression) {
            return String(url[range])
        }
        if let range = url.range(of: #"youtu\.be/([A-Za-z0-9_-]{11})"#, options: .regularExpression) {
            let match = String(url[range])
            return String(match.suffix(11))
        }
        return nil
    }

    private static func normalizedTimestamp(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) {
            return iso.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "MMM d, yyyy, h:mm:ss a z",
            "MMM d, yyyy, h:mm:ss a",
            "MMM d, yyyy, h:mm a",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return iso.string(from: date)
            }
        }

        return nil
    }

    private static func normalizedTitle(_ value: String?) -> String? {
        let title = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return title.replacingOccurrences(of: "Watched ", with: "")
    }

    private static func strippingTags(from value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func htmlDecoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstDateLikeString(in value: String) -> String? {
        let patterns = [
            #"[A-Z][a-z]{2}\s+\d{1,2},\s+\d{4},\s+\d{1,2}:\d{2}(?::\d{2})?\s+[AP]M(?:\s+\w+)?"#,
            #"\d{4}-\d{2}-\d{2}(?:\s+\d{2}:\d{2}:\d{2}(?:\s+[+-]\d{4})?)?"#
        ]

        for pattern in patterns {
            if let range = value.range(of: pattern, options: .regularExpression) {
                return String(value[range])
            }
        }
        return nil
    }
}
