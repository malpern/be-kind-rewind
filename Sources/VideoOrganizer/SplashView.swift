import SwiftUI

/// Inline loading state shown in the main window while the database initializes.
struct InlineLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            if let url = Bundle.module.url(forResource: "app-icon", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }

            Text("Be Kind, Rewind")
                .font(.title2.weight(.semibold))

            ProgressView()
                .controlSize(.small)

            Text("Loading library…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
