import SwiftUI

/// Keyboard shortcut cheat sheet shown via Help → Keyboard Shortcuts (⌘/).
/// Lists all grid navigation, video actions, and app-level shortcuts in a
/// compact two-column layout.
struct KeyboardShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    shortcutSection("Navigation") {
                        shortcutRow("h  j  k  l", "Move selection (vim)")
                        shortcutRow("← ↓ ↑ →", "Move selection (arrows)")
                        shortcutRow("Space", "Open video on YouTube")
                        shortcutRow("Return", "Open video on YouTube")
                        shortcutRow("Esc", "Clear selection")
                    }

                    shortcutSection("Video Actions") {
                        shortcutRow("w", "Save to Watch Later")
                        shortcutRow("p", "Save to Playlist…")
                        shortcutRow("⇧P", "Move to Playlist…")
                        shortcutRow("d", "Dismiss (Watch mode)")
                        shortcutRow("n", "Not Interested (Watch mode)")
                    }

                    shortcutSection("App") {
                        shortcutRow("⌘F", "Search")
                        shortcutRow("⌘K", "Quick Navigator")
                        shortcutRow("⌘,", "Settings")
                        shortcutRow("⌘/", "This cheat sheet")
                    }

                    shortcutSection("Creator Detail Page") {
                        shortcutRow("⌘1", "Identity")
                        shortcutRow("⌘2", "What's New")
                        shortcutRow("⌘3", "Hits")
                        shortcutRow("⌘4", "All Videos")
                        shortcutRow("⌘5", "Playlists")
                        shortcutRow("⌘6", "Leaderboard")
                        shortcutRow("⌘7", "Notes")
                        shortcutRow("⌘8", "Channel Info")
                    }

                    shortcutSection("View") {
                        shortcutRow("⌘1", "Saved mode")
                        shortcutRow("⌘2", "Watch mode")
                        shortcutRow("⌘⇧I", "Toggle Inspector")
                        shortcutRow("⌘⇧L", "Toggle log viewer")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 420, height: 520)
    }

    @ViewBuilder
    private func shortcutSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func shortcutRow(_ keys: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(keys)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 100, alignment: .trailing)
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
