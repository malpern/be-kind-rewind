import Charts
import SwiftUI
import TaggingKit

/// Phase 1 creator detail page. Built incrementally across commits #6-#12 in the plan;
/// this file currently renders the identity card and the What's new section. Later
/// commits add Essentials, All Videos, In your playlists, Niches & cadence, and
/// Channel information sections.
///
/// The page consumes a `CreatorPageViewModel` rebuilt on every channelId change. The
/// `OrganizerStore` is `@Bindable` so future toolbar actions (Pin/Exclude/YouTube) and
/// favorite-state changes can mutate it directly.
struct CreatorDetailView: View {
    @Bindable var store: OrganizerStore
    let channelId: String
    let thumbnailCache: ThumbnailCache

    @State private var page: CreatorPageViewModel = .placeholderEmpty
    @State private var allVideosSort: [KeyPathComparator<CreatorVideoCard>] = [
        KeyPathComparator(\CreatorVideoCard.ageDays, order: .forward)
    ]
    @State private var allVideosSelection: CreatorVideoCard.ID?
    /// View-mode preference is sticky across navigations and app launches via UserDefaults.
    /// Default is `.byTheme` so videos are grouped by their LLM theme cluster — gives
    /// the most useful initial view when themes are populated, and falls back to a
    /// flat grid for creators whose themes haven't been classified yet.
    @AppStorage("creatorAllVideosViewMode") private var allVideosViewMode: AllVideosViewMode = .byTheme

    // Hits used to have a sort toggle (All time / Recent) but having two
    // perspectives in one section was overkill — they're nearly identical for
    // most creators. Now it's a single view ranked by all-time outlier score.

    /// Leaderboard topic scope. Defaults to the page creator's primary topic but the
    /// user can flip the menu to look at any other topic the creator publishes in.
    /// Resets on navigation away (per page, not sticky across creators).
    @State private var leaderboardScopeTopicId: Int64?

    /// Leaderboard ranking metric. Sticky across navigations + app launches via
    /// @AppStorage. The plan specifies three options ranking by what the user has
    /// actually saved or the videos' performance — never by global subscriber count.
    @AppStorage("creatorLeaderboardMetric") private var leaderboardMetric: LeaderboardMetric = .savedCount

    enum LeaderboardMetric: String, CaseIterable, Identifiable {
        case savedCount
        case outlierCount
        case totalViews

        var id: String { rawValue }

        var label: String {
            switch self {
            case .savedCount: return "Saved"
            case .outlierCount: return "Outliers"
            case .totalViews: return "Views"
            }
        }

        var symbolName: String {
            switch self {
            case .savedCount: return "tray.full"
            case .outlierCount: return "arrow.up.right"
            case .totalViews: return "eye"
            }
        }
    }

    /// Per-creator search query. Local to the page, resets on navigation away. Filters
    /// the All Videos table/grid by case-insensitive title substring. Distinct from the
    /// main app search (which spans the whole library) — this only narrows the videos
    /// already shown for this one creator.
    @State private var creatorSearchText: String = ""

    /// Currently-selected theme capsule, if any. Filters the All Videos list to videos
    /// in the matching cluster's `videoIds`. nil means no theme filter is active.
    /// Local to the page, resets on navigation away.
    @State private var selectedThemeLabel: String? = nil

    /// Local edit buffer for the per-creator notes field. Mirrors the persisted
    /// notes from the favorite_channels row; commits on blur via .onChange below.
    @State private var notesDraft: String = ""
    @FocusState private var notesFocused: Bool

    /// Environment hook for opening the standard macOS Settings scene from in-app
    /// affordances (e.g., the "Manage excluded creators" link in the identity menu).
    @Environment(\.openSettings) private var openSettings

    /// Phase 3 perf: cached snapshot of `ClaudeClient.hasStoredAPIKey()` so the
    /// themesEmptyStateRow doesn't hit the keychain on every SwiftUI re-render.
    /// Refreshed once per channel switch via the .task(id: channelId) below.
    /// Keychain queries cost ~50-200ms each on the main thread — calling them
    /// from a view body slows the page noticeably.
    @State private var hasClaudeKeyCached: Bool = false

    /// Section anchor the body should scroll to next. Set by interactions
    /// elsewhere on the page (e.g. clicking a theme capsule scrolls to All
    /// Videos with that tag filtered). The body's ScrollViewReader observes
    /// this via .onChange and clears the flag after performing the scroll.
    @State private var pendingScrollAnchor: SectionAnchor?

    /// True when the user has clicked the "+N more" pill in the themes
    /// column to reveal the long-tail themes alongside the head/middle.
    /// Resets per channel switch so each creator's view starts collapsed.
    @State private var themesExpanded: Bool = false

    // MARK: - Skeleton loading

    /// Phase 3: any background load that mutates the page model is in flight.
    /// Driven by the auto-archive load and theme classification — both of
    /// which can complete on the order of seconds and would otherwise cause
    /// visible layout shifts as content slots in. The skeleton helpers below
    /// gate on these to render placeholder content with the same dimensions
    /// as the eventual real content.
    private var isLoadingArchive: Bool {
        store.loadingFullHistoryChannels.contains(channelId)
    }

    /// True while any of the loading paths that affect page content are still
    /// running. The flag is the OR of every async producer the page depends on.
    private var isHydrating: Bool {
        isLoadingArchive || page.isClassifyingThemes
    }

    /// Sort order for the All Videos grid view. Mirrors the main grid's
    /// sectioned sort menu — one row per dimension, fixed direction
    /// (newest first / most views / longest, etc.). The high/low pairs
    /// from the previous version were collapsed.
    ///
    /// Default is `.byTheme` — the theme-grouped layout with section
    /// headers per LLM-cluster. "Clear Sort" returns to this default.
    @AppStorage("creatorAllVideosGridSort") private var allVideosGridSort: AllVideosGridSort = .byTheme

    enum AllVideosGridSort: String, CaseIterable, Identifiable {
        // RawValues are kept stable across the rename so users with prior
        // @AppStorage values auto-migrate. The old "high/low" pairs collapse
        // to whichever direction is the natural default for that dimension
        // (Date → newest first, Views → most viewed, Duration → longest).
        // Users who had `dateOldest`, `viewsLow`, or `durationShort` saved
        // will fall through to the @AppStorage default (.byTheme).
        case byTheme = "byTopic"
        case date = "dateNewest"
        case views = "viewsHigh"
        case duration = "durationLong"
        case alphabetical
        case outlierScore

        var id: String { rawValue }

        var label: String {
            switch self {
            case .byTheme: return "By theme"
            case .date: return "Date"
            case .views: return "Views"
            case .duration: return "Length"
            case .alphabetical: return "A-Z"
            case .outlierScore: return "Top outliers"
            }
        }

        var symbolName: String {
            switch self {
            case .byTheme: return "rectangle.3.group"
            case .date: return "calendar"
            case .views: return "chart.bar.fill"
            case .duration: return "timer"
            case .alphabetical: return "textformat.abc"
            case .outlierScore: return "arrow.up.right"
            }
        }
    }

    enum AllVideosViewMode: String, CaseIterable, Identifiable {
        case byTheme
        case grid
        case table

        var id: String { rawValue }
        var label: String {
            switch self {
            case .byTheme: return "By Theme"
            case .grid: return "Grid"
            case .table: return "Table"
            }
        }
        var symbolName: String {
            switch self {
            case .byTheme: return "rectangle.3.group"
            case .grid: return "square.grid.2x2"
            case .table: return "tablecells"
            }
        }
    }

