import SwiftUI

/// Video card displaying thumbnail, title, channel, and metadata badges.
struct VideoGridItem: View {
    let video: VideoGridItemModel
    let isSelected: Bool
    let isHovering: Bool
    let cacheDir: URL
    let showMetadata: Bool
    let size: Double
    var highlightTerms: [String] = []
    var forceShowTitle: Bool = false

    private var cornerRadius: CGFloat { GridConstants.cornerRadius(for: size) }
    private var cardPadding: CGFloat { GridConstants.cardPadding(for: size) }

    private var metadataLine: String? {
        let parts = [video.viewCount, video.publishedAt].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showMetadata ? GridConstants.metadataSpacing(for: size) : 0) {
            // Thumbnail with duration badge
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(videoId: video.id, thumbnailUrl: video.thumbnailUrl, cacheDir: cacheDir)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .scaleEffect(isHovering ? GridConstants.hoverScaleEffect : 1.0)

                if let stateTag = video.stateTag {
                    VStack {
                        HStack {
                            Text(stateTag)
                                .font(GridConstants.metadataFont(for: size).weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.92), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(GridConstants.durationPadding(for: size))
                }

                if let duration = video.duration {
                    Text(duration)
                        .font(.system(size: GridConstants.durationFontSize(for: size), weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: GridConstants.durationBadgeCornerRadius))
                        .padding(GridConstants.durationPadding(for: size))
                }
            }

            if showMetadata {
                HStack(alignment: .top, spacing: GridConstants.channelSpacing(for: size)) {
                    channelIconView
                        .frame(width: GridConstants.channelIconSize(for: size), height: GridConstants.channelIconSize(for: size))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        HighlightedText(video.title, terms: highlightTerms)
                            .font(GridConstants.titleFont(for: size))
                            .lineLimit(2)

                        if let channel = video.channelName {
                            HighlightedText(channel, terms: highlightTerms)
                                .font(GridConstants.channelFont(for: size))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let meta = metadataLine {
                            Text(meta)
                                .font(GridConstants.metadataFont(for: size))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            } else if forceShowTitle {
                HighlightedText(video.title, terms: highlightTerms)
                    .font(GridConstants.titleFont(for: size))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(showMetadata ? cardPadding : 2)
        .background(
            RoundedRectangle(cornerRadius: showMetadata ? cornerRadius + 6 : cornerRadius + 2, style: .continuous)
                .fill(Color.white.opacity(isHovering || isSelected ? GridConstants.hoverBackgroundOpacity : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: showMetadata ? cornerRadius + 6 : cornerRadius + 2, style: .continuous)
                .stroke(Color.accentColor, lineWidth: isSelected ? GridConstants.selectionBorderWidth : 0)
        )
        .help(video.title)
    }

    @ViewBuilder
    private var channelIconView: some View {
        if let iconUrl = video.channelIconUrl {
            AsyncImage(url: iconUrl) { phase in
                if case .success(let image) = phase {
                    image.resizable()
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
        }
    }
}
