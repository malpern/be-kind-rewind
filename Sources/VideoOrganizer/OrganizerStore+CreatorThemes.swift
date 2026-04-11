import Foundation
import TaggingKit

extension OrganizerStore {
    /// Trigger Claude theme classification + about generation for a creator if all of:
    /// - The user has flipped on `claudeThemeClassificationEnabled` in Settings
    /// - A `creatorThemeClassifier` is configured (Claude API key present)
    /// - The cache for this channel is empty
    /// - We're not already classifying this channel
    /// - **The channel's archive has been loaded** (see comment below)
    ///
    /// Runs the two LLM calls (themes + about) in parallel and writes the results to
    /// the local SQLite cache. The page view observes `classifyingThemeChannels` to
    /// show a loading indicator and rebuilds itself from the cache when this method
    /// completes (the .task(id: channelId) on the page handles re-fetch).
    func classifyCreatorThemesIfNeeded(channelId: String, channelName: String, force: Bool = false) {
        guard claudeThemeClassificationEnabled else { return }
        guard let classifier = creatorThemeClassifier else { return }
        guard !classifyingThemeChannels.contains(channelId) else { return }

        // Phase 3 gating: never classify themes from a partial dataset. The
        // channel must have a populated discovery archive first — otherwise
        // we'd burn LLM tokens classifying just the user's saved videos
        // (typically <10) instead of the full catalog. Skipped when force=true
        // (manual refresh button) since the user is explicitly opting in.
        if !force {
            let archived = (try? store.archivedVideoIDsForChannel(channelId)) ?? []
            guard !archived.isEmpty else {
                AppLogger.app.info("Skipping theme classification for \(channelName, privacy: .public) — archive not yet loaded")
                return
            }
        }

        // Collect inputs first so we can compare against the cached count for
        // staleness detection below.
        let inputs = collectClassifierInputs(forChannelId: channelId)
        guard !inputs.isEmpty else { return }

        // Independently decide whether themes and about each need to be
        // (re)generated. The previous version only checked themes — if themes
        // were fresh but about was missing, the function returned early and
        // about never got generated. Same the other way around. Now each
        // cache is queried separately and we only run the LLM calls that are
        // actually needed.
        let themesNeeded = force || isThemesCacheStale(channelId: channelId, currentInputCount: inputs.count, channelName: channelName)
        let aboutNeeded = force || isAboutCacheMissing(channelId: channelId)

        guard themesNeeded || aboutNeeded else {
            AppLogger.app.info("Both theme + about caches fresh for \(channelName, privacy: .public) — skipping LLM run")
            return
        }

        if force {
            AppLogger.app.info("Forcing theme/about regeneration for \(channelName, privacy: .public) (\(channelId, privacy: .public))")
        }

        classifyingThemeChannels.insert(channelId)
        AppLogger.app.info("Started Claude run for \(channelName, privacy: .public): themes=\(themesNeeded, privacy: .public) about=\(aboutNeeded, privacy: .public) over \(inputs.count, privacy: .public) videos")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.classifyingThemeChannels.remove(channelId)
            }

            await self.runClassificationAndAbout(
                classifier: classifier,
                channelId: channelId,
                channelName: channelName,
                inputs: inputs,
                generateThemes: themesNeeded,
                generateAbout: aboutNeeded
            )
        }
    }

    /// Returns true when the cached themes for this channel either don't
    /// exist or are stale enough (≥25% growth AND ≥5 new videos) to warrant
    /// re-classification. Returns false (cache fresh) for the steady-state
    /// case where the user is just navigating between cached creators.
    private func isThemesCacheStale(channelId: String, currentInputCount: Int, channelName: String) -> Bool {
        guard let existing = try? store.creatorThemes(channelId: channelId), !existing.isEmpty else {
            return true  // No cache → needs to run
        }
        let cachedCount = existing.first?.classifiedVideoCount ?? 0
        let growth = currentInputCount - cachedCount
        let growthRatio = cachedCount > 0 ? Double(growth) / Double(cachedCount) : 1.0
        let isStale = growth >= 5 && growthRatio >= 0.25
        if isStale {
            AppLogger.app.info("Theme cache stale for \(channelName, privacy: .public): \(cachedCount, privacy: .public) → \(currentInputCount, privacy: .public) videos (+\(Int(growthRatio * 100), privacy: .public)%)")
        }
        return isStale
    }

    /// Returns true when there's no cached about paragraph for this channel.
    /// About paragraphs don't have a staleness check — once generated they
    /// stay until manually refreshed via force=true.
    private func isAboutCacheMissing(channelId: String) -> Bool {
        let cached = (try? store.creatorAbout(channelId: channelId))
        return cached == nil
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
        inputs: [CreatorThemeClassifier.CreatorVideoInput],
        generateThemes: Bool,
        generateAbout: Bool
    ) async {
        // Run only the LLM calls that the caller asked for. The two calls
        // are still parallel via async-let when both are requested. When
        // only one is needed (typical follow-up case where themes are
        // cached but about is missing, or vice versa) we save the other
        // call's tokens entirely.
        if generateThemes && generateAbout {
            async let themesResult = Task {
                try await classifier.classifyThemes(creatorName: channelName, videos: inputs)
            }.value
            async let aboutResult = Task {
                try await classifier.generateAbout(creatorName: channelName, videos: inputs)
            }.value
            await persistThemes(try? themesResult, channelId: channelId, channelName: channelName)
            await persistAbout(try? aboutResult, channelId: channelId, channelName: channelName, inputCount: inputs.count)
        } else if generateThemes {
            do {
                let result = try await classifier.classifyThemes(creatorName: channelName, videos: inputs)
                await persistThemes(result, channelId: channelId, channelName: channelName)
            } catch {
                AppLogger.app.error("Theme classification failed for \(channelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else if generateAbout {
            do {
                let summary = try await classifier.generateAbout(creatorName: channelName, videos: inputs)
                await persistAbout(summary, channelId: channelId, channelName: channelName, inputCount: inputs.count)
            } catch {
                AppLogger.app.error("About generation failed for \(channelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persistThemes(_ result: CreatorThemeClassifier.ClassificationResult?, channelId: String, channelName: String) async {
        guard let result else { return }
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
        do {
            try store.replaceCreatorThemes(channelId: channelId, themes: records)
            AppLogger.app.info("Cached \(records.count, privacy: .public) themes for \(channelName, privacy: .public)")
        } catch {
            AppLogger.app.error("Failed to persist themes for \(channelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistAbout(_ summary: String?, channelId: String, channelName: String, inputCount: Int) async {
        guard let summary, !summary.isEmpty else { return }
        let record = CreatorAboutRecord(
            channelId: channelId,
            summary: summary,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            sourceVideoCount: inputCount
        )
        do {
            try store.upsertCreatorAbout(record)
            AppLogger.app.info("Cached about paragraph for \(channelName, privacy: .public) (\(summary.count, privacy: .public) chars)")
        } catch {
            AppLogger.app.error("Failed to persist about for \(channelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
