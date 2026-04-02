import SwiftUI

/// Centralized constants for the video grid layout.
enum GridConstants {
    // MARK: - Thumbnail Size Thresholds
    static let smallThreshold: Double = 160
    static let mediumThreshold: Double = 220
    static let largeThreshold: Double = 300

    // MARK: - Grid Spacing
    static let metadataGridSpacing: CGFloat = 16
    static let compactGridSpacing: CGFloat = 4
    static let gridMaxThumbnailDelta: Double = 60
    static let horizontalPadding: CGFloat = 20
    static let sectionBottomPadding: CGFloat = 24
    static let columnSpacingEstimate: Double = 16
    static let containerPaddingEstimate: CGFloat = 40

    // MARK: - Card
    static let hoverBackgroundOpacity: Double = 0.08
    static let hoverScaleEffect: CGFloat = 1.01
    static let selectionBorderWidth: CGFloat = 2
    static let durationBadgeCornerRadius: CGFloat = 3

    // MARK: - Hover Timing
    static let hoverDebounceMs: Int = 80
    static let hoverFadeOutDuration: Double = 0.2

    // MARK: - Progress Bar
    static let progressBarHeight: CGFloat = 3
    static let progressAnimationDuration: Double = 0.15

    // MARK: - Page Navigation
    static let pageJumpRows = 4

    // MARK: - Size-Dependent Values

    static func titleFont(for size: Double) -> Font {
        if size < smallThreshold { return .system(size: 9, weight: .medium) }
        if size < mediumThreshold { return .caption.weight(.medium) }
        if size < largeThreshold { return .subheadline.weight(.medium) }
        return .body.weight(.medium)
    }

    static func channelFont(for size: Double) -> Font {
        if size < smallThreshold { return .system(size: 8) }
        if size < mediumThreshold { return .caption2 }
        if size < largeThreshold { return .caption }
        return .subheadline
    }

    static func metadataFont(for size: Double) -> Font {
        if size < smallThreshold { return .system(size: 8) }
        if size < mediumThreshold { return .caption2 }
        if size < largeThreshold { return .caption }
        return .subheadline
    }

    static func cornerRadius(for size: Double) -> CGFloat {
        if size < smallThreshold { return 8 }
        if size < largeThreshold { return 10 }
        return 12
    }

    static func channelIconSize(for size: Double) -> CGFloat {
        if size < smallThreshold { return 16 }
        if size < mediumThreshold { return 22 }
        if size < largeThreshold { return 28 }
        return 32
    }

    static func cardPadding(for size: Double) -> CGFloat {
        if size < smallThreshold { return 6 }
        if size < mediumThreshold { return 8 }
        return 12
    }

    static func durationFontSize(for size: Double) -> CGFloat {
        size < mediumThreshold ? 8 : 10
    }

    static func durationPadding(for size: Double) -> CGFloat {
        size < mediumThreshold ? 3 : 5
    }

    static func metadataSpacing(for size: Double) -> CGFloat {
        size < mediumThreshold ? 4 : 8
    }

    static func channelSpacing(for size: Double) -> CGFloat {
        size < mediumThreshold ? 6 : 10
    }
}
