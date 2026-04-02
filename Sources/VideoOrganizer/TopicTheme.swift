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
        (["mcp", "agent", "automation"], Theme(icon: "cpu", color: .blue)),
        (["cursor", "ide", "vibe coding", "coding tool"], Theme(icon: "hammer", color: .indigo)),
        (["ai model", "ai research", "industry trend"], Theme(icon: "sparkles", color: .blue)),
        (["ai"], Theme(icon: "cpu", color: .blue)),
        (["vim", "terminal", "neovim"], Theme(icon: "terminal", color: .green)),
        (["swift", "ios", "swiftui"], Theme(icon: "swift", color: .orange)),
        (["mac", "apple", "wwdc", "xcode"], Theme(icon: "desktopcomputer", color: .gray)),
        (["web", "frontend", "backend", "css", "figma"], Theme(icon: "globe", color: .cyan)),
        (["embedded", "electronic", "pcb", "arduino", "raspberry", "esp32", "microcontroller", "fpga"], Theme(icon: "chip", color: .yellow)),
        (["linux", "devops", "docker", "homelab"], Theme(icon: "server.rack", color: .teal)),
        (["retro", "vintage", "classic mac", "apple ii"], Theme(icon: "clock.arrow.trianglehead.counterclockwise.rotate.90", color: .brown)),
        (["3d print", "modeling software"], Theme(icon: "cube", color: .mint)),
        (["home auto", "smart home", "home assistant"], Theme(icon: "house", color: .cyan)),
        (["geopolit", "current event", "politics", "intelligence", "espionage"], Theme(icon: "globe.americas", color: .red)),
        (["finance", "retire", "investing", "fire", "budget"], Theme(icon: "chart.line.uptrend.xyaxis", color: .green)),
        (["health", "lifestyle", "fitness", "nutrition", "longevity", "diet", "exercise"], Theme(icon: "heart", color: .red)),
        (["entertainment", "pop culture", "movie", "tv show", "star trek", "comedy", "film"], Theme(icon: "film", color: .pink)),
        (["productiv", "creative", "learning", "note-taking", "pkm"], Theme(icon: "lightbulb", color: .yellow)),
        (["personal growth", "philosophy", "mindset", "psychology", "career"], Theme(icon: "person.fill", color: .purple)),
        (["programming", "software", "python", "algorithm", "cs fundamental"], Theme(icon: "chevron.left.forwardslash.chevron.right", color: .teal)),
        (["tech", "gadget", "hardware", "networking"], Theme(icon: "wrench.and.screwdriver", color: .gray)),
        (["shell", "cli", "git"], Theme(icon: "apple.terminal", color: .green)),
        (["design", "ui", "ux"], Theme(icon: "paintbrush", color: .pink)),
        (["camera", "photo", "video"], Theme(icon: "camera", color: .secondary)),
        (["music", "art"], Theme(icon: "music.note", color: .pink)),
        (["food", "cooking", "recipe"], Theme(icon: "fork.knife", color: .orange)),
        (["gaming", "game"], Theme(icon: "gamecontroller", color: .indigo)),
        (["robot", "computer vision"], Theme(icon: "gearshape.2", color: .secondary)),
        (["diy", "build", "project", "maker"], Theme(icon: "wrench", color: .orange)),
        (["soldering", "assembly"], Theme(icon: "flame", color: .orange)),
        (["tutorial", "guide", "beginner", "course"], Theme(icon: "book", color: .blue)),
        (["review", "comparison"], Theme(icon: "star", color: .yellow)),
        (["podcast", "interview"], Theme(icon: "mic", color: .purple)),
        (["indie dev", "app business"], Theme(icon: "storefront", color: .green)),
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
