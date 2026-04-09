import SwiftUI

@MainActor
@Observable
/// Observable state for the brief toast banner shown after actions like "Saved to Watch Later".
final class ActionToastState {
    var message: String = ""
    var icon: String = ""
    var isVisible: Bool = false
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, icon: String) {
        hideTask?.cancel()
        self.message = message
        self.icon = icon
        withAnimation(.easeOut(duration: 0.15)) {
            isVisible = true
        }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                isVisible = false
            }
        }
    }
}

struct ActionToast: View {
    let state: ActionToastState

    var body: some View {
        if state.isVisible {
            HStack(spacing: 8) {
                Image(systemName: state.icon)
                    .font(.title3.weight(.medium))
                Text(state.message)
                    .font(.title3.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .allowsHitTesting(false)
        }
    }
}
