import SwiftUI
import AppKit

struct AboutView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(red: 0.95, green: 0.92, blue: 0.86)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 28, y: 18)
                .padding(36)
                .overlay {
                    HStack(spacing: 40) {
                        artwork
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        details
                            .frame(width: 290, alignment: .leading)
                    }
                    .padding(40)
                }
        }
        .frame(width: 860, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(AboutWindowConfigurator(size: NSSize(width: 860, height: 620)))
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = Bundle.module.url(forResource: "app-icon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(22)

                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 420, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 26, y: 16)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Be Kind, Rewind")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("Video Organizer")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Label("Version 0.1.0", systemImage: "play.rectangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quinary, in: Capsule())

            Text("Organize your YouTube video library by topic. Like sorting your VHS collection, but with AI.")
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                aboutPoint("Topic-first browsing", systemImage: "square.grid.2x2")
                aboutPoint("Creator-aware sections", systemImage: "person.2")
                aboutPoint("Fast triage for long video lists", systemImage: "sparkles")
            }

            Spacer()

            Link(destination: URL(string: "https://github.com/malpern/be-kind-rewind")!) {
                HStack(spacing: 8) {
                    Text("View Source")
                    Image(systemName: "arrow.up.right")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func aboutPoint(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AboutWindowConfigurator: NSViewRepresentable {
    let size: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setContentSize(size)
            window.center()
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.setContentSize(size)
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
    }
}
