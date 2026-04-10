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
    /// Same enum used by both creator-page surfaces and any future per-section toggle.
    @AppStorage("creatorAllVideosViewMode") private var allVideosViewMode: AllVideosViewMode = .table

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

    enum AllVideosViewMode: String, CaseIterable, Identifiable {
        case table
        case grid

        var id: String { rawValue }
        var label: String { self == .table ? "Table" : "Grid" }
        var symbolName: String { self == .table ? "tablecells" : "square.grid.2x2" }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                identityCard
                whatsNewSection
                essentialsSection
                theirHitsSection
                themeCapsulesSection
                allVideosSection
                byThemeSection
                playlistsSection
                nichesAndCadenceSection
                leaderboardSection
                notesSection
                channelInformationSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 32)
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
        .onChange(of: store.classifyingThemeChannels.contains(channelId)) { wasClassifying, isClassifying in
            // When classification finishes (true → false), rebuild the page so the
            // newly-cached themes and about paragraph appear.
            if wasClassifying && !isClassifying {
                page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
            } else if !wasClassifying && isClassifying {
                // Rebuild once at the start so the loading indicator appears.
                page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
            }
        }
    }

    // MARK: - Identity card

    /// App Store / Apple Podcasts pattern: square (rounded-corner) icon on the left,
    /// info stack on the right, no card chrome — sits flush with the page. The
    /// rounded-square avatar treatment deliberately departs from YouTube's circular
    /// convention so the page reads as a native macOS detail page rather than a
    /// YouTube-flavored widget.
    @ViewBuilder
    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                avatar
                    .frame(width: 160, height: 160)

                VStack(alignment: .leading, spacing: 6) {
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    } else if page.isClassifyingThemes {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating creator summary…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }

                    tierLine
                    statsLine
                    headerActionButtons
                        .padding(.top, 8)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .contextMenu {
                identityContextMenuItems
            }

            Divider()
        }
    }

    /// Inline action buttons that live in the header next to the avatar/title, the
    /// way Apple Music's artist hero (Play / Shuffle / ...) and the Mac App Store
    /// product page (Get button) put primary actions adjacent to the entity. macOS
    /// users grab these faster than reaching for the toolbar.
    ///
    /// The action set is deliberately small and meaningful for a *creator on this page*:
    /// Open on YouTube (prominent primary), Pin (favorite), Copy Link, Share (system
    /// share sheet), and Exclude (destructive).
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

            Button {
                store.toggleFavoriteCreator(
                    channelId: channelId,
                    channelName: page.channelName,
                    iconUrl: page.avatarUrl?.absoluteString
                )
            } label: {
                Label(
                    page.isFavorite ? "Pinned" : "Pin",
                    systemImage: page.isFavorite ? "pin.fill" : "pin"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(page.isFavorite
                  ? "Remove from pinned creators (their videos will no longer be boosted in Watch refresh)"
                  : "Pin this creator (their videos will be prioritized in Watch refresh)")
            .accessibilityIdentifier("creatorHeaderPinButton")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.youtubeURL.absoluteString, forType: .string)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Copy this channel's YouTube URL to the clipboard")
            .accessibilityIdentifier("creatorHeaderCopyLinkButton")

            ShareLink(item: page.youtubeURL, subject: Text(page.channelName)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Share this channel via the system share sheet")
            .accessibilityIdentifier("creatorHeaderShareButton")

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
                    page.isExcluded ? "Excluded" : "Exclude",
                    systemImage: page.isExcluded ? "checkmark.circle" : "nosign"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(page.isExcluded ? "Restore this creator to Watch discovery" : "Hide this creator from Watch discovery")
            .accessibilityIdentifier("creatorHeaderExcludeButton")
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
    @ViewBuilder
    private var avatar: some View {
        Group {
            if let url = page.avatarUrl {
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

    @ViewBuilder
    private var tierLine: some View {
        let parts: [String] = [
            page.creatorTier,
            page.foundingYear.map { "since \($0)" },
            page.countryDisplayName
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statsLine: some View {
        let chips = headerChips
        if !chips.isEmpty {
            Text(chips.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var headerChips: [String] {
        var chips: [String] = []
        chips.append("\(page.savedVideoCount) saved")
        if page.watchedVideoCount > 0 {
            chips.append("\(page.watchedVideoCount) watched")
        }
        if let subs = page.subscriberCountFormatted {
            chips.append(subs)
        }
        if let lastUpload = page.lastUploadAge {
            chips.append("last upload \(lastUpload)")
        }
        return chips
    }

    // MARK: - What's new / Recent uploads

    @ViewBuilder
    private var whatsNewSection: some View {
        if !page.recentVideos.isEmpty {
            // Multiple videos in the last 14 days → grid layout, "Recent uploads" header.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    if page.recentVideos.count == 1 {
                        Text("What's new")
                            .font(.title3.weight(.semibold))
                    } else {
                        Text("Recent uploads")
                            .font(.title3.weight(.semibold))
                        Text("last 14 days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if page.recentVideosTotalInWindow > page.recentVideos.count {
                        Text("+ \(page.recentVideosTotalInWindow - page.recentVideos.count) more")
                            .font(.caption)
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
            }
        } else if let latest = page.latestVideo {
            // Window was empty (creator hasn't posted in the last 14 days), but we
            // still want to surface their most recent upload as a fallback.
            VStack(alignment: .leading, spacing: 8) {
                Text("What's new")
                    .font(.title3.weight(.semibold))

                whatsNewRow(latest)
            }
        }
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
        if let url = card.thumbnailUrl {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    thumbnailPlaceholder
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    thumbnailPlaceholder
                @unknown default:
                    thumbnailPlaceholder
                }
            }
        } else {
            thumbnailPlaceholder
        }
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

    // MARK: - Essentials

    @ViewBuilder
    private var essentialsSection: some View {
        if !page.essentials.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Essentials")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text(essentialsHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(180))], spacing: 14) {
                        ForEach(page.essentials) { card in
                            essentialsCard(card)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var essentialsHelpText: String {
        // Surface the outlier baseline so the user understands "what counts as a hit
        // for this creator". Hidden when the median is meaningless (no view counts).
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
                    .font(.caption.monospacedDigit())
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
        .font(.caption2.weight(.semibold))
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
            parts.append("\(multiplier) channel median (\(formatCompact(page.channelMedianViews)) views)")
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

    // MARK: - Their hits (raw outlier ranking, no recency tilt)

    @ViewBuilder
    private var theirHitsSection: some View {
        // Only show when at least one video meaningfully outperformed (>= 1.5× median)
        // AND at least 2 outliers exist — a single hit is just luck, two is a pattern.
        let outliers = page.theirHits.filter { $0.outlierScore >= 1.5 }
        if outliers.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Their hits")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("ranked by outlier score · all-time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(180))], spacing: 14) {
                        ForEach(outliers) { card in
                            essentialsCard(card)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Theme capsules (LLM-driven)

    @ViewBuilder
    private var themeCapsulesSection: some View {
        if !page.themes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Themes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(page.themes, id: \.label) { theme in
                            themeCapsule(theme)
                        }
                        if selectedThemeLabel != nil {
                            Button {
                                selectedThemeLabel = nil
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } else if page.isClassifyingThemes && page.aboutParagraph == nil {
            // Show a single inline progress row above All Videos when classification
            // is in flight and we don't have an about paragraph rendering instead.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Classifying themes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func themeCapsule(_ theme: CreatorThemeRecord) -> some View {
        let isSelected = selectedThemeLabel == theme.label
        return Button {
            if isSelected {
                selectedThemeLabel = nil
            } else {
                selectedThemeLabel = theme.label
            }
        } label: {
            HStack(spacing: 6) {
                if theme.isSeries {
                    Image(systemName: "list.number")
                        .font(.caption.weight(.semibold))
                }
                Text(theme.label)
                    .font(.callout.weight(.medium))
                Text("\(theme.videoIds.count)")
                    .font(.caption.monospacedDigit())
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    creatorSearchField
                    Picker("", selection: $allVideosViewMode) {
                        ForEach(AllVideosViewMode.allCases) { mode in
                            Image(systemName: mode.symbolName)
                                .help(mode.label)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 88)
                    .help("Switch between table and grid views")
                }

                switch allVideosViewMode {
                case .table:
                    allVideosTable
                case .grid:
                    allVideosGrid
                }

                Text("↑ marks videos punching above this creator's median view count")
                    .font(.caption)
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
                .font(.caption.weight(.medium))
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
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tint)
                                    .help(outlierTooltip(card))
                                    .accessibilityLabel("Outlier")
                            }
                        }
                        if let topic = card.topicName {
                            Text(topic)
                                .font(.caption)
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

    @ViewBuilder
    private var allVideosGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(sortedAllVideos) { card in
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
            placeholderMessage: nil
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

    @ViewBuilder
    private func tableThumbnail(for card: CreatorVideoCard) -> some View {
        Group {
            if let url = card.thumbnailUrl {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.clear
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 56, height: 32)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func outlierTooltip(_ card: CreatorVideoCard) -> String {
        guard page.channelMedianViews > 0 else { return "Outlier" }
        let multiplier = String(format: "%.1f×", card.outlierScore)
        return "\(multiplier) channel median (\(formatCompact(page.channelMedianViews)) views)"
    }

    // MARK: - By theme (LLM-driven browse)

    @ViewBuilder
    private var byThemeSection: some View {
        if !page.themes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("By theme")
                    .font(.title3.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(Array(page.themes.enumerated()), id: \.element.label) { index, theme in
                        DisclosureGroup {
                            byThemeVideoList(for: theme)
                        } label: {
                            byThemeRowLabel(theme)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < page.themes.count - 1 {
                            Divider()
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

    private func byThemeRowLabel(_ theme: CreatorThemeRecord) -> some View {
        HStack(spacing: 8) {
            if theme.isSeries {
                Image(systemName: "list.number")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .help(theme.orderingSignal == "numeric" ? "Numbered series" :
                          theme.orderingSignal == "date" ? "Date-ordered series" : "Recurring series")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.label)
                    .font(.body.weight(.medium))
                if let description = theme.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Text("\(theme.videoIds.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(.gray.opacity(0.15)))
        }
    }

    @ViewBuilder
    private func byThemeVideoList(for theme: CreatorThemeRecord) -> some View {
        let allowed = Set(theme.videoIds)
        let videosInTheme = page.allVideos.filter { allowed.contains($0.videoId) }
        let standoutId = page.standoutEpisodesBySeriesLabel[theme.label]
        VStack(alignment: .leading, spacing: 4) {
            ForEach(videosInTheme) { card in
                Link(destination: card.youtubeUrl ?? URL(string: "https://www.youtube.com")!) {
                    HStack(spacing: 8) {
                        if card.videoId == standoutId {
                            Image(systemName: "star.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.yellow)
                                .help("Standout episode of this series")
                        }
                        Text(card.title)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if card.viewCountParsed > 0 {
                            Text(card.viewCountFormatted)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let age = card.ageFormatted {
                            Text(age)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    videoContextMenuItems(for: [card])
                }
            }
        }
        .padding(.top, 6)
        .padding(.leading, 8)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Filter the topic grid to videos in \(entry.playlist.title)")
    }

    // MARK: - Niches & cadence (the 25% analytics block)

    @ViewBuilder
    private var nichesAndCadenceSection: some View {
        if !page.topicShare.isEmpty || !page.monthlyVideoCounts.isEmpty {
            GroupBox("Niches & cadence") {
                HStack(alignment: .top, spacing: 24) {
                    topicShareChart
                    cadenceChart
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var topicShareChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Topic share")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("their share / library share")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if page.topicShare.isEmpty {
                Text("No saved videos yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Chart(page.topicShare) { share in
                    BarMark(
                        x: .value("Share", share.percentage),
                        y: .value("Topic", share.topicName)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading) {
                        // Two numbers: their slice of the page creator's saved videos,
                        // and their slice of the topic across all creators in library.
                        HStack(spacing: 4) {
                            Text(percentageString(share.percentage))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("/")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(percentageString(share.shareOfVoice))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(shareOfVoiceColor(share.shareOfVoice))
                        }
                        .padding(.leading, 4)
                        .help("\(share.videoCount) of this creator's saved videos · \(share.videoCount) of \(share.topicTotalSavedCount) total \(share.topicName) videos in your library (\(percentageString(share.shareOfVoice)) share of voice)")
                    }
                }
                .chartXScale(domain: 0...max(1.0, page.topicShare.map(\.percentage).max() ?? 1.0))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.gray.opacity(0.04))
                        .border(Color.gray.opacity(0.1), width: 0.5)
                }
                .frame(height: max(60, CGFloat(page.topicShare.count) * 26))
                .animation(.easeInOut(duration: 0.35), value: page.topicShare.map(\.percentage))
                .accessibilityLabel("Topic share for \(page.channelName)")
            }
        }
        .frame(minWidth: 240, idealWidth: 320, alignment: .leading)
    }

    /// Highlight high share-of-voice with the accent color so users can spot which
    /// topics this creator dominates in the library at a glance. >= 25% = accent,
    /// otherwise secondary text color.
    private func shareOfVoiceColor(_ share: Double) -> Color {
        share >= 0.25 ? .accentColor : .secondary
    }

    @ViewBuilder
    private var cadenceChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Videos / month (24mo)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            let totalDated = page.monthlyVideoCounts.reduce(0) { $0 + $1.count }
            let maxCount = page.monthlyVideoCounts.map(\.count).max() ?? 0
            if totalDated == 0 {
                Text("No dated videos available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Chart(page.monthlyVideoCounts) { bucket in
                    BarMark(
                        x: .value("Month", bucket.month, unit: .month),
                        y: .value("Videos", bucket.count),
                        width: .fixed(8)
                    )
                    .foregroundStyle(
                        bucket.count == 0
                        ? Color.accentColor.opacity(0.15)
                        : Color.accentColor.opacity(0.85)
                    )
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 6)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2]))
                            .foregroundStyle(.gray.opacity(0.2))
                        AxisTick(length: 4)
                            .foregroundStyle(.gray.opacity(0.4))
                        if value.as(Date.self) != nil {
                            AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2]))
                            .foregroundStyle(.gray.opacity(0.2))
                        AxisValueLabel()
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.gray.opacity(0.04))
                        .border(Color.gray.opacity(0.1), width: 0.5)
                }
                .frame(height: 100)
                .animation(.easeInOut(duration: 0.35), value: page.monthlyVideoCounts.map(\.count))
                .accessibilityLabel("Monthly upload cadence for \(page.channelName), peak \(maxCount) in a single month")
            }
        }
        .frame(minWidth: 240, idealWidth: 320, alignment: .leading)
    }

    private func percentageString(_ value: Double) -> String {
        if value >= 0.10 {
            return String(format: "%.0f%%", value * 100)
        }
        return String(format: "%.1f%%", value * 100)
    }

    // MARK: - Top creators in this niche (competitor leaderboard)

    @ViewBuilder
    private var leaderboardSection: some View {
        if !page.leaderboardEntries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Top creators in this niche")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("ranked by saved videos in shared topics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(page.leaderboardEntries.enumerated()), id: \.element.id) { index, entry in
                        leaderboardRow(rank: index + 1, entry: entry)
                        if index < page.leaderboardEntries.count - 1 {
                            Divider()
                                .padding(.leading, 56)
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

    private func leaderboardRow(rank: Int, entry: CreatorLeaderboardEntry) -> some View {
        Button {
            store.openCreatorDetail(channelId: entry.channelId)
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)

                leaderboardAvatar(entry)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.channelName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(leaderboardSubtitle(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(entry.channelName)'s creator page")
    }

    @ViewBuilder
    private func leaderboardAvatar(_ entry: CreatorLeaderboardEntry) -> some View {
        Group {
            if let url = entry.channelIconUrl {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        leaderboardAvatarFallback
                    }
                }
            } else {
                leaderboardAvatarFallback
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private var leaderboardAvatarFallback: some View {
        ZStack {
            Circle().fill(.tertiary)
            Image(systemName: "person.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
    }

    private func leaderboardSubtitle(for entry: CreatorLeaderboardEntry) -> String {
        var parts: [String] = ["\(entry.savedVideoCount) saved"]
        if let subs = entry.subscriberCountFormatted {
            parts.append(subs)
        }
        if entry.sharedTopicCount > 1 {
            parts.append("\(entry.sharedTopicCount) shared topics")
        } else {
            parts.append("1 shared topic")
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
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Channel information

    @ViewBuilder
    private var channelInformationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Channel information")
                .font(.title3.weight(.semibold))

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
                    infoRow("Last refreshed", value: formatRefreshTime(refreshed))
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
        }
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
                    .font(.caption)
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
