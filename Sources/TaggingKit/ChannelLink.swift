import Foundation

/// One external link surfaced from a creator's YouTube channel description.
/// Populated by `youtube_channel_about.py` which extracts URLs from the
/// channel home page's og:description meta tag and maps them to friendly
/// titles via a curated platform-rules list (GitHub, Twitter/X, etc.).
public struct ChannelLink: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }

    /// SF Symbol name to render alongside the title in the link button. Maps
    /// well-known platforms to their best-fit icon; otherwise returns a
    /// generic link symbol so unknown URLs still get a recognizable affordance.
    public var symbolName: String {
        let lower = url.lowercased()
        if lower.contains("github.com") { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("twitter.com") || lower.contains("x.com") { return "bird" }
        if lower.contains("instagram.com") { return "camera" }
        if lower.contains("tiktok.com") { return "music.note" }
        if lower.contains("linkedin.com") { return "person.crop.rectangle" }
        if lower.contains("threads.net") { return "at" }
        if lower.contains("bsky.app") { return "cloud" }
        if lower.contains("mastodon") { return "at" }
        if lower.contains("discord.") { return "bubble.left.and.bubble.right" }
        if lower.contains("patreon.com") { return "heart.circle" }
        if lower.contains("ko-fi.com") || lower.contains("buymeacoffee.com") { return "cup.and.saucer" }
        if lower.contains("substack.com") { return "newspaper" }
        if lower.contains("medium.com") { return "doc.text" }
        if lower.contains("twitch.tv") { return "tv" }
        if lower.contains("amazon.") || lower.contains("amzn.") { return "cart" }
        if lower.contains("podcasts.apple.com") || lower.contains("open.spotify.com") { return "headphones" }
        return "link"
    }
}
