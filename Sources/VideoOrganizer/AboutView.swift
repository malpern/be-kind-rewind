import SwiftUI
import AppKit

struct AboutView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            artwork
            details
            footer
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 36)
        .frame(width: 620, height: 730)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(AboutWindowConfigurator(size: NSSize(width: 620, height: 730)))
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = Bundle.module.url(forResource: "app-icon-about-clean", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            VStack(spacing: 0) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 360, height: 360)
                    .scaleEffect(1.12)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        }
    }

    private var details: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Be Kind, Rewind")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
            }

            Label("Version 0.1.0", systemImage: "play.rectangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quinary, in: Capsule())

            Text("Organize your YouTube video library by topic. Like sorting your VHS collection, but with AI.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                aboutPoint("Topic-first browsing", systemImage: "square.grid.2x2")
                aboutPoint("Creator-aware sections", systemImage: "person.2")
                aboutPoint("Fast triage", systemImage: "sparkles")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()

            HStack {
                Text("A topic-first desktop organizer for large YouTube libraries.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                Spacer()

                Link(destination: URL(string: "https://github.com/malpern/be-kind-rewind")!) {
                    Label("View Source", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.link)
            }
        }
    }

    private func aboutPoint(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quinary, in: Capsule())
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
