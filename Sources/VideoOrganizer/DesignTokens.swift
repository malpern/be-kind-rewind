import SwiftUI

/// Phase 3 sizing recalibration. Centralizes type and spacing tokens so we
/// stop scattering raw `.font(.caption2)` / `.controlSize(.small)` /
/// `.padding(4)` calls across the app — those are the leading causes of
/// "tiny and fiddly" feel on macOS.
///
/// **Sizing rationale (anchored to NetNewsWire + Apple HIG):**
///
/// - macOS `NSFont.systemFontSize` is **13 pt**. SwiftUI `Font` styles on
///   macOS are derived from this anchor: `.body = 13`, `.subheadline = 11`,
///   `.footnote = 9`, `.caption = 8`, `.caption2 = 7`. iOS values are
///   completely different (body = 17), which is why so many SwiftUI tutorials
///   produce "tiny" Mac apps when their authors copy iOS sizes.
/// - NetNewsWire — the gold-standard polished native macOS reader — uses
///   13 pt across the sidebar (SidebarCellAppearance.swift) and 14 pt
///   semibold for timeline titles (TimelineCellAppearance.swift). It NEVER
///   goes below 11 pt anywhere, including for date stamps and bylines. It
///   uses **8 pt vertical row padding** as the minimum
///   (`TimelineCellAppearance.cellPadding`).
/// - The Mac app's article body CSS sets **16 px** with 1.6 line-height for
///   long-form reading, with 48 px horizontal gutters (`stylesheet.css`).
/// - OpenAI's Codex Mac app uses ~13 pt body throughout but achieves a
///   "spacious" feel through generous internal padding on interactive
///   elements (16-20 pt around the input field) and aggressive restraint
///   on hierarchy (effectively 2 type sizes — body and a single H1).
///
/// **Anti-patterns this file exists to eliminate:**
///
/// - `.font(.caption)` / `.caption2` / `.footnote` for metadata. On macOS
///   these are 8/7/9 pt and they look "tiny and fiddly". Use `appMetadata`
///   (11 pt secondary) instead.
/// - `.controlSize(.small)` on toolbar items, primary actions, and most
///   buttons. NNW uses stock `NSToolbar` at `.regular`. Reserve `.small`
///   for dense table cells only.
/// - `.padding(4)` around interactive controls. Use `Spacing.s` (8) at
///   minimum for any tappable row.
///
/// View modifiers below are the canonical way to apply these. Use them
/// instead of raw `.font` / `.foregroundStyle` calls so a future tweak
/// to the design system propagates automatically.
enum Typography {
    /// Primary text in lists and rows. The default for any user-readable
    /// content that should look "normal weight, normal color".
    static let primary: Font = .body

    /// Secondary text — bylines, subtitles, supporting context. Pair with
    /// `.foregroundStyle(.secondary)` (the `appSecondary` modifier handles
    /// both for you).
    static let secondary: Font = .subheadline

    /// Metadata, timestamps, counts, status hints. Same size as `secondary`
    /// — we use this name when the content is structured info, not prose.
    /// Pair with `.foregroundStyle(.secondary)`.
    static let metadata: Font = .subheadline

    /// Headers above grouped content (section titles within a page).
    /// Lean on weight, not size, for hierarchy — `.headline` is the
    /// system 13 pt semibold which reads as a header without overwhelming.
    static let sectionHeader: Font = .headline

    /// Page-level title. Used for the title of the current page or pane,
    /// e.g. "Channel information", "All videos", a creator's name. Slightly
    /// larger than body for visual hierarchy without becoming a marketing
    /// headline.
    static let pageTitle: Font = .title3

    /// Hero title for the very top of a detail page. Roughly 1.85× body,
    /// matching NetNewsWire's article H1 ratio.
    static let heroTitle: Font = .title

    /// Body text in long-form reading content (about paragraphs, notes,
    /// descriptions). Larger than `primary` because reading paragraphs is
    /// fundamentally different from scanning rows. Mirrors NetNewsWire's
    /// 16 px article body CSS.
    static let readingBody: Font = .system(size: 15)
}

/// Standard spacing tokens. Apple's macOS HIG and NetNewsWire's source both
/// align to a 4-pt grid. Use these instead of magic numbers so the visual
/// rhythm is consistent across the app.
enum Spacing {
    /// 4 pt — only between paired icon + label, never around hit targets.
    static let xs: CGFloat = 4
    /// 8 pt — minimum vertical padding for any interactive row.
    static let s: CGFloat = 8
    /// 12 pt — comfortable horizontal padding inside a row.
    static let m: CGFloat = 12
    /// 16 pt — group container padding.
    static let l: CGFloat = 16
    /// 20 pt — section separator, page-level content inset.
    static let xl: CGFloat = 20
    /// 32 pt — large-scale rhythm (page top padding, hero margins).
    static let xxl: CGFloat = 32
}

extension View {
    /// Apply the primary text treatment: 13 pt body, default foreground.
    /// Use for the main user-facing text in any list row, card, or pane.
    func appPrimary() -> some View {
        self.font(Typography.primary)
    }

    /// Apply the secondary text treatment: 11 pt subheadline + secondary
    /// foreground. Use for subtitles, bylines, supporting context.
    func appSecondary() -> some View {
        self.font(Typography.secondary)
            .foregroundStyle(.secondary)
    }

    /// Apply the metadata treatment: 11 pt subheadline + secondary
    /// foreground. Same visual treatment as `appSecondary` but the name
    /// signals "this is structured info" (counts, timestamps, status
    /// chips, etc.) rather than prose.
    func appMetadata() -> some View {
        self.font(Typography.metadata)
            .foregroundStyle(.secondary)
    }

    /// Apply the section-header treatment: 13 pt semibold (`.headline`).
    /// Use for the title above a grouped block of content within a page.
    /// Hierarchy is conveyed by weight, not size.
    func appSectionHeader() -> some View {
        self.font(Typography.sectionHeader)
    }

    /// Apply the page-title treatment: `.title3` (16 pt). Use for the
    /// title of the current page or pane.
    func appPageTitle() -> some View {
        self.font(Typography.pageTitle)
    }

    /// Apply the hero-title treatment: `.title` (24 pt). Use for the very
    /// top headline of a detail page (e.g. a creator's name).
    func appHeroTitle() -> some View {
        self.font(Typography.heroTitle)
    }

    /// Apply the reading-body treatment: 15 pt with comfortable line
    /// spacing. Use for long-form paragraph content (descriptions, about
    /// text, notes) — never for scannable list rows.
    func appReadingBody() -> some View {
        self.font(Typography.readingBody)
            .lineSpacing(4)
    }
}
