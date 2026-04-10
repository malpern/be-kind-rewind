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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                identityCard
                whatsNewSection
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
}
