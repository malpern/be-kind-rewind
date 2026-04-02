import SwiftUI

/// Maps topic names to SF Symbol icons and colors.
enum TopicTheme {
    struct Theme {
        let icon: String
        let color: Color
    }

    private static let themes: [(keywords: [String], theme: Theme)] = [
        (["keyboard"], Theme(icon: "keyboard", color: .purple)),
        (["claude", "anthropic"], Theme(icon: "brain", color: .orange)),
        (["ai", "agent", "llm"], Theme(icon: "cpu", color: .blue)),
        (["vim", "terminal"], Theme(icon: "terminal", color: .green)),
        (["swift", "ios"], Theme(icon: "swift", color: .orange)),
        (["mac", "apple"], Theme(icon: "desktopcomputer", color: .gray)),
        (["web"], Theme(icon: "globe", color: .cyan)),
        (["embedded", "electronic", "pcb"], Theme(icon: "chip", color: .yellow)),
        (["linux", "devops"], Theme(icon: "server.rack", color: .secondary)),
        (["retro", "vintage"], Theme(icon: "clock.arrow.trianglehead.counterclockwise.rotate.90", color: .brown)),
        (["3d print"], Theme(icon: "cube", color: .secondary)),
        (["home auto"], Theme(icon: "house", color: .secondary)),
        (["geopolit", "current event"], Theme(icon: "globe.americas", color: .secondary)),
        (["finance", "retire"], Theme(icon: "chart.line.uptrend.xyaxis", color: .green)),
        (["health", "lifestyle"], Theme(icon: "heart", color: .red)),
        (["entertainment", "pop culture"], Theme(icon: "film", color: .pink)),
        (["productiv", "creative", "learning"], Theme(icon: "lightbulb", color: .secondary)),
        (["personal growth", "philosophy"], Theme(icon: "person.fill", color: .secondary)),
        (["programming", "software"], Theme(icon: "chevron.left.forwardslash.chevron.right", color: .secondary)),
        (["tech", "gadget"], Theme(icon: "wrench.and.screwdriver", color: .secondary)),
        (["cursor", "ide", "coding tool"], Theme(icon: "hammer", color: .secondary)),
    ]

    private static let defaultTheme = Theme(icon: "folder", color: .secondary)

    static func theme(for topicName: String) -> Theme {
        let lower = topicName.lowercased()
        for entry in themes {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                return entry.theme
            }
        }
        return defaultTheme
    }

    static func iconName(for topicName: String) -> String {
        theme(for: topicName).icon
    }

    static func iconColor(for topicName: String) -> Color {
        theme(for: topicName).color
    }
}
