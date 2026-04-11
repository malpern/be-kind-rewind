import AppKit
import SwiftUI

/// Reusable channel-icon view that prefers a locally cached `iconData` blob
/// over a network fetch. Pass the blob (typically pulled from
/// `OrganizerStore.knownChannelsById[id]?.iconData`) and the source URL as a
/// fallback. When neither is available the placeholder is shown.
///
/// This is the offline-first counterpart for channel icons that the rest of
/// the codebase uses for video thumbnails via `ThumbnailView`. Without it,
/// every channel-avatar render goes straight to the YouTube CDN, which makes
/// half the UI go blank when the network is off even though the bytes are
/// already in SQLite.
struct ChannelIconView: View {
    let iconData: Data?
    let fallbackUrl: URL?

    var body: some View {
        if let iconData, let nsImage = NSImage(data: iconData) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let url = fallbackUrl {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(.tertiary)
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
        }
    }
}

/// Reusable thumbnail view that checks disk cache first, then falls back to AsyncImage.
struct ThumbnailView: View {
    let videoId: String
    let thumbnailUrl: URL?
    let cacheDir: URL

    var body: some View {
        let path = cacheDir.appendingPathComponent("\(videoId).jpg")
        if FileManager.default.fileExists(atPath: path.path),
           let nsImage = NSImage(contentsOf: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
        } else if let url = thumbnailUrl {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                case .failure:
                    thumbnailPlaceholder
                default:
                    thumbnailPlaceholder
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
        } else {
            thumbnailPlaceholder
        }
    }

    private var thumbnailPlaceholder: some View {
        Color(nsColor: .quaternaryLabelColor)
            .aspectRatio(16/9, contentMode: .fit)
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}
