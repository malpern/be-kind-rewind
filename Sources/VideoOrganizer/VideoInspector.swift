import SwiftUI

struct VideoInspector: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache

    private var video: VideoViewModel? { store.inspectedVideo }
    private var isSelected: Bool { store.selectedVideoId == store.inspectedVideoId }

    var body: some View {
        Group {
            if let video {
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
                // Large thumbnail
                thumbnailView(for: video)
                    .aspectRatio(16/9, contentMode: .fit)

                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    HighlightedText(video.title, terms: store.parsedQuery.includeTerms)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)

                    // Channel
                    if let channel = video.channelName {
                        HStack(spacing: 10) {
                            if let iconUrl = video.channelIconUrl.flatMap({ URL(string: $0) }) {
                                AsyncImage(url: iconUrl) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable()
                                    } else {
                                        channelIconPlaceholder
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

                    // Metadata
                    metadataGrid(video)

                    // Actions (only for selected video)
                    if isSelected {
                        Divider()
                        actionButtons(video)
                    }

                    // More from this channel
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
                if let url = URL(string: "https://www.youtube.com/watch?v=\(video.videoId)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open on YouTube", systemImage: "play.rectangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://www.youtube.com/watch?v=\(video.videoId)", forType: .string)
            } label: {
                Label("Copy Link", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
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
                        relatedThumbnail(for: v)
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

    // MARK: - Thumbnails

    @ViewBuilder
    private func thumbnailView(for video: VideoViewModel) -> some View {
        let path = thumbnailCache.cacheDirURL.appendingPathComponent("\(video.videoId).jpg")
        if FileManager.default.fileExists(atPath: path.path),
           let nsImage = NSImage(contentsOf: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
        } else if let url = video.thumbnailUrl {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(16/9, contentMode: .fill)
                } else {
                    thumbnailPlaceholder
                }
            }
        } else {
            thumbnailPlaceholder
        }
    }

    @ViewBuilder
    private func relatedThumbnail(for video: VideoViewModel) -> some View {
        let path = thumbnailCache.cacheDirURL.appendingPathComponent("\(video.videoId).jpg")
        if FileManager.default.fileExists(atPath: path.path),
           let nsImage = NSImage(contentsOf: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
        } else {
            Color(nsColor: .quaternaryLabelColor)
        }
    }

    private var thumbnailPlaceholder: some View {
        Color(nsColor: .quaternaryLabelColor)
            .aspectRatio(16/9, contentMode: .fit)
    }

    private var channelIconPlaceholder: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .foregroundStyle(.tertiary)
    }
}
