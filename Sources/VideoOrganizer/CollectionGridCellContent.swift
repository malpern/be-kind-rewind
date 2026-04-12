// CollectionGridCellContent.swift
//
// SwiftUI content views hosted inside NSCollectionView cells and section headers.
// Extracted from CollectionGridView.swift for maintainability.

import AppKit
import SwiftUI
import TaggingKit

// MARK: - Video Cell SwiftUI Content

struct VideoCellContent: View {
    let video: VideoGridItemModel
    let cacheDir: URL
    let thumbnailSize: Double
    let showMetadata: Bool
    let isSelected: Bool
    var highlightTerms: [String] = []

    private var cornerRadius: CGFloat { GridConstants.cornerRadius(for: thumbnailSize) }
    private var metadataLine: String? {
        let displayDate = video.publishedAt.map { VideoViewModel.formatPublishedAtForDisplay($0) }
        let parts = [video.viewCount, displayDate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showMetadata ? GridConstants.metadataSpacing(for: thumbnailSize) : 2) {
            if video.isPlaceholder {
                placeholderCard
            } else {
                standardCard
            }
        }
        .padding(showMetadata ? GridConstants.cardPadding(for: thumbnailSize) : 2)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                .fill(Color.white.opacity(isSelected ? GridConstants.hoverBackgroundOpacity : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                .stroke(Color.accentColor, lineWidth: isSelected ? GridConstants.selectionBorderWidth : 0)
        )
    }

    private var standardCard: some View {
        Group {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(videoId: video.id, thumbnailUrl: video.thumbnailUrl, cacheDir: cacheDir)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

                if let stateTag = video.stateTag {
                    VStack {
                        HStack {
                            Text(stateTag)
                                .font(GridConstants.metadataFont(for: thumbnailSize).weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.92), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(GridConstants.durationPadding(for: thumbnailSize))
                }

                if let duration = video.duration {
                    Text(duration)
                        .font(.system(size: GridConstants.durationFontSize(for: thumbnailSize), weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: GridConstants.durationBadgeCornerRadius))
                        .padding(GridConstants.durationPadding(for: thumbnailSize))
                }
            }

            if showMetadata {
                Text(video.title)
                    .font(GridConstants.titleFont(for: thumbnailSize))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                if let channel = video.channelName {
                    Text(channel)
                        .font(GridConstants.channelFont(for: thumbnailSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let metadataLine {
                    Text(metadataLine)
                        .font(GridConstants.metadataFont(for: thumbnailSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else if !highlightTerms.isEmpty {
                HighlightedText(video.title, terms: highlightTerms)
                    .font(GridConstants.titleFont(for: thumbnailSize))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
    }

    private var placeholderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [8, 6]))
                        .foregroundStyle(Color.accentColor.opacity(0.35))
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text("Watch")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)

            Text(video.title)
                .font(GridConstants.titleFont(for: thumbnailSize))
                .foregroundStyle(.primary)

            if let message = video.placeholderMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Section Header SwiftUI Content

struct SectionHeaderContent: View {
    let model: CollectionSectionHeaderModel

    var body: some View {
        switch model {
        case let .topic(name, count, totalCount, topicId, scrollProgress, highlightTerms, displayMode, channels, selectedChannelId, videoCountForChannel, hasRecentContent, latestPublishedAtForChannel, themeLabelsForChannel, subscriberCountForChannel, onSelectChannel, onOpenCreatorDetail):
            VStack(spacing: 0) {
                SectionHeaderView(
                    name: name,
                    count: count,
                    totalCount: totalCount,
                    topicId: topicId,
                    progress: scrollProgress,
                    showProgress: displayMode != .watchCandidates,
                    highlightTerms: highlightTerms
                )
                .accessibilityIdentifier("topic-\(topicId)")

                if !channels.isEmpty {
                    CreatorCirclesBar(
                        channels: channels,
                        selectedChannelId: selectedChannelId,
                        topicId: topicId,
                        collapseLowCountCreators: displayMode != .watchCandidates,
                        prioritizeRecency: displayMode == .watchCandidates,
                        videoCountForChannel: videoCountForChannel,
                        hasRecentContent: hasRecentContent,
                        latestPublishedAtForChannel: latestPublishedAtForChannel,
                        onSelect: onSelectChannel,
                        onOpenDetail: onOpenCreatorDetail,
                        themeLabelsForChannel: themeLabelsForChannel,
                        subscriberCountForChannel: subscriberCountForChannel
                    )
                }
            }
        case let .creator(channelName, channelIconUrl, channelIconData, channelUrl, count, totalCount, topicNames, sectionId, scrollProgress, highlightTerms, onInspect):
            CreatorSectionHeaderView(
                channelName: channelName,
                channelIconUrl: channelIconUrl,
                channelIconData: channelIconData,
                channelUrl: channelUrl,
                count: count,
                totalCount: totalCount,
                topicNames: topicNames,
                sectionId: sectionId,
                progress: scrollProgress,
                highlightTerms: highlightTerms
            )
            .onTapGesture(perform: onInspect)
            .contextMenu {
                if let channelUrl {
                    Button("Open Channel on YouTube") {
                        NSWorkspace.shared.open(channelUrl)
                    }
                }
            }
        }
    }
}
