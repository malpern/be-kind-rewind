import SwiftUI

/// Phase 1 commit #5 placeholder. The real `CreatorDetailView` arrives in commit #6;
/// this view exists only so the `NavigationStack` wiring (path, destination, sidebar
/// auto-collapse) can be verified in isolation before any UI work begins. Replaced
/// in the next commit.
struct CreatorDetailPagePlaceholder: View {
    let channelId: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Creator detail page")
                .font(.title2.weight(.semibold))
            Text("channelId: \(channelId)")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            Text("Phase 1 commit #6 will replace this placeholder with the real CreatorDetailView.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .navigationTitle("Creator")
    }
}
