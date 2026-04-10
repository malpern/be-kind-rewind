import Foundation

/// Generates per-creator content themes and a short "About" paragraph by sending the
/// creator's video titles through Claude Haiku.
///
/// One LLM call returns:
/// - 5-10 named theme clusters with descriptions and member video IDs
/// - A per-cluster `is_series` flag (covering both enumerated patterns like
///   "Day 1-30" and thematic patterns like "I tried X for a week")
/// - An optional `ordering_signal` per series cluster (numeric / date / unordered)
///
/// A second small call generates the about paragraph from the same title sample.
///
/// The classifier is stateless and reusable across creators. Caller is responsible
/// for caching the results in `creator_themes` / `creator_about` SQLite tables.
public actor CreatorThemeClassifier {
    private let client: any ClaudeCompleting

    public init(client: any ClaudeCompleting) {
        self.client = client
    }

    // MARK: - Public structs

    public struct ThemeCluster: Sendable, Equatable {
        public let label: String
        public let description: String
        public let videoIds: [String]
        public let isSeries: Bool
        public let orderingSignal: OrderingSignal?

        public init(
            label: String,
            description: String,
            videoIds: [String],
            isSeries: Bool,
            orderingSignal: OrderingSignal?
        ) {
            self.label = label
            self.description = description
            self.videoIds = videoIds
            self.isSeries = isSeries
            self.orderingSignal = orderingSignal
        }
    }

    public enum OrderingSignal: String, Sendable, Equatable {
        case numeric    // Episode N, Day N, Part N — videoIds can be ordered by parsed number
        case date       // Date-based — videoIds can be ordered by publishedAt
        case unordered  // No reliable ordering, but the videos belong together
    }

    public struct ClassificationResult: Sendable, Equatable {
        public let themes: [ThemeCluster]
        public let classifiedVideoCount: Int

        public init(themes: [ThemeCluster], classifiedVideoCount: Int) {
            self.themes = themes
            self.classifiedVideoCount = classifiedVideoCount
        }
    }

    public struct CreatorVideoInput: Sendable, Equatable {
        public let videoId: String
        public let title: String

        public init(videoId: String, title: String) {
            self.videoId = videoId
            self.title = title
        }
    }

    public enum CreatorThemeClassifierError: Error, LocalizedError {
        case emptyInput
        case invalidJSON(String)
        case unknownVideoId(String)

        public var errorDescription: String? {
            switch self {
            case .emptyInput: return "No videos to classify."
            case .invalidJSON(let preview): return "Could not parse Claude response: \(preview)"
            case .unknownVideoId(let id): return "Claude returned an unknown video ID: \(id)"
            }
        }
    }

    // MARK: - Theme classification

    /// Classify a creator's videos into 5-10 themed clusters with series detection.
    /// Cap input at 200 videos for cost discipline. Caller should pre-truncate.
    public func classifyThemes(
        creatorName: String,
        videos: [CreatorVideoInput],
        maxVideos: Int = 200
    ) async throws -> ClassificationResult {
        guard !videos.isEmpty else {
            throw CreatorThemeClassifierError.emptyInput
        }

        let capped = Array(videos.prefix(maxVideos))
        let validVideoIds = Set(capped.map(\.videoId))

        // Use videoId as the index in the prompt so Claude returns the IDs back
        // verbatim rather than trying to match positional indices.
        let titleList = capped.map { v in
            "\(v.videoId): \(v.title)"
        }.joined(separator: "\n")

        let prompt = """
        Analyze the videos by YouTube creator "\(creatorName)" below and group them into \
        5-12 named theme clusters that capture how this creator's content is organized. \
        Each cluster should represent either a recurring topic or a recurring format/series.

        LABEL RULES (very important):
        - Labels MUST be 1-3 words, ideally 1-2. Maximum 24 characters.
        - Use plain noun phrases, no leading articles ("the", "a"), no trailing words.
        - Prefer specific terms unique to this creator over generic ones. \
          Good: "Switch Lubing", "Lily58 Builds", "Audio Reviews". \
          Bad: "Mechanical Keyboard Reviews and Tutorials", "Tech Content", \
          "Videos About Various Topics".
        - If two natural labels overlap, pick the shorter one.

        Videos (format: videoId: title):
        \(titleList)

        For each cluster, decide whether it is a SERIES — meaning the videos can be ordered \
        and follow a sequence. Series can be:
        - "numeric": titles contain numbered references like "Day 1", "Episode 12", "Part 5"
        - "date": titles imply chronological ordering (date-stamped builds, etc.)
        - "unordered": just a recurring theme like "Hot Take #X" or "I tried X for a week"

        Mark `is_series: false` for clusters that are just topic groupings with no ordering.

        Return ONLY a JSON object with this exact shape:
        {
          "clusters": [
            {
              "label": "Short Label",
              "description": "One-sentence description of this cluster",
              "video_ids": ["videoId1", "videoId2", ...],
              "is_series": true,
              "ordering_signal": "numeric"
            },
            ...
          ]
        }

        Every input video MUST appear in exactly one cluster's video_ids. \
        Use the videoId strings exactly as given. \
        If a video doesn't fit a clear theme, put it in a catch-all "Other" cluster. \
        Reminder: every label must be 1-3 words and at most 24 characters.
        """

        let response = try await client.complete(
            prompt: prompt,
            system: "You are a video librarian classifying a creator's catalog into themed clusters and detecting recurring series. Return only valid JSON.",
            model: .haiku,
            maxTokens: 4096
        )

        let themes = try parseClassificationResponse(response, validVideoIds: validVideoIds)
        return ClassificationResult(themes: themes, classifiedVideoCount: capped.count)
    }

    // MARK: - About paragraph

    /// Generate a 3-5 sentence "About" paragraph for the creator from their title sample.
    public func generateAbout(
        creatorName: String,
        videos: [CreatorVideoInput],
        maxVideos: Int = 200
    ) async throws -> String {
        guard !videos.isEmpty else {
            throw CreatorThemeClassifierError.emptyInput
        }

        let capped = Array(videos.prefix(maxVideos))
        let titleList = capped.map(\.title).joined(separator: "\n")

        let prompt = """
        Write a 3-5 sentence summary describing what kind of content the YouTube creator \
        "\(creatorName)" makes. Base it on their video titles below. Be specific about \
        their topics, format, and tone. Do NOT include marketing language or speculation.

        Video titles:
        \(titleList)

        Return ONLY the summary paragraph, no preamble, no quotes, no JSON.
        """

        let response = try await client.complete(
            prompt: prompt,
            system: "You are writing a factual one-paragraph description of a YouTube creator based on their video titles. Be concise and concrete.",
            model: .haiku,
            maxTokens: 512
        )

        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    nonisolated private func parseClassificationResponse(
        _ response: String,
        validVideoIds: Set<String>
    ) throws -> [ThemeCluster] {
        var cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        guard let data = cleaned.data(using: .utf8) else {
            throw CreatorThemeClassifierError.invalidJSON(String(response.prefix(200)))
        }

        struct RawResponse: Decodable {
            let clusters: [RawCluster]
        }
        struct RawCluster: Decodable {
            let label: String
            let description: String?
            let video_ids: [String]
            let is_series: Bool?
            let ordering_signal: String?
        }

        let parsed: RawResponse
        do {
            parsed = try JSONDecoder().decode(RawResponse.self, from: data)
        } catch {
            throw CreatorThemeClassifierError.invalidJSON(String(cleaned.prefix(200)))
        }

        return parsed.clusters.map { raw in
            let validIds = raw.video_ids.filter(validVideoIds.contains)
            let signal: OrderingSignal? = (raw.is_series ?? false)
                ? OrderingSignal(rawValue: raw.ordering_signal ?? "unordered") ?? .unordered
                : nil
            return ThemeCluster(
                label: shortenLabel(raw.label),
                description: raw.description ?? "",
                videoIds: validIds,
                isSeries: raw.is_series ?? false,
                orderingSignal: signal
            )
        }
    }

    /// Safety net for the prompt's "1-3 words, max 24 chars" rule. Trims
    /// whitespace, drops trailing punctuation, and truncates with an ellipsis
    /// if the LLM returned something longer than the limit anyway.
    nonisolated private func shortenLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        let limit = 24
        if trimmed.count <= limit { return trimmed }
        let cut = trimmed.prefix(limit - 1)
        return "\(cut)…"
    }
}
