import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            if let url = Bundle.module.url(forResource: "app-icon", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            }

            VStack(spacing: 6) {
                Text("Be Kind, Rewind")
                    .font(.title.bold())

                Text("Video Organizer")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("Version 0.1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("Organize your YouTube video library by topic.\nLike sorting your VHS collection, but with AI.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Link("GitHub Repository", destination: URL(string: "https://github.com/malpern/be-kind-rewind")!)
                .font(.caption)
        }
        .padding(32)
        .frame(width: 400, height: 480)
    }
}
