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

    @State private var page: CreatorPageViewModel = .placeholderEmpty
    @State private var allVideosSort: [KeyPathComparator<CreatorVideoCard>] = [
        KeyPathComparator(\CreatorVideoCard.ageDays, order: .forward)
    ]
    @State private var allVideosSelection: CreatorVideoCard.ID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                identityCard
                whatsNewSection
                essentialsSection
                allVideosSection
                playlistsSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .navigationTitle(page.channelName)
        .navigationSubtitle(page.subtitle ?? "")
        .task(id: channelId) {
            page = CreatorPageBuilder.makePage(forChannelId: channelId, in: store)
        }
    }

    // MARK: - Identity card

    @ViewBuilder
    private var identityCard: some View {
        HStack(alignment: .top, spacing: 16) {
            avatar
                .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 4) {
                Text(page.channelName)
                    .font(.title.weight(.semibold))
                    .lineLimit(1)

                if let subtitle = page.subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                tierLine
                statsLine
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if let data = page.avatarData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let url = page.avatarUrl {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        avatarFallback
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        avatarFallback
                    @unknown default:
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(.tertiary)
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
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

    // MARK: - What's new

    @ViewBuilder
    private var whatsNewSection: some View {
        if let latest = page.latestVideo {
            VStack(alignment: .leading, spacing: 8) {
                Text("What's new")
                    .font(.title3.weight(.semibold))

                whatsNewRow(latest)
            }
        }
    }

    private func whatsNewRow(_ card: CreatorVideoCard) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(for: card)
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.headline)
                    .lineLimit(2)
                metadataLine(for: card)
            }

            Spacer(minLength: 0)

            if let url = card.youtubeUrl {
                Link(destination: url) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Open this video on YouTube")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
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

                Text(card.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 200, alignment: .leading)

                if card.viewCountParsed > 0 {
                    Text(card.viewCountFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(essentialsCardTooltip(card))
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

    // MARK: - All videos

    @ViewBuilder
    private var allVideosSection: some View {
        if !page.allVideos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("All videos")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(page.allVideos.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

                Text("↑ marks videos punching above this creator's median view count")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sortedAllVideos: [CreatorVideoCard] {
        page.allVideos.sorted(using: allVideosSort)
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
