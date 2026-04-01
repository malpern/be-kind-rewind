import SwiftUI

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            // Left: app icon taking full height
            if let url = Bundle.module.url(forResource: "splash-image", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 320, height: 320)
                    .clipped()
            }

            // Right: app info
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Be Kind, Rewind")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Video Organizer")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.5))

                    Text("Version 0.1.0")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("\u{00A9} 2026 Micah Alpern")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 540, height: 320)
        .background(Color.black)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                appeared = true
            }
        }
    }
}
