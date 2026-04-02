import SwiftUI

struct VideoInspector: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache

    private var video: VideoViewModel? { store.inspectedVideo }
    private var isSelected: Bool { store.selectedVideoId == store.inspectedVideoId }

    var body: some View {
        Group {
            if let creatorName = store.inspectedCreatorName {
                creatorInspectorContent(store.creatorDetail(channelName: creatorName))
            } else if let video {
                inspectorContent(video)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.and.hand.point.up.left")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select a video")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    private func inspectorContent(_ video: VideoViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ThumbnailView(videoId: video.videoId, thumbnailUrl: video.thumbnailUrl, cacheDir: thumbnailCache.cacheDirURL)
                    .aspectRatio(16/9, contentMode: .fit)

                VStack(alignment: .leading, spacing: 16) {
                    HighlightedText(video.title, terms: store.parsedQuery.includeTerms)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)

                    if let channel = video.channelName {
                        HStack(spacing: 10) {
                            if let iconUrl = video.channelIconUrl.flatMap({ URL(string: $0) }) {
                                AsyncImage(url: iconUrl) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable()
                                    } else {
                                        Image(systemName: "person.circle.fill")
                                            .resizable()
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())
                            }
                            HighlightedText(channel, terms: store.parsedQuery.includeTerms)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    metadataGrid(video)

                    if isSelected {
                        Divider()
                        actionButtons(video)
                    }

                    let moreVideos = store.moreFromChannel(videoId: video.videoId)
                    if !moreVideos.isEmpty {
                        Divider()
                        moreFromChannel(moreVideos, channelName: video.channelName)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Metadata Grid

    private func metadataGrid(_ video: VideoViewModel) -> some View {
        Grid(alignment: .leading, verticalSpacing: 10) {
            if let views = video.viewCount {
                metadataRow(icon: "eye", label: "Views", value: views)
            }
            if let date = video.publishedAt {
                metadataRow(icon: "calendar", label: "Published", value: date)
            }
            if let duration = video.duration {
                metadataRow(icon: "clock", label: "Duration", value: duration, mono: true)
            }
            if let topic = store.topicNameForVideo(video.videoId) {
                metadataRow(icon: "folder", label: "Topic", value: topic)
            }
        }
    }

    @ViewBuilder
    private func metadataRow(icon: String, label: String, value: String, mono: Bool = false) -> some View {
        GridRow {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 85, alignment: .leading)
            Text(value)
                .font(mono ? .callout.monospacedDigit() : .callout)
        }
    }

    // MARK: - Actions

    private func actionButtons(_ video: VideoViewModel) -> some View {
        VStack(spacing: 8) {
            Button {
                if let url = video.youtubeUrl {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open on YouTube", systemImage: "play.rectangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help("Open this video on YouTube")

            Button {
                if let url = video.youtubeUrl {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            } label: {
                Label("Copy Link", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .help("Copy YouTube link to clipboard")
        }
    }

    // MARK: - Creator Detail

    private func creatorInspectorContent(_ detail: CreatorDetailViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Large channel icon
                HStack {
                    Spacer()
                    creatorIcon(detail)
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                    Spacer()
                }
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 16) {
                    // Name + tier
                    VStack(spacing: 4) {
                        Text(detail.channelName)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)

                        if let subs = detail.formattedSubscribers, let tier = detail.subscriberTier {
                            Text("\(subs) · \(tier)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    Divider()

                    // Stats
                    Grid(alignment: .leading, verticalSpacing: 10) {
                        metadataRow(icon: "video", label: "Saved", value: "\(detail.totalVideoCount) videos")
                        if let coverage = detail.coverageText {
                            metadataRow(icon: "chart.pie", label: "Coverage", value: coverage)
                        }
                        if detail.totalViews > 0 {
                            metadataRow(icon: "eye", label: "Views", value: detail.formattedViews)
                        }
                        if let velocity = detail.velocityText {
                            metadataRow(icon: "bolt", label: "Recent", value: velocity)
                        }
                        if let newest = detail.newestAge {
                            metadataRow(icon: "calendar", label: "Newest", value: newest)
                        }
                        if let oldest = detail.oldestAge {
                            metadataRow(icon: "calendar.badge.clock", label: "Oldest", value: oldest)
                        }
                    }

                    Divider()

                    // Topic breakdown
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Topics")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(detail.videosByTopic, id: \.topicName) { entry in
                            HStack {
                                Image(systemName: TopicTheme.iconName(for: entry.topicName))
                                    .font(.caption)
                                    .foregroundStyle(TopicTheme.iconColor(for: entry.topicName))
                                    .frame(width: 20)
                                Text(entry.topicName)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(entry.videos.count)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func creatorIcon(_ detail: CreatorDetailViewModel) -> some View {
        if let data = detail.channelIconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let urlString = detail.channelIconUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    creatorPlaceholder(detail.channelName)
                }
            }
        } else {
            creatorPlaceholder(detail.channelName)
        }
    }

    private func creatorPlaceholder(_ name: String) -> some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.15))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - More from Channel

    private func moreFromChannel(_ videos: [VideoViewModel], channelName: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("More from \(channelName ?? "this channel")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(videos, id: \.videoId) { v in
                Button {
                    store.selectedVideoId = v.videoId
                } label: {
                    HStack(spacing: 10) {
                        ThumbnailView(videoId: v.videoId, thumbnailUrl: v.thumbnailUrl, cacheDir: thumbnailCache.cacheDirURL)
                            .frame(width: 80, height: 45)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                            if let meta = [v.viewCount, v.publishedAt].compactMap({ $0 }).joined(separator: " · ") as String?,
                               !meta.isEmpty {
                                Text(meta)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
