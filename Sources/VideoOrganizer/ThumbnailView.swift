import SwiftUI

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