    /// Section anchors for ⌘1–⌘8 jump shortcuts. The order matches the visual order
    /// of sections in the page body and the keyboard shortcuts in `sectionShortcuts`.
    enum SectionAnchor: Hashable {
        case identity, whatsNew, hits, allVideos, playlists, notes, leaderboard, channelInfo
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    identityCard.id(SectionAnchor.identity)
                    whatsNewSection.id(SectionAnchor.whatsNew)
                    hitsSection.id(SectionAnchor.hits)
                    allVideosSection.id(SectionAnchor.allVideos)
                    playlistsSection.id(SectionAnchor.playlists)
                    leaderboardSection.id(SectionAnchor.leaderboard)
                    notesSection.id(SectionAnchor.notes)
                    channelInformationSection.id(SectionAnchor.channelInfo)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(sectionShortcuts(scroller: scroller))
            // Theme capsule click → set pendingScrollAnchor → this onChange
            // performs the scroll inside the ScrollViewReader's closure where
            // the proxy is in scope. Cleared after firing so re-clicking the
            // same anchor still scrolls.
            .onChange(of: pendingScrollAnchor) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    scroller.scrollTo(new, anchor: .top)
                }
                pendingScrollAnchor = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        // Deliberately no navigationTitle / navigationSubtitle / toolbar action items
        // here. The page body owns the title via the largeTitle in the identity card,
        // and the action buttons live inline in the header next to the avatar
        // (Apple Music artist hero pattern). Mac App Store does the same thing with
        // its "Get" button — actions adjacent to the entity, not in the toolbar.
        .task(id: channelId) {
            page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
            notesDraft = page.notes ?? ""
            themesExpanded = false
            // Phase 3 perf: refresh the cached keychain check once per page open.
            // The themesEmptyStateRow used to call ClaudeClient.hasStoredAPIKey()
            // directly from its view body, which fired a keychain query on every
            // SwiftUI redraw. Now it reads from `hasClaudeKeyCached` which only
            // updates when the user navigates to a different creator.
            hasClaudeKeyCached = ClaudeClient.hasStoredAPIKey()
            // Phase 3: stamp last_visited_at AFTER the page model has been built
            // (the builder reads the previous timestamp to compute "new since
            // last visit"). Bumping it before the build would always yield 0.
            store.markCreatorVisited(channelId: channelId)
            // Phase 3: auto-trigger an archive scrape on first visit when the
            // creator has zero archive entries. The Watch refresh pipeline only
            // populates archives for channels in active candidate discovery, so
            // any creator outside that path stays empty until manually loaded.
            // We only fire when there's been NO previous load attempt this
            // session (loadingFullHistoryChannels and lastFullHistoryLoadCount
            // are both empty for this channelId) so navigating back to the
            // page doesn't re-scrape.
            if page.lastRefreshedAt == nil
                && page.savedVideoCount > 0
                && !store.loadingFullHistoryChannels.contains(channelId)
                && store.lastFullHistoryLoadCount[channelId] == nil
                && store.lastFullHistoryLoadError[channelId] == nil {
                AppLogger.file.log("Auto-loading archive for empty-archive creator \(channelId)", category: "discovery")
                store.loadFullChannelHistory(
                    channelId: channelId,
                    channelName: page.channelName
                )
            }

            // Phase 3: auto-scrape channel links on first visit. Cheap, gated
            // by ScrapeRateLimiter and the cached-row check inside the loader.
            store.loadChannelLinksIfNeeded(channelId: channelId)

            // Phase 3: also opportunistically check whether themes/about
            // need (re)generation. The function checks both caches
            // independently and bails out early if both are fresh — so
            // creators with cached archives but pre-existing classification
            // won't re-run the LLM. This handles the case where a creator
            // was visited before theme classification was added: the
            // archive is on disk but themes have never been generated.
            store.classifyCreatorThemesIfNeeded(channelId: channelId, channelName: page.channelName)

            // Offline-first thumbnails: prefetch every video shown on this
            // page into the on-disk thumbnail cache. Without this, only the
            // saved videos for the user's currently-selected topic ever get
            // cached — so opening a creator page while offline used to
            // leave most rows blank. Union the four sources visible on the
            // page: allVideos (master list for table/grid/byTheme/byTopic),
            // theirHits, recentVideos, essentials. Prefetch is a no-op for
            // already-cached IDs so this is cheap on revisits.
            Task.detached { [thumbnailCache, page] in
                var ids = Set<String>()
                for card in page.allVideos { ids.insert(card.videoId) }
                for card in page.theirHits { ids.insert(card.videoId) }
                for card in page.recentVideos { ids.insert(card.videoId) }
                for card in page.essentials { ids.insert(card.videoId) }
                let videoIds = Array(ids)
                guard !videoIds.isEmpty else { return }
                await thumbnailCache.prefetch(videoIds: videoIds)
            }
            // Reset leaderboard scope to the page creator's primary topic on every
            // navigation. The user can flip the picker to look at other topics, but
            // navigating to a new creator should always start at THEIR primary topic.
            leaderboardScopeTopicId = page.leaderboardDefaultTopicId

            // Kick off Claude theme classification + about generation in the background
            // if the toggle is on and the cache is empty. The store inserts this channel
            // into classifyingThemeChannels, which we observe below to rebuild the page
            // when classification finishes.
            store.classifyCreatorThemesIfNeeded(channelId: channelId, channelName: page.channelName)
        }
        .onChange(of: notesFocused) { wasFocused, isFocused in
            // Commit on blur — when focus leaves the notes editor, persist the draft.
            // Editing while focused stays purely local until the user clicks elsewhere.
            if wasFocused && !isFocused {
                let trimmed = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let persisted = page.notes ?? ""
                if trimmed != persisted {
                    store.setNotesForCreator(
                        channelId: channelId,
                        channelName: page.channelName,
                        iconUrl: page.avatarUrl?.absoluteString,
                        notes: trimmed.isEmpty ? nil : trimmed
                    )
                }
            }
        }
        .onChange(of: store.favoriteCreators.map(\.channelId)) { _, _ in
            // Reflect Pin/Unpin and Exclude/Restore actions immediately in the page model.
            page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
        }
        .onChange(of: store.excludedCreators.map(\.channelId)) { _, _ in
            page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
        }
        .onChange(of: store.channelLinksVersion) { _, _ in
            // A channel-link scrape just completed for *some* creator. Cheap
            // to rebuild — the page builder is sub-100ms.
            page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
        }
        .onChange(of: store.classifyingThemeChannels.contains(channelId)) { wasClassifying, isClassifying in
            // When classification finishes (true → false), rebuild the page so the
            // newly-cached themes and about paragraph appear.
            if wasClassifying && !isClassifying {
                page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
                // Auto-switch to theme grouping now that themes are available.
                // Before classification, All Videos was showing a flat
                // chronological grid (byTheme falls through to allVideosGrid
                // when themes are empty). Now that themes exist, switch the
                // sort to .byTheme so the grouped view appears without
                // requiring the user to manually flip the sort menu.
                if !page.themes.isEmpty {
                    allVideosGridSort = .byTheme
                }
            } else if !wasClassifying && isClassifying {
                // Rebuild once at the start so the loading indicator appears.
                page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
            }
        }
    }

    // MARK: - Section jump shortcuts (⌘1–⌘0)

    /// Hidden button stack hosting ⌘1–⌘0 keyboard shortcuts. Each button scrolls
    /// the page to its anchor via the `ScrollViewReader` proxy. We place this in
    /// the ScrollView's `.background` so the buttons are non-interactive visually
    /// but still respond to the key equivalents while the detail view has focus.
    /// Tenth section (notes) gets ⌘0, matching macOS tab/window picker convention.
    @ViewBuilder
    private func sectionShortcuts(scroller: ScrollViewProxy) -> some View {
        let bindings: [(String, SectionAnchor)] = [
            ("1", .identity),
            ("2", .whatsNew),
            ("3", .hits),
            ("4", .allVideos),
            ("5", .playlists),
            ("6", .leaderboard),
            ("7", .notes),
            ("8", .channelInfo),
        ]
        ZStack {
            ForEach(bindings, id: \.1) { key, anchor in
                Button("Jump to section") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scroller.scrollTo(anchor, anchor: .top)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Identity card

    /// App Store / Apple Podcasts pattern: square (rounded-corner) icon on
    /// the left, info stack in the middle, themes capsules in a 320pt
    /// right column. No card chrome — sits flush with the page. The
    /// rounded-square avatar treatment deliberately departs from YouTube's
    /// circular convention so the page reads as a native macOS detail page
    /// rather than a YouTube-flavored widget.
    @ViewBuilder
    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                avatar
                    .frame(width: 160, height: 160)
                    .help(avatarTooltip)

                // Middle column: name, subtitle, about, stat tiles, actions, links.
                VStack(alignment: .leading, spacing: 8) {
                    Text(page.channelName)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let subtitle = page.subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if let about = page.aboutParagraph {
                        Text(about)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    }

                    statsTileRow
                    headerActionButtons
                        .padding(.top, 8)
                    if !page.channelLinks.isEmpty {
                        channelLinksRow
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                // Right column: themes capsules. Width tuned to fit ~2
                // capsules per row in the FlowLayout for typical labels
                // (1-3 words, max 24 chars per the prompt rules).
                themesIdentityColumn
                    .frame(width: 320, alignment: .topLeading)
            }
            .contentShape(Rectangle())
            .contextMenu {
                identityContextMenuItems
            }

            Divider()
        }
    }

    /// Themes column rendered inline in the identity card. Hosts the same
    /// content the standalone `themeCapsulesSection` used to render — the
    /// FlowLayout-wrapped capsules, the staleness badge, the refresh button,
    /// the classifying spinner, and the empty-state row — but laid out for a
    /// fixed-width right column instead of a full-width section.
    @ViewBuilder
    private var themesIdentityColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Spacer(minLength: 0)
                if selectedThemeLabel != nil {
                    Button {
                        selectedThemeLabel = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .help("Clear theme filter")
                }
                if !page.themes.isEmpty {
                    Button {
                        store.classifyCreatorThemesIfNeeded(
                            channelId: channelId,
                            channelName: page.channelName,
                            force: true
                        )
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .help("Re-run theme classification with the latest video list")
                    .disabled(page.isClassifyingThemes)
                }
            }

            if !page.themes.isEmpty {
                if let cachedCount = page.themes.first?.classifiedVideoCount,
                   cachedCount > 0,
                   page.totalUploadsKnown > cachedCount {
                    Text("\(page.totalUploadsKnown - cachedCount) new since last classification")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                themesTagList
            } else if page.isClassifyingThemes || isLoadingArchive {
                // Skeleton: 6 redacted capsules with the same vertical rhythm
                // as real themes. Replaces the inline progress row that used
                // to shrink the column. Reserves enough height that the
                // identity card doesn't grow when real themes arrive.
                themesSkeletonRows
            } else {
                themesEmptyStateRow
            }
        }
    }

    // MARK: - Themes radial chart

    /// Curated palette for the themes donut chart. Eight stops cycling through
    /// macOS-friendly hues with similar saturation/value so adjacent slices
    /// stay distinguishable in both light and dark mode. Major themes get
    /// indices 0..7 from this palette; the "Other" slice always uses .gray.
    private var themePalette: [Color] {
        [
            Color(red: 0.40, green: 0.60, blue: 0.95),  // blue
            Color(red: 0.95, green: 0.55, blue: 0.40),  // orange
            Color(red: 0.55, green: 0.80, blue: 0.55),  // green
            Color(red: 0.80, green: 0.50, blue: 0.85),  // pink
            Color(red: 0.95, green: 0.78, blue: 0.40),  // gold
            Color(red: 0.50, green: 0.78, blue: 0.85),  // teal
            Color(red: 0.85, green: 0.45, blue: 0.55),  // crimson
            Color(red: 0.65, green: 0.55, blue: 0.85),  // violet
        ]
    }

    /// Wraps a single chart slice — either a real theme or the catch-all
    /// "Other" bucket. Sized by `videoCount`, painted by `color`. Used by
    /// both the donut chart and the legend list so they stay in sync.
    struct ThemeChartSlice: Identifiable, Equatable {
        let id: String          // theme label, or "__other__" for the bucket
        let label: String
        let videoCount: Int
        let color: Color
        let themeRecord: CreatorThemeRecord?  // nil for the "Other" bucket
    }

    /// Compute the chart slices: top N themes with ≥3 videos each, capped at
    /// 8, plus an "Other" bucket aggregating the long tail. Both the radial
    /// chart and the by-theme grouping in All Videos consume this same
    /// derivation so the visual story is consistent.
    private var majorThemeSlices: [ThemeChartSlice] {
        let sorted = page.themes.sorted { $0.videoIds.count > $1.videoIds.count }
        let candidates = sorted.filter { $0.videoIds.count >= 3 }
        let majors = Array(candidates.prefix(8))
        let majorIds = Set(majors.map(\.label))
        let otherCount = page.themes
            .filter { !majorIds.contains($0.label) }
            .reduce(0) { $0 + $1.videoIds.count }

        var slices: [ThemeChartSlice] = majors.enumerated().map { index, theme in
            ThemeChartSlice(
                id: theme.label,
                label: theme.label,
                videoCount: theme.videoIds.count,
                color: themePalette[index % themePalette.count],
                themeRecord: theme
            )
        }
        if otherCount > 0 {
            slices.append(ThemeChartSlice(
                id: "__other__",
                label: "Other",
                videoCount: otherCount,
                color: Color.gray.opacity(0.5),
                themeRecord: nil
            ))
        }
        return slices
    }

    /// Themes column body: large clickable tag capsules in a wrapping flow.
    /// Replaces the radial donut chart that lived here in earlier iterations.
    /// Default-collapsed view shows the head + middle of the theme
    /// distribution (data-driven, not a fixed N) followed by a "+N more"
    /// pill that expands to reveal the long tail as individual tags.
    @ViewBuilder
    private var themesTagList: some View {
        let visible = themesPartition.visible
        let hidden = themesPartition.hidden
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(visible, id: \.label) { theme in
                themeLargeTag(theme)
            }
            if themesExpanded {
                ForEach(hidden, id: \.label) { theme in
                    themeLargeTag(theme)
                }
                if !hidden.isEmpty {
                    themesExpandPill(label: "Show fewer", systemImage: "minus.circle") {
                        withAnimation(.easeInOut(duration: 0.2)) { themesExpanded = false }
                    }
                }
            } else if !hidden.isEmpty {
                themesExpandPill(label: "+\(hidden.count) more", systemImage: "plus.circle") {
                    withAnimation(.easeInOut(duration: 0.2)) { themesExpanded = true }
                }
            }
        }
        .padding(.top, 4)
    }

    /// Split the themes into "visible" (head + middle of the distribution)
    /// and "hidden" (long tail) using an 80% Pareto cumulative-sum rule.
    ///
    /// - **Sort** by video count desc
    /// - **Cumulative sum** until ≥80% of total videos are covered
    /// - That's the visible set
    /// - Anything past that point is the long tail
    ///
    /// Two safety bounds:
    /// - **Floor 3**: always show at least 3 themes when available, even
    ///   when one theme dominates (otherwise a creator with 90% of videos
    ///   in one theme would show just that one tag — unhelpful)
    /// - **Ceiling 8**: never show more than 8 themes by default, even when
    ///   the distribution is unusually flat (avoid blowing out the column)
    private var themesPartition: (visible: [CreatorThemeRecord], hidden: [CreatorThemeRecord]) {
        let sorted = page.themes.sorted { $0.videoIds.count > $1.videoIds.count }
        guard sorted.count > 1 else { return (sorted, []) }

        let total = sorted.reduce(0) { $0 + $1.videoIds.count }
        guard total > 0 else { return (sorted, []) }
        let target = Double(total) * 0.80

        var cumulative = 0
        var visibleCount = 0
        for theme in sorted {
            cumulative += theme.videoIds.count
            visibleCount += 1
            if Double(cumulative) >= target { break }
        }

        let floor = min(3, sorted.count)
        let ceiling = 8
        let bounded = max(floor, min(visibleCount, ceiling))
        let visible = Array(sorted.prefix(bounded))
        let hidden = Array(sorted.dropFirst(bounded))
        return (visible, hidden)
    }

    /// Large tag capsule for a single theme. Body-weight semibold text,
    /// generous padding, accent fill when selected. Click toggles the
    /// All Videos theme filter and scrolls to it.
    @ViewBuilder
    private func themeLargeTag(_ theme: CreatorThemeRecord) -> some View {
        let isSelected = selectedThemeLabel == theme.label
        Button {
            if isSelected {
                selectedThemeLabel = nil
            } else {
                selectedThemeLabel = theme.label
                pendingScrollAnchor = .allVideos
            }
        } label: {
            HStack(spacing: 6) {
                if theme.isSeries {
                    Image(systemName: "list.number")
                        .font(.subheadline.weight(.semibold))
                }
                Text(theme.label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(theme.videoIds.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 0 : 0.35), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(theme.description ?? theme.label)
    }

    /// "+N more" / "Show fewer" pill button styled as a control rather than
    /// a real theme tag. Same height as `themeLargeTag` so the row reads
    /// as a coherent strip, but uses neutral colors so it doesn't look
    /// like a theme.
    @ViewBuilder
    private func themesExpandPill(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.body.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(.secondary)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Toggle the long-tail themes")
    }

    /// Skeleton placeholder for the themes column. Mirrors the new tag-list
    /// loaded state — a wrapping FlowLayout of stub tag capsules at the
    /// same dimensions as the real `themeLargeTag`, so the identity card
    /// row's height stays stable when the real tags slot in.
    @ViewBuilder
    private var themesSkeletonRows: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(0..<6, id: \.self) { i in
                let stub = i.isMultiple(of: 3) ? "Loading tag" : (i.isMultiple(of: 2) ? "Theme" : "Topic name")
                HStack(spacing: 6) {
                    Text(stub)
                        .font(.body.weight(.semibold))
                    Text("00")
                        .font(.subheadline.monospacedDigit())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                )
            }
        }
        .padding(.top, 4)
        .redacted(reason: .placeholder)
    }

    /// Phase 3: external link buttons row. Renders the channel's scraped
    /// social/professional URLs as a wrapped row of small bordered buttons —
    /// each labeled with a friendly platform name (GitHub, Twitter/X, etc.)
    /// and a matching SF Symbol. Click opens the URL in the user's default
    /// browser. Wraps to multiple rows when there are too many to fit, so
    /// creators with a long social presence don't blow up the layout.
    @ViewBuilder
    private var channelLinksRow: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(page.channelLinks, id: \.url) { link in
                channelLinkButton(link)
            }
        }
    }

    @ViewBuilder
    private func channelLinkButton(_ link: ChannelLink) -> some View {
        Link(destination: URL(string: link.url) ?? URL(string: "https://www.youtube.com")!) {
            Label(compactURLDisplay(link.url), systemImage: link.symbolName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(link.url)
    }

    /// Display-cleaned URL for the link button. Strips the scheme and `www.`
    /// prefix, drops a trailing slash, and truncates with a middle ellipsis
    /// when the result is wider than 32 chars so creators with long URLs
    /// don't blow out the row layout.
    ///
    /// Examples:
    ///   "https://github.com/benfrain" → "github.com/benfrain"
    ///   "https://www.benfrain.com/blog/2024/some-post-title" → "benfrain.com/blog/…/some-post-title"
    private func compactURLDisplay(_ raw: String) -> String {
        var url = raw
        if url.hasPrefix("https://") { url = String(url.dropFirst(8)) }
        else if url.hasPrefix("http://") { url = String(url.dropFirst(7)) }
        if url.hasPrefix("www.") { url = String(url.dropFirst(4)) }
        if url.hasSuffix("/") { url = String(url.dropLast()) }

        let maxLength = 32
        if url.count <= maxLength {
            return url
        }
        // Middle truncation: keep the host + first path segment + the tail.
        let head = url.prefix(maxLength / 2 - 1)
        let tail = url.suffix(maxLength / 2 - 2)
        return "\(head)…\(tail)"
    }

    /// App Store pattern: one primary CTA, one system action, one overflow.
    /// `[Open on YouTube]` `[Share]` `[···]`. Power actions (refresh themes,
    /// load more uploads, copy URL, exclude/restore, manage excluded) live
    /// in the overflow Menu so they're discoverable via a button instead of
    /// only via right-click on the avatar.
    @ViewBuilder
    private var headerActionButtons: some View {
        HStack(spacing: 8) {
            Link(destination: page.youtubeURL) {
                Label("Open on YouTube", systemImage: "arrow.up.right.square.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("Open this channel on YouTube")
            .accessibilityIdentifier("creatorHeaderYouTubeButton")

            ShareLink(item: page.youtubeURL, subject: Text(page.channelName)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Share this channel via the system share sheet")
            .accessibilityIdentifier("creatorHeaderShareButton")

            Menu {
                identityContextMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityIdentifier("creatorHeaderOverflowMenu")
            .accessibilityLabel("More actions")
        }
    }

    /// Rounded-square avatar (App Store icon style). Continuous corner radius gives
    /// the iOS/macOS app icon shape; the size + treatment combine to read as
    /// "this page is about this entity" rather than "thumbnail of a creator."
    ///
    /// We **prefer the high-resolution URL** (`page.avatarUrl` is upscaled at build
    /// time via `CreatorPageBuilder.upscaledAvatarURL`) over the cached `iconData`
    /// blob, because the cache stores whatever low-res version was downloaded for
    /// the small thumbnails elsewhere in the app — typically 88-240px. The page
    /// header at 160pt × 2x retina needs at least 320px to avoid looking soft.
    /// We fall back to the cached blob only when no URL is available.
    ///
    /// Offline-first ordering: when we already have an `avatarData` blob and
    /// the user is potentially offline, we render the blob *immediately*
    /// instead of flashing through `AsyncImage`'s `.empty` → `.failure`
    /// transition. The high-res network upgrade only kicks in when there's
    /// no blob yet (first visit to a creator on a fresh install). This
    /// trades a slightly soft avatar on revisits-while-online for a flicker-
    /// free fully-offline UX, which matches the rest of the app.
    @ViewBuilder
    private var avatar: some View {
        Group {
            if page.avatarData != nil {
                avatarLowResOrFallback
            } else if let url = page.avatarUrl {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        avatarLowResOrFallback
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        avatarLowResOrFallback
                    @unknown default:
                        avatarLowResOrFallback
                    }
                }
            } else {
                avatarLowResOrFallback
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
    }

    /// Shown while the high-res URL is loading or after it fails. Falls back to the
    /// cached low-res icon data if we have it (better than a blank box), and to a
    /// generic SF Symbol if we don't.
    @ViewBuilder
    private var avatarLowResOrFallback: some View {
        if let data = page.avatarData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.tertiary)
                Image(systemName: "person.crop.square.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Three stat tiles in the identity card. Replaces the old comma-soup
    /// `tierLine` + `statsLine` (which crammed 6+ metrics into two text
    /// rows separated by " · "). Apple Health / App Store / Apple Music
    /// all use this pattern: a small row of `BIG NUMBER` over `tiny label`
    /// stat tiles. Three is the magic number — fewer feels sparse, more
    /// dilutes the focal points.
    ///
    /// Tiles: Saved · Subscribers · Last upload. Tier / founding year /
    /// country are deliberately *not* tiles — they live in the avatar
    /// `.help()` tooltip and the identity context menu, where they belong
    /// as low-priority metadata.
    @ViewBuilder
    private var statsTileRow: some View {
        HStack(spacing: 24) {
            statTile(
                value: "\(page.savedVideoCount)",
                label: "Saved"
            )

            if let subs = page.subscriberCountFormatted {
                statTile(
                    value: subs,
                    label: "Subscribers"
                )
            }

            if let lastUpload = page.lastUploadAge {
                statTile(
                    value: lastUpload,
                    label: "Last upload"
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Tooltip surfaced on the avatar — hosts the metadata that used to
    /// live in `tierLine`. The user gets it on hover without taking page
    /// real estate.
    private var avatarTooltip: String {
        var parts: [String] = [page.channelName]
        if let tier = page.creatorTier {
            parts.append(tier)
        }
        if let founding = page.foundingYear {
            parts.append("since \(founding)")
        }
        if let country = page.countryDisplayName {
            parts.append(country)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - What's new / Recent uploads

    @ViewBuilder
    private var whatsNewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            emptyArchiveBanner
            sinceLastVisitBanner
            if !page.recentVideos.isEmpty {
                // Multiple videos in the last 14 days → grid layout, "Recent uploads" header.
                HStack(alignment: .firstTextBaseline) {
                    if page.recentVideos.count == 1 {
                        Text("What's new")
                            .font(.title3.weight(.semibold))
                    } else {
                        Text("Recent uploads")
                            .font(.title3.weight(.semibold))
                        Text("last 14 days")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if page.recentVideosTotalInWindow > page.recentVideos.count {
                        Text("+ \(page.recentVideosTotalInWindow - page.recentVideos.count) more")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if page.recentVideos.count == 1 {
                    // Single video — keep the wide tap-target row treatment with the
                    // play.circle.fill overlay (more visual presence than a single grid card).
                    whatsNewRow(page.recentVideos[0])
                } else {
                    // 2-5 videos — same VideoGridItem cards as the All Videos grid view,
                    // so the visual treatment matches the rest of the app.
                    recentUploadsGrid
                }
            } else if let latest = page.latestVideo {
                // Window was empty (creator hasn't posted in the last 14 days), but we
                // still want to surface their most recent upload as a fallback.
                Text("What's new")
                    .font(.title3.weight(.semibold))
                whatsNewRow(latest)
            } else if isLoadingArchive {
                // No videos yet AND a load is in progress — render a skeleton
                // row at the same dimensions as `whatsNewRow` so the page
                // doesn't shift when real data arrives.
                Text("What's new")
                    .font(.title3.weight(.semibold))
                whatsNewRowSkeleton
            }
        }
    }

    /// Skeleton placeholder matching `whatsNewRow` dimensions exactly so the
    /// page layout doesn't shift when real data arrives.
    @ViewBuilder
    private var whatsNewRowSkeleton: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 160, height: 90)
            VStack(alignment: .leading, spacing: 6) {
                Text("Loading recent upload title placeholder")
                    .font(.body.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                Text("00 views · 0d ago")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .redacted(reason: .placeholder)
    }

    /// Banner shown only when a previous archive load attempt failed. The
    /// happy-path "we're loading" state is now an inline `ProgressView` next
    /// to the What's new header — the auto-load fires from `.task(id:)` so
    /// the user doesn't need to ask for it explicitly.
    ///
    /// Keeping a hero card for the success-path empty state read as
    /// "this page is broken/unfinished" because it appeared on every fresh
    /// visit before the auto-load completed (~2-10s). Now the only time the
    /// loud orange banner shows up is when something genuinely went wrong.
    @ViewBuilder
    private var emptyArchiveBanner: some View {
        let errorMessage = store.lastFullHistoryLoadError[channelId]
        let isLoading = store.loadingFullHistoryChannels.contains(channelId)
        if let errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't load this creator's recent uploads")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    store.loadFullChannelHistory(
                        channelId: channelId,
                        channelName: page.channelName
                    )
                } label: {
                    if isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                        }
                    } else {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isLoading)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
            )
            // When the load completes (count appears, even if 0), force a
            // page rebuild so the new archive videos flow into allVideos and
            // monthlyCounts immediately. Also kicks off theme classification
            // now that the archive is populated — themes are gated on the
            // archive being loaded so they classify against the full catalog
            // instead of just the user's saved videos.
            .onChange(of: store.lastFullHistoryLoadCount[channelId]) { _, newCount in
                guard newCount != nil, !store.loadingFullHistoryChannels.contains(channelId) else { return }
                page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
                store.classifyCreatorThemesIfNeeded(
                    channelId: channelId,
                    channelName: page.channelName
                )
            }
        }
    }

    /// Phase 3: small "N new since your last visit · X days ago" banner shown
    /// above the What's new section when the user has previously visited this
    /// favorited creator and there are uploads after that timestamp. Hidden on
    /// first visits, for non-favorited creators, and when nothing is new.
    @ViewBuilder
    private var sinceLastVisitBanner: some View {
        if page.newSinceLastVisitCount > 0, let prevDate = page.previousVisitDate {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("\(page.newSinceLastVisitCount) new since your last visit")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("·")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text(relativeVisitDate(prevDate))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    private func relativeVisitDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "last visited \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    @ViewBuilder
    private var recentUploadsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 12)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(page.recentVideos) { card in
                Link(destination: card.youtubeUrl ?? URL(string: "https://www.youtube.com")!) {
                    VideoGridItem(
                        video: gridModel(for: card),
                        isSelected: false,
                        isHovering: false,
                        cacheDir: thumbnailCache.cacheDirURL,
                        showMetadata: true,
                        size: 200,
                        highlightTerms: [],
                        forceShowTitle: false
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    videoContextMenuItems(for: [card])
                }
            }
        }
    }

    private func whatsNewRow(_ card: CreatorVideoCard) -> some View {
        Link(destination: card.youtubeUrl ?? URL(string: "https://www.youtube.com")!) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    thumbnail(for: card)
                        .frame(width: 160, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    // Visual play affordance — the wrapping Link handles the actual click,
                    // so this is just an iconographic hint that the row is playable.
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white, .black.opacity(0.5))
                        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    metadataLine(for: card)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Open this video on YouTube")
        .contextMenu {
            videoContextMenuItems(for: [card])
        }
    }

    @ViewBuilder
    private func thumbnail(for card: CreatorVideoCard) -> some View {
        // Routes through ThumbnailView so we hit the on-disk cache first
        // (~/Library/Caches/VideoOrganizer/thumbnails/{videoId}.jpg) and
        // only fall back to AsyncImage when the file isn't there. Critical
        // for offline use — without this, every Hits/What's-New row went
        // straight to i.ytimg.com on every render.
        ThumbnailView(
            videoId: card.videoId,
            thumbnailUrl: card.thumbnailUrl,
            cacheDir: thumbnailCache.cacheDirURL
        )
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "photo")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
    }

    private func metadataLine(for card: CreatorVideoCard) -> some View {
        let pieces: [String] = [
            card.ageFormatted,
            card.viewCountParsed > 0 ? card.viewCountFormatted : nil,
            card.runtimeFormatted
        ].compactMap { $0 }
        return Text(pieces.joined(separator: " · "))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: - Hits (merged outlier shelf, sortable by All time vs Recent)

    /// Single outlier shelf — the creator's best work, ranked by all-time
    /// outlier score (videos punching above their channel median). No toggle,
    /// no perspective picker. Recency weighting was its own view in an earlier
    /// version but the two perspectives were nearly identical for most
    /// creators and the picker was visual noise.
    @ViewBuilder
    private var hitsSection: some View {
        let cards = page.theirHits.filter { $0.outlierScore >= 1.5 }
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Hits")
                        .font(.title3.weight(.semibold))
                    Text(hitsHelpText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(180))], spacing: 14) {
                        ForEach(cards) { card in
                            essentialsCard(card)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else if isLoadingArchive {
            // Skeleton: render the section header + a row of placeholder cards
            // at the same dimensions as essentialsCard so the page doesn't
            // shift when archive load completes and real outliers slot in.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Hits")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(180))], spacing: 14) {
                        ForEach(0..<5, id: \.self) { _ in
                            essentialsCardSkeleton
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Skeleton placeholder matching `essentialsCard` dimensions (200×112
    /// thumbnail, 2-line title with `reservesSpace: true`, 1-line metadata).
    @ViewBuilder
    private var essentialsCardSkeleton: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .frame(width: 200, height: 112)
            Text("Placeholder loading title for outlier card")
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .frame(width: 200, alignment: .topLeading)
            Text("000K views")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
        }
        .redacted(reason: .placeholder)
    }

    private var hitsHelpText: String {
        guard page.channelMedianViews > 0 else {
            return "ranked by views"
        }
        return "ranked by outlier score · median ≈ \(formatCompact(page.channelMedianViews)) views"
    }

    private func essentialsCard(_ card: CreatorVideoCard) -> some View {
        Link(destination: card.youtubeUrl ?? URL(string: "https://www.youtube.com")!) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    thumbnail(for: card)
                        .frame(width: 200, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if card.isOutlier {
                        outlierBadge(card)
                            .padding(6)
                    }
                }

                // Always reserve 2 lines of vertical space for the title so cards
                // with short titles align with cards that have wrapped titles. The
                // .lineLimit(_:reservesSpace:) variant is the modern SwiftUI way to
                // pad to a fixed line count.
                Text(card.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(width: 200, alignment: .topLeading)

                // Always render the metadata line so the bottom edge of every card
                // sits at the same baseline. Use an em-dash placeholder when view
                // count is unknown so the row never collapses to zero height.
                Text(card.viewCountParsed > 0 ? card.viewCountFormatted : "—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(card.viewCountParsed > 0 ? .secondary : .tertiary)
                    .frame(width: 200, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help(essentialsCardTooltip(card))
        .contextMenu {
            videoContextMenuItems(for: [card])
        }
    }

    private func outlierBadge(_ card: CreatorVideoCard) -> some View {
        let multiplier = card.outlierScore
        let label = multiplier >= 10
            ? String(format: "%.0f×", multiplier)
            : String(format: "%.1f×", multiplier)
        return HStack(spacing: 4) {
            Image(systemName: "arrow.up")
            Text(label)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
        .foregroundStyle(.primary)
        .accessibilityLabel("Outlier: \(label) the channel median")
    }

    private func essentialsCardTooltip(_ card: CreatorVideoCard) -> String {
        var parts: [String] = [card.title]
        if card.viewCountParsed > 0 {
            parts.append(card.viewCountFormatted)
        }
        if let age = card.ageFormatted {
            parts.append(age)
        }
        if card.isOutlier && page.channelMedianViews > 0 {
            let multiplier = String(format: "%.1f×", card.outlierScore)
            let actual = formatCompact(card.viewCountParsed)
            let median = formatCompact(page.channelMedianViews)
            parts.append("\(multiplier) channel median (\(actual) vs \(median) median)")
        }
        return parts.joined(separator: " · ")
    }

    private func formatCompact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    // (Phase 3 "Their hits" section was merged into hitsSection above with a
    // sortable [All time | Recent] picker. Both perspectives still live in the
    // page model — page.theirHits and page.essentials — so the toggle is instant.)

    // MARK: - Theme capsules (LLM-driven)
    //
    // The standalone themeCapsulesSection was folded into the identity card's
    // right column (`themesIdentityColumn`). The empty-state row, capsule
    // helper, and refresh logic still live below — they're consumed by the
    // new identity column.

    /// Discoverability empty state for the themes section. Branches on three
    /// reasons the cache is empty: no Claude API key, classification disabled,
    /// or simply not generated yet. Each branch surfaces the right next-step CTA
    /// so the user is never left staring at a blank space.
    @ViewBuilder
    private var themesEmptyStateRow: some View {
        let hasKey = hasClaudeKeyCached
        HStack(spacing: 10) {
            Image(systemName: "tag")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if !hasKey {
                Text("Add a Claude API key to generate tags for this creator")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if !store.claudeThemeClassificationEnabled {
                Text("Theme classification is off. Enable it to tag this creator's videos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enable") {
                    store.claudeThemeClassificationEnabled = true
                    store.classifyCreatorThemesIfNeeded(channelId: channelId, channelName: page.channelName)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if page.lastRefreshedAt == nil {
                // Archive empty AND no tags. Combined CTA — load full history
                // first, then theme classification fires automatically when
                // the load completes (see the .onChange in emptyArchiveBanner).
                Text("Load this creator's uploads to generate tags")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.loadFullChannelHistory(
                        channelId: channelId,
                        channelName: page.channelName
                    )
                } label: {
                    Label("Load uploads & generate tags", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.loadingFullHistoryChannels.contains(channelId))
            } else {
                Text("No tags generated yet for this creator")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.classifyCreatorThemesIfNeeded(
                        channelId: channelId,
                        channelName: page.channelName,
                        force: true
                    )
                } label: {
                    Label("Generate tags", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    private func themeCapsule(_ theme: CreatorThemeRecord) -> some View {
        let isSelected = selectedThemeLabel == theme.label
        return Button {
            if isSelected {
                selectedThemeLabel = nil
            } else {
                selectedThemeLabel = theme.label
                // Jump to the All Videos section so the user can immediately
                // see the videos in this theme — the filter is already applied
                // by the selectedThemeLabel binding in `filteredAllVideos`.
                pendingScrollAnchor = .allVideos
            }
        } label: {
            HStack(spacing: 6) {
                if theme.isSeries {
                    Image(systemName: "list.number")
                        .font(.subheadline.weight(.semibold))
                }
                Text(theme.label)
                    .font(.callout.weight(.medium))
                Text("\(theme.videoIds.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 1.5 : 0.5)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(theme.description ?? theme.label)
    }

    // MARK: - All videos

    @ViewBuilder
    private var allVideosSection: some View {
        if !page.allVideos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("All videos")
                        .font(.title3.weight(.semibold))
                    Text(allVideosCountLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    creatorSearchField
                    if allVideosViewMode == .grid || allVideosViewMode == .byTheme {
                        allVideosGridSortMenu
                    }
                    // Menu picker (not segmented) — segmented Pickers crash
                    // during SwiftUI scroll prefetch on macOS 26 when the
                    // enum case count changes between releases. Menus don't
                    // have this issue and read just as cleanly for a
                    // 3-option toggle.
                    Menu {
                        ForEach(AllVideosViewMode.allCases) { mode in
                            Button {
                                allVideosViewMode = mode
                            } label: {
                                if allVideosViewMode == mode {
                                    Label(mode.label, systemImage: "checkmark")
                                } else {
                                    Label(mode.label, systemImage: mode.symbolName)
                                }
                            }
                        }
                    } label: {
                        Label(allVideosViewMode.label, systemImage: allVideosViewMode.symbolName)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Switch between By Theme, Grid, and Table views")
                }

                switch allVideosViewMode {
                case .table:
                    allVideosTable
                case .grid:
                    // Special-case the "by theme" sort: render the grid as
                    // theme-grouped section headers (same layout as the
                    // .byTheme view mode). Other sorts stay flat — they
                    // define ordering, not grouping. Saved videos inside
                    // the theme groups get a small badge in
                    // `allVideosGridCard`.
                    if allVideosGridSort == .byTheme {
                        allVideosByTheme
                    } else {
                        allVideosGrid
                    }
                case .byTheme:
                    allVideosByTheme
                }

                Text("↑ marks videos punching above this creator's median view count")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Inline search field for filtering this creator's videos by title.
    /// Magnifying-glass icon + plain TextField wrapped in a rounded background — same
    /// look as the topic sidebar search field already in the app.
    @ViewBuilder
    private var creatorSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Search videos", text: $creatorSearchText)
                .textFieldStyle(.plain)
                .font(.body)
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 240)
            if !creatorSearchText.isEmpty {
                Button {
                    creatorSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    /// "52 total" when no filter is active; "12 of 52" when the search has narrowed
    /// the visible set so the user can see how much the filter is hiding.
    private var allVideosCountLabel: String {
        let total = page.allVideos.count
        let visible = filteredAllVideos.count
        if visible == total {
            return "\(total) total"
        }
        return "\(visible) of \(total)"
    }

    @ViewBuilder
    private var allVideosTable: some View {
        Table(sortedAllVideos, selection: $allVideosSelection, sortOrder: $allVideosSort) {
            TableColumn("Title", value: \.title) { card in
                HStack(spacing: 8) {
                    tableThumbnail(for: card)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(card.title)
                                .font(.body)
                                .lineLimit(1)
                            if card.isOutlier {
                                Image(systemName: "arrow.up")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.tint)
                                    .help(outlierTooltip(card))
                                    .accessibilityLabel("Outlier")
                            }
                        }
                        if let topic = card.topicName {
                            Text(topic)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .width(min: 240, ideal: 360)

            TableColumn("Views", value: \.viewCountParsed) { card in
                Text(card.viewCountParsed > 0 ? card.viewCountFormatted : "—")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(card.viewCountParsed > 0 ? .primary : .secondary)
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Runtime") { card in
                Text(card.runtimeFormatted ?? "—")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(card.runtimeFormatted != nil ? .primary : .secondary)
            }
            .width(min: 60, ideal: 70, max: 100)

            TableColumn("Age", value: \.ageDaysSortKey) { card in
                Text(card.ageFormatted ?? "—")
                    .font(.body)
                    .foregroundStyle(card.ageFormatted != nil ? .primary : .secondary)
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn("Saved") { card in
                if card.isSaved {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Saved in your library")
                } else {
                    Text("")
                }
            }
            .width(min: 40, ideal: 50, max: 70)
        }
        .frame(minHeight: 240, idealHeight: 380, maxHeight: 520)
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: CreatorVideoCard.ID.self) { ids in
            let cards = cardsForSelection(ids)
            if !cards.isEmpty {
                videoContextMenuItems(for: cards)
            }
        } primaryAction: { ids in
            // Double-click / return-key default action: open the selected video(s)
            // on YouTube. Native list pattern (Mail, Music, Files all behave this way).
            let cards = cardsForSelection(ids)
            for card in cards {
                if let url = card.youtubeUrl {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func cardsForSelection(_ ids: Set<CreatorVideoCard.ID>) -> [CreatorVideoCard] {
        guard !ids.isEmpty else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: page.allVideos.map { ($0.videoId, $0) })
        return ids.compactMap { lookup[$0] }
    }

    /// Sort menu for the All Videos grid. Matches the main grid's sectioned
    /// sort menu style: one row per dimension, "Clear Sort" at the bottom
    /// that returns to the default (.byTheme). No Creator or Shuffle since
    /// both are nonsensical on a per-creator page.
    @ViewBuilder
    private var allVideosGridSortMenu: some View {
        Menu {
            Section("Sort") {
                ForEach(AllVideosGridSort.allCases) { sort in
                    Button {
                        allVideosGridSort = sort
                    } label: {
                        if allVideosGridSort == sort {
                            Label(sort.label, systemImage: "checkmark")
                        } else {
                            Label(sort.label, systemImage: sort.symbolName)
                        }
                    }
                    .accessibilityIdentifier("creatorSort\(sort.label)")
                }

                Button {
                    allVideosGridSort = .byTheme
                } label: {
                    Label("Clear Sort", systemImage: "line.3.horizontal.decrease.circle")
                }
                .disabled(allVideosGridSort == .byTheme)
            }
        } label: {
            Label(allVideosGridSort.label, systemImage: allVideosGridSort.symbolName)
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort grid videos")
        .accessibilityIdentifier("creatorAllVideosGridSortMenu")
    }

    @ViewBuilder
    private var allVideosGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(gridSortedAllVideos) { card in
                allVideosGridCard(card)
            }
        }
    }

    /// By Theme grouping. Each major theme becomes a section header followed
    /// by a LazyVGrid of its videos. Long-tail themes (themes with fewer than
    /// 3 videos OR not in the top 8) collapse into a final "Other" section.
    /// Falls back to a flat grid when the creator has no themes yet — that
    /// way the byTheme mode is safe to use as the default even on creators
    /// whose themes haven't been classified.
    @ViewBuilder
    private var allVideosByTheme: some View {
        let groups = byThemeGroups
        if groups.isEmpty {
            // No themes available — fall back to the flat grid so the user
            // still sees something while the byTheme mode is the default.
            allVideosGrid
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(groups) { group in
                    byThemeGroupSection(group)
                }
            }
        }
    }

    /// One theme bucket inside the byTheme view: a section header (theme
    /// label + count + optional series icon) and the videos belonging to
    /// the theme rendered as a LazyVGrid.
    @ViewBuilder
    private func byThemeGroupSection(_ group: ByThemeGroup) -> some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let color = group.color {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: 12, height: 12)
                }
                if group.isSeries {
                    Image(systemName: "list.number")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(group.label)
                    .font(.headline)
                Text("\(group.cards.count) video\(group.cards.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(group.cards) { card in
                    allVideosGridCard(card)
                }
            }
        }
    }

    /// Single grid card with the standard hover/context-menu treatment. Both
    /// the flat grid view and the byTheme grouped view use this so the card
    /// behavior stays consistent. Saved cards get a small "Saved" badge in
    /// the top-right corner of the thumbnail so users can see at a glance
    /// which videos in a theme group are already in their library.
    @ViewBuilder
    private func allVideosGridCard(_ card: CreatorVideoCard) -> some View {
        Link(destination: card.youtubeUrl ?? URL(string: "https://www.youtube.com")!) {
            VideoGridItem(
                video: gridModel(for: card),
                isSelected: false,
                isHovering: false,
                cacheDir: thumbnailCache.cacheDirURL,
                showMetadata: true,
                size: 200,
                highlightTerms: [],
                forceShowTitle: false
            )
            .overlay(alignment: .topTrailing) {
                if card.isSaved {
                    savedBadge
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            videoContextMenuItems(for: [card])
        }
    }

    /// Small "Saved" pill rendered as an overlay on cards already in the
    /// user's library. Lives on the top-trailing corner of the thumbnail
    /// so it doesn't fight the duration badge in the bottom-trailing.
    private var savedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Saved")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.92), in: Capsule())
        .accessibilityLabel("Saved in your library")
    }

    /// One section in the byTheme view. `themeLabel` and `videoIds` come
    /// directly from a CreatorThemeRecord; `cards` is the resolved subset of
    /// the page's all-videos list belonging to this theme. The `Other` bucket
    /// uses themeLabel="Other" with a nil color.
    struct ByThemeGroup: Identifiable {
        let id: String                  // theme label or "__other__"
        let label: String
        let color: Color?
        let isSeries: Bool
        let cards: [CreatorVideoCard]
    }

    /// Build the byTheme groups from the filtered+sorted card list. Iterates
    /// `majorThemeSlices` first so the section ordering matches the radial
    /// chart's slice ordering. Each video is assigned to its FIRST matching
    /// theme to keep groups disjoint. Videos belonging to no major theme go
    /// into the "Other" bucket. Within each section, cards are sorted by the
    /// active grid sort preference so the existing sort menu still works.
    private var byThemeGroups: [ByThemeGroup] {
        let slices = majorThemeSlices
        guard !slices.isEmpty else { return [] }

        let sortedCards = gridSortedAllVideos
        var seenVideoIds = Set<String>()
        var groups: [ByThemeGroup] = []

        for slice in slices where slice.themeRecord != nil {
            let themeIds = Set(slice.themeRecord!.videoIds)
            let cards = sortedCards.filter { card in
                guard themeIds.contains(card.videoId), !seenVideoIds.contains(card.videoId) else {
                    return false
                }
                seenVideoIds.insert(card.videoId)
                return true
            }
            if !cards.isEmpty {
                groups.append(ByThemeGroup(
                    id: slice.label,
                    label: slice.label,
                    color: slice.color,
                    isSeries: slice.themeRecord?.isSeries ?? false,
                    cards: cards
                ))
            }
        }

        // Anything not yet claimed goes into the Other bucket. Includes both
        // the long-tail themes (slices with themeRecord == nil never have a
        // member set, so their videos fall through to here) and any video
        // that isn't in any classified theme at all.
        let otherCards = sortedCards.filter { !seenVideoIds.contains($0.videoId) }
        if !otherCards.isEmpty {
            groups.append(ByThemeGroup(
                id: "__other__",
                label: "Other",
                color: Color.gray.opacity(0.5),
                isSeries: false,
                cards: otherCards
            ))
        }
        return groups
    }

    private func gridModel(for card: CreatorVideoCard) -> VideoGridItemModel {
        VideoGridItemModel(
            id: card.videoId,
            topicId: card.topicId,
            title: card.title,
            channelName: page.channelName,
            topicName: card.topicName,
            thumbnailUrl: card.thumbnailUrl,
            viewCount: card.viewCountParsed > 0 ? card.viewCountFormatted : nil,
            publishedAt: card.ageFormatted,
            duration: card.runtimeFormatted,
            channelIconUrl: page.avatarUrl,
            channelId: card.topicId == nil ? nil : channelId,
            candidateScore: nil,
            stateTag: card.isOutlier ? "OUTLIER" : nil,
            isPlaceholder: false,
            placeholderMessage: nil,
            // All cards on this page belong to the same creator, so the
            // page channel's cached icon bytes apply to every card.
            channelIconData: store.knownChannelsById[channelId]?.iconData
        )
    }

    /// All videos with the per-creator search AND the theme capsule filter applied.
    /// Used by the count label, the table, and the grid so all three stay in sync with
    /// what the user is filtering for. Both filters compose as an intersection.
    private var filteredAllVideos: [CreatorVideoCard] {
        var working = page.allVideos

        // Theme capsule filter (LLM-cluster membership).
        if let themeLabel = selectedThemeLabel,
           let theme = page.themes.first(where: { $0.label == themeLabel }) {
            let allowedIds = Set(theme.videoIds)
            working = working.filter { allowedIds.contains($0.videoId) }
        }

        // Free-text title substring filter.
        let trimmed = creatorSearchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let needle = trimmed.lowercased()
            working = working.filter { card in
                card.title.lowercased().contains(needle)
            }
        }

        return working
    }

    private var sortedAllVideos: [CreatorVideoCard] {
        filteredAllVideos.sorted(using: allVideosSort)
    }

    /// Grid-mode sort path. Reads the @AppStorage-backed `allVideosGridSort`
    /// preference (see the menu next to the view-mode toggle) and applies it
    /// to the same filtered set the table uses. Kept separate from the
    /// table's KeyPathComparator-based sort because Table sorting is column
    /// header driven and doesn't translate to the grid card layout.
    private var gridSortedAllVideos: [CreatorVideoCard] {
        let base = filteredAllVideos
        switch allVideosGridSort {
        case .byTheme:
            // .byTheme is a *grouping* mode (the rendering switch routes
            // it to `allVideosByTheme`), so the underlying linear sort
            // here just orders cards within each theme group by
            // newest-first. The byThemeGroups builder consumes this list.
            return base.sorted { ($0.ageDays ?? .max) < ($1.ageDays ?? .max) }
        case .date:
            return base.sorted { ($0.ageDays ?? .max) < ($1.ageDays ?? .max) }
        case .views:
            return base.sorted { $0.viewCountParsed > $1.viewCountParsed }
        case .duration:
            return base.sorted { runtimeMinutes($0) > runtimeMinutes($1) }
        case .alphabetical:
            return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .outlierScore:
            return base.sorted { $0.outlierScore > $1.outlierScore }
        }
    }

    /// Best-effort numeric runtime in minutes for grid sort. Parses the
    /// "12:34" / "1:02:45" formatted string the rest of the page already has;
    /// returns -1 (sorts last) for unknown durations so they don't pollute
    /// the top of either ascending or descending order.
    private func runtimeMinutes(_ card: CreatorVideoCard) -> Double {
        guard let raw = card.runtimeFormatted else { return -1 }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2:
            return parts[0] + parts[1] / 60
        case 3:
            return parts[0] * 60 + parts[1] + parts[2] / 60
        default:
            return -1
        }
    }

    @ViewBuilder
    private func tableThumbnail(for card: CreatorVideoCard) -> some View {
        // Same on-disk-cache-first treatment as `thumbnail(for:)`. Without
        // this, every visible Table row punched the network on every render.
        ThumbnailView(
            videoId: card.videoId,
            thumbnailUrl: card.thumbnailUrl,
            cacheDir: thumbnailCache.cacheDirURL
        )
        .frame(width: 56, height: 32)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func outlierTooltip(_ card: CreatorVideoCard) -> String {
        guard page.channelMedianViews > 0 else { return "Outlier" }
        let multiplier = String(format: "%.1f×", card.outlierScore)
        let actual = formatCompact(card.viewCountParsed)
        let median = formatCompact(page.channelMedianViews)
        return "View count is \(multiplier) this creator's median (\(actual) vs \(median) median)"
    }

    // MARK: - In your playlists

    @ViewBuilder
    private var playlistsSection: some View {
        if !page.playlists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("In your playlists")
                    .font(.title3.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(Array(page.playlists.enumerated()), id: \.element.id) { index, entry in
                        playlistRow(entry)
                        if index < page.playlists.count - 1 {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.background.secondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
            }
        }
    }

    private func playlistRow(_ entry: CreatorPlaylistEntry) -> some View {
        Button {
            store.applyPlaylistFilter(entry.playlist)
            store.popToRootDetail()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.playlist.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("\(entry.creatorVideoCount) video\(entry.creatorVideoCount == 1 ? "" : "s") from this creator")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Filter the topic grid to videos in \(entry.playlist.title)")
    }

    // MARK: - Top creators in this niche (competitor leaderboard)

    @ViewBuilder
    private var leaderboardSection: some View {
        let entries = currentLeaderboardEntries
        if !entries.isEmpty, let scope = currentLeaderboardScope {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Top creators in this niche")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    leaderboardScopePicker
                    leaderboardMetricPicker
                }

                Text("\(scope.creatorCount) creators publish \(scope.topicName) videos in your library — ranked by \(metricDescription)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        leaderboardRow(rank: index + 1, entry: entry)
                        if index < entries.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.background.secondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
            }
        }
    }

    /// The active scope object — looks up the chosen topicId in the page's scope list.
    private var currentLeaderboardScope: CreatorLeaderboardScope? {
        guard let topicId = leaderboardScopeTopicId ?? page.leaderboardDefaultTopicId else {
            return nil
        }
        return page.leaderboardScopes.first(where: { $0.topicId == topicId })
    }

    /// Entries for the current scope, re-sorted by the selected metric. Both data
    /// pieces are pre-computed in the builder so this is a free in-memory sort.
    private var currentLeaderboardEntries: [CreatorLeaderboardEntry] {
        guard let topicId = leaderboardScopeTopicId ?? page.leaderboardDefaultTopicId,
              let raw = page.leaderboardByTopic[topicId] else {
            return []
        }
        return raw.sorted { lhs, rhs in
            switch leaderboardMetric {
            case .savedCount:
                if lhs.savedVideoCount != rhs.savedVideoCount {
                    return lhs.savedVideoCount > rhs.savedVideoCount
                }
            case .outlierCount:
                if lhs.outlierVideoCount != rhs.outlierVideoCount {
                    return lhs.outlierVideoCount > rhs.outlierVideoCount
                }
            case .totalViews:
                if lhs.totalViewsInTopic != rhs.totalViewsInTopic {
                    return lhs.totalViewsInTopic > rhs.totalViewsInTopic
                }
            }
            return lhs.channelName.localizedStandardCompare(rhs.channelName) == .orderedAscending
        }
    }

    private var metricDescription: String {
        switch leaderboardMetric {
        case .savedCount: return "saved video count"
        case .outlierCount: return "outlier count (videos punching above their channel median)"
        case .totalViews: return "total views in this topic"
        }
    }

    /// Topic scope picker — Menu of every topic the page creator publishes in.
    @ViewBuilder
    private var leaderboardScopePicker: some View {
        if page.leaderboardScopes.count > 1 {
            Menu {
                ForEach(page.leaderboardScopes) { scope in
                    Button {
                        leaderboardScopeTopicId = scope.topicId
                    } label: {
                        if scope.topicId == (leaderboardScopeTopicId ?? page.leaderboardDefaultTopicId) {
                            Label(scope.topicName, systemImage: "checkmark")
                        } else {
                            Text(scope.topicName)
                        }
                    }
                }
            } label: {
                Label(currentLeaderboardScope?.topicName ?? "Topic", systemImage: "rectangle.stack")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick which topic to compute the leaderboard against")
        }
    }

    /// Metric picker — Menu (not segmented) for [Saved | Outliers | Views].
    /// Same crash-avoidance reasoning as the All Videos view-mode picker:
    /// segmented Pickers can crash during SwiftUI scroll prefetch on macOS
    /// 26 when their enum case count varies, and Menus avoid the issue
    /// entirely.
    @ViewBuilder
    private var leaderboardMetricPicker: some View {
        Menu {
            ForEach(LeaderboardMetric.allCases) { metric in
                Button {
                    leaderboardMetric = metric
                } label: {
                    if leaderboardMetric == metric {
                        Label(metric.label, systemImage: "checkmark")
                    } else {
                        Label(metric.label, systemImage: metric.symbolName)
                    }
                }
            }
        } label: {
            Label(leaderboardMetric.label, systemImage: leaderboardMetric.symbolName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Rank by saved video count, outlier count, or total views")
    }

    @ViewBuilder
    private func leaderboardRow(rank: Int, entry: CreatorLeaderboardEntry) -> some View {
        Button {
            if !entry.isPageCreator {
                store.openCreatorDetail(channelId: entry.channelId)
            }
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(entry.isPageCreator ? Color.accentColor : .secondary)
                    .frame(width: 22, alignment: .trailing)

                ChannelIconView(
                    iconData: store.knownChannelsById[entry.channelId]?.iconData,
                    fallbackUrl: entry.channelIconUrl
                )
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.channelName)
                            .font(.body.weight(entry.isPageCreator ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if entry.isPageCreator {
                            Text("YOU")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                        }
                    }
                    Text(leaderboardSubtitle(for: entry))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(metricValueText(for: entry))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())

                if !entry.isPageCreator {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Color.clear.frame(width: 7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                entry.isPageCreator
                ? Color.accentColor.opacity(0.08)
                : Color.clear
            )
        }
        .buttonStyle(.plain)
        .help(entry.isPageCreator
              ? "This is the creator whose page you're viewing"
              : "Open \(entry.channelName)'s creator page")
    }

    private func metricValueText(for entry: CreatorLeaderboardEntry) -> String {
        switch leaderboardMetric {
        case .savedCount:
            return "\(entry.savedVideoCount)"
        case .outlierCount:
            return "\(entry.outlierVideoCount)"
        case .totalViews:
            return formatCompact(entry.totalViewsInTopic)
        }
    }

    private var metricUnitText: String {
        let topicName = currentLeaderboardScope?.topicName ?? ""
        switch leaderboardMetric {
        case .savedCount: return "saved · in \(topicName)"
        case .outlierCount: return "outliers · in \(topicName)"
        case .totalViews: return "views · in \(topicName)"
        }
    }

    private func leaderboardSubtitle(for entry: CreatorLeaderboardEntry) -> String {
        var parts: [String] = []
        switch leaderboardMetric {
        case .savedCount:
            if entry.outlierVideoCount > 0 {
                parts.append("\(entry.outlierVideoCount) outlier\(entry.outlierVideoCount == 1 ? "" : "s")")
            }
            if entry.totalViewsInTopic > 0 {
                parts.append("\(formatCompact(entry.totalViewsInTopic)) views")
            }
        case .outlierCount:
            parts.append("\(entry.savedVideoCount) saved")
            if entry.totalViewsInTopic > 0 {
                parts.append("\(formatCompact(entry.totalViewsInTopic)) views")
            }
        case .totalViews:
            parts.append("\(entry.savedVideoCount) saved")
            if entry.outlierVideoCount > 0 {
                parts.append("\(entry.outlierVideoCount) outlier\(entry.outlierVideoCount == 1 ? "" : "s")")
            }
        }
        if let subs = entry.subscriberCountFormatted {
            parts.append(subs)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Notes (per-creator scratch pad)

    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Notes")
                    .font(.title3.weight(.semibold))
                Spacer()
                if notesFocused {
                    Button("Done") {
                        notesFocused = false
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }

            TextEditor(text: $notesDraft)
                .font(.body)
                .focused($notesFocused)
                .frame(minHeight: 80, idealHeight: 100)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.background.secondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(notesFocused ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: notesFocused ? 1.5 : 0.5)
                )
                .overlay(alignment: .topLeading) {
                    if notesDraft.isEmpty && !notesFocused {
                        Text("Why are you tracking this creator? What patterns have you noticed? Click to add notes…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            Text("Notes are saved when you click outside the field or press ⌘↩. Saving notes implicitly pins this creator.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Channel information

    @ViewBuilder
    private var channelInformationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Channel information")
                    .font(.title3.weight(.semibold))
                Spacer()
                loadNext400Button
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if let subs = page.subscriberCountFormatted {
                    infoRow("Subscribers", value: subs)
                }
                infoRow("Total uploads (known)", value: "\(page.totalUploadsKnown)")
                if let reported = page.totalUploadsReported, reported != page.totalUploadsKnown {
                    infoRow("Total uploads (reported)", value: "\(reported)")
                }
                infoRow("In your library", value: libraryCoverageString)
                if let founding = page.foundingYear {
                    infoRow("Earliest known upload", value: String(founding))
                }
                if let country = page.countryDisplayName {
                    infoRow("Country", value: country)
                }
                if let refreshed = page.lastRefreshedAt {
                    infoRow("Last refreshed", value: refreshedRowValue(date: refreshed))
                }
                infoRowLink("YouTube", url: page.youtubeURL)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )

            // Destructive Exclude action docked at the bottom of the page,
            // out of the header where it could be misclicked.
            HStack {
                Spacer()
                Button(role: page.isExcluded ? nil : .destructive) {
                    if page.isExcluded {
                        store.restoreExcludedCreator(channelId: channelId)
                    } else {
                        store.excludeCreatorFromWatch(
                            channelId: channelId,
                            channelName: page.channelName,
                            channelIconUrl: page.avatarUrl?.absoluteString
                        )
                    }
                } label: {
                    Label(
                        page.isExcluded ? "Restore from Watch" : "Exclude from Watch",
                        systemImage: page.isExcluded ? "checkmark.circle" : "nosign"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help(page.isExcluded
                      ? "Restore this creator to Watch discovery"
                      : "Hide this creator from Watch discovery")
                .accessibilityIdentifier("creatorBottomExcludeButton")
            }
            .padding(.top, 8)
        }
    }

    /// "Load next 400" button. Triggers the deeper one-shot scrape (max 400
    /// videos vs the default 16) and shows a small spinner + result count
    /// next to itself. Disabled while a load is in flight; once a load
    /// completes, the result count persists for the remainder of the
    /// session as quiet feedback.
    @ViewBuilder
    private var loadNext400Button: some View {
        let isLoading = store.loadingFullHistoryChannels.contains(channelId)
        let lastCount = store.lastFullHistoryLoadCount[channelId]
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let lastCount {
                Text(lastCount == 0 ? "No new videos" : "Loaded \(lastCount) more")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Button {
                store.loadFullChannelHistory(
                    channelId: channelId,
                    channelName: page.channelName
                )
            } label: {
                Label("Load next 400", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoading)
            .help("Scrape this creator's last 400 uploads into your archive (one-shot, no API quota)")
        }
        .onChange(of: store.lastFullHistoryLoadCount[channelId]) { _, _ in
            // Rebuild the page model after a load completes so totalUploadsKnown,
            // allVideos, monthlyVideoCounts and downstream stats reflect the new
            // archive rows immediately.
            if !store.loadingFullHistoryChannels.contains(channelId) {
                page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
            }
        }
    }

    /// Build the value displayed for the "Last refreshed" row, including the
    /// stale-warning suffix when the cache is more than 7 days old.
    private func refreshedRowValue(date: Date) -> String {
        let formatted = formatRefreshTime(date)
        let ageDays = Int(Date().timeIntervalSince(date) / 86_400)
        if ageDays >= 7 {
            return "\(formatted) · \(ageDays) days old"
        }
        return formatted
    }

    private var libraryCoverageString: String {
        if let coverage = page.coveragePercent {
            let pct = Int(coverage * 100)
            return "\(page.savedVideoCount) (\(pct)%)"
        }
        return "\(page.savedVideoCount)"
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func infoRowLink(_ label: String, url: URL) -> some View {
        GridRow {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Link(url.absoluteString, destination: url)
                    .font(.body)
                Image(systemName: "arrow.up.right.square")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatRefreshTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Context menus (macOS-native actions)

    /// The single source of truth for per-video actions on the page. Used by every
    /// surface that displays a video — All Videos table rows, grid cards, Essentials
    /// shelf cards, and the What's new row. Mirrors the existing CollectionGridView
    /// context menu so muscle memory transfers between the topic grid and the creator
    /// detail page.
    @ViewBuilder
    private func videoContextMenuItems(for cards: [CreatorVideoCard]) -> some View {
        let openLabel = cards.count == 1 ? "Open on YouTube" : "Open All on YouTube"
        Button {
            for card in cards {
                if let url = card.youtubeUrl {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Label(openLabel, systemImage: "arrow.up.right.square")
        }

        let copyLabel = cards.count == 1 ? "Copy YouTube Link" : "Copy YouTube Links"
        Button {
            let urls = cards.map { "https://www.youtube.com/watch?v=\($0.videoId)" }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls, forType: .string)
        } label: {
            Label(copyLabel, systemImage: "link")
        }

        Divider()

        Button {
            store.saveVideosToWatchLater(videoIds: cards.map(\.videoId))
        } label: {
            Label("Save to Watch Later", systemImage: "clock")
        }

        let savablePlaylists = store.knownPlaylists().filter { $0.playlistId != "WL" }
        if !savablePlaylists.isEmpty {
            Menu {
                ForEach(savablePlaylists) { playlist in
                    Button(playlist.title) {
                        store.saveVideosToPlaylist(
                            videoIds: cards.map(\.videoId),
                            playlist: playlist
                        )
                    }
                }
            } label: {
                Label("Save to Playlist…", systemImage: "music.note.list")
            }
        }

        // Mark Not Interested only applies to videos already saved into a topic.
        let savedCardsWithTopic = cards.filter { $0.isSaved && $0.topicId != nil }
        if !savedCardsWithTopic.isEmpty {
            Divider()
            Button(role: .destructive) {
                // Group by topicId since markCandidatesNotInterested takes a single topic.
                let byTopic = Dictionary(grouping: savedCardsWithTopic) { $0.topicId ?? -1 }
                for (topicId, group) in byTopic where topicId != -1 {
                    store.markCandidatesNotInterested(
                        topicId: topicId,
                        videoIds: group.map(\.videoId)
                    )
                }
            } label: {
                Label("Mark as Not Interested", systemImage: "hand.thumbsdown")
            }
        }
    }

    /// Context menu for the identity header — channel-level actions. Mirrors the
    /// header action buttons but accessible via right-click directly on the avatar/title.
    /// Pin/Unpin is intentionally absent until Phase 3 wires the favorite signal into
    /// Watch refresh ranking — keeping it out of the menu matches the header.
    @ViewBuilder
    private var identityContextMenuItems: some View {
        Button {
            NSWorkspace.shared.open(page.youtubeURL)
        } label: {
            Label("Open Channel on YouTube", systemImage: "arrow.up.right.square")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(page.youtubeURL.absoluteString, forType: .string)
        } label: {
            Label("Copy Channel URL", systemImage: "link")
        }

        Divider()

        // "Load more uploads" — manual re-trigger of the deeper one-shot
        // archive scrape (max 200 videos vs the default 16). The auto-load
        // in .task only fires once per channel per session, so users who
        // want to pull in newer uploads after that first load need this
        // affordance. Lives here in the context menu now that the standalone
        // Channel Information section was removed.
        Button {
            store.loadFullChannelHistory(
                channelId: channelId,
                channelName: page.channelName
            )
        } label: {
            Label(
                store.loadingFullHistoryChannels.contains(channelId)
                    ? "Loading more uploads…"
                    : "Load more uploads",
                systemImage: "arrow.down.circle"
            )
        }
        .disabled(store.loadingFullHistoryChannels.contains(channelId))

        Divider()

        Button(role: .destructive) {
            if page.isExcluded {
                store.restoreExcludedCreator(channelId: channelId)
            } else {
                store.excludeCreatorFromWatch(
                    channelId: channelId,
                    channelName: page.channelName,
                    channelIconUrl: page.avatarUrl?.absoluteString
                )
            }
        } label: {
            Label(
                page.isExcluded ? "Restore from Watch" : "Exclude from Watch",
                systemImage: page.isExcluded ? "checkmark.circle" : "nosign"
            )
        }

        Button {
            openSettings()
        } label: {
            Label(
                store.excludedCreators.isEmpty
                    ? "Manage Excluded Creators…"
                    : "Manage Excluded Creators (\(store.excludedCreators.count))…",
                systemImage: "person.crop.circle.badge.xmark"
            )
        }
    }
}

// MARK: - Sort key helpers

private extension CreatorVideoCard {
    /// `Table` sort needs a non-optional, totally ordered key. Use a large sentinel for
    /// unknown ages so they sort last regardless of direction (consistent with the rest
    /// of the app's "—" treatment).
    var ageDaysSortKey: Int {
        ageDays ?? Int.max
    }
}
