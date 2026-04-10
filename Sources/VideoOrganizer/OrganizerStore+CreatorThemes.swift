import Foundation
import TaggingKit

extension OrganizerStore {
    /// Trigger Claude theme classification + about generation for a creator if all of:
    /// - The user has flipped on `claudeThemeClassificationEnabled` in Settings
    /// - A `creatorThemeClassifier` is configured (Claude API key present)
    /// - The cache for this channel is empty
    /// - We're not already classifying this channel
    ///
    /// Runs the two LLM calls (themes + about) in parallel and writes the results to
    /// the local SQLite cache. The page view observes `classifyingThemeChannels` to
    /// show a loading indicator and rebuilds itself from the cache when this method
    /// completes (the .task(id: channelId) on the page handles re-fetch).
    func classifyCreatorThemesIfNeeded(channelId: String, channelName: String) {
        guard claudeThemeClassificationEnabled else { return }
        guard let classifier = creatorThemeClassifier else { return }
        guard !classifyingThemeChannels.contains(channelId) else { return }

        // If the cache already has data, do nothing — re-classification is opt-in.
        if let existing = try? store.creatorThemes(channelId: channelId), !existing.isEmpty {
            return
        }

        // Collect titles from saved + archive videos for this creator. Cap upstream
        // to keep the LLM call bounded.
        let inputs = collectClassifierInputs(forChannelId: channelId)
        guard !inputs.isEmpty else { return }

        classifyingThemeChannels.insert(channelId)
        AppLogger.app.info("Started Claude theme classification for \(channelName, privacy: .public) (\(channelId, privacy: .public)) over \(inputs.count, privacy: .public) videos")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.classifyingThemeChannels.remove(channelId)
            }

            await self.runClassificationAndAbout(
                classifier: classifier,
                channelId: channelId,
                channelName: channelName,
                inputs: inputs
            )
        }
    }

    /// Manually clear the LLM cache for a single creator. Useful for "Refresh themes"
    /// affordances or when the user wants to re-run with newer videos.
    func clearCreatorThemeCache(channelId: String) {
        do {
            try store.deleteCreatorThemes(channelId: channelId)
            try store.deleteCreatorAbout(channelId: channelId)
            AppLogger.app.info("Cleared theme cache for \(channelId, privacy: .public)")
        } catch {
            AppLogger.app.error("Failed to clear theme cache for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private helpers

    /// Walks the same data sources as CreatorPageBuilder (saved videos + archive)
    /// and returns deduped (videoId, title) inputs for the classifier.
    private func collectClassifierInputs(forChannelId channelId: String) -> [CreatorThemeClassifier.CreatorVideoInput] {
        var seen = Set<String>()
        var inputs: [CreatorThemeClassifier.CreatorVideoInput] = []

        // Saved videos for this creator across every topic the user has.
        for topic in topics {
            let videos = videosForTopicIncludingSubtopics(topic.id)
                .filter { $0.channelId == channelId }
            for video in videos where seen.insert(video.videoId).inserted {
                inputs.append(.init(videoId: video.videoId, title: video.title))
            }
        }

        // Archive videos that aren't already in the saved set.
        if let archive = try? store.archivedVideosForChannels([channelId], perChannelLimit: 200) {
            for entry in archive where seen.insert(entry.videoId).inserted {
                inputs.append(.init(videoId: entry.videoId, title: entry.title))
            }
        }

        return inputs
    }

    private func runClassificationAndAbout(
        classifier: CreatorThemeClassifier,
        channelId: String,
        channelName: String,
        inputs: [CreatorThemeClassifier.CreatorVideoInput]
    ) async {
        // Classification + about run in parallel — they're independent calls.
        async let themesResult = Task {
            try await classifier.classifyThemes(creatorName: channelName, videos: inputs)
        }.value

        async let aboutResult = Task {
            try await classifier.generateAbout(creatorName: channelName, videos: inputs)
        }.value

        // Themes
        do {
            let result = try await themesResult
            let now = ISO8601DateFormatter().string(from: Date())
            let records = result.themes.enumerated().map { index, cluster in
                CreatorThemeRecord(
                    channelId: channelId,
                    label: cluster.label,
                    description: cluster.description.isEmpty ? nil : cluster.description,
                    order: index,
                    videoIds: cluster.videoIds,
                    isSeries: cluster.isSeries,
                    orderingSignal: cluster.orderingSignal?.rawValue,
                    classifiedAt: now,
                    classifiedVideoCount: result.classifiedVideoCount
                )
            }
            try store.replaceCreatorThemes(channelId: channelId, themes: records)
            AppLogger.app.info("Cached \(records.count, privacy: .public) themes for \(channelName, privacy: .public)")
        } catch {
            AppLogger.app.error("Theme classification failed for \(channelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // About
        do {
            let summary = try await aboutResult
            let record = CreatorAboutRecord(
                channelId: channelId,
                summary: summary,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                sourceVideoCount: inputs.count
            )
            try store.upsertCreatorAbout(record)
            AppLogger.app.info("Cached about paragraph for \(channelName, privacy: .public) (\(summary.count, privacy: .public) chars)")
        } catch {
            AppLogger.app.error("About generation failed for \(channelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
