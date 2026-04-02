import Foundation
import Observation

enum SortOrder: String, CaseIterable {
    case views
    case date
    case duration
    case alphabetical
    case shuffle

    var sfSymbol: String {
        switch self {
        case .views: return "chart.bar.fill"
        case .date: return "calendar"
        case .duration: return "timer"
        case .alphabetical: return "textformat.abc"
        case .shuffle: return "shuffle"
        }
    }

    var label: String {
        switch self {
        case .views: return "Views"
        case .date: return "Date"
        case .duration: return "Length"
        case .alphabetical: return "A-Z"
        case .shuffle: return "Shuffle"
        }
    }

    var helpText: String {
        switch self {
        case .views: return "Sort by view count"
        case .date: return "Sort by publish date"
        case .duration: return "Sort by length"
        case .alphabetical: return "Sort alphabetically"
        case .shuffle: return "Random order"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .views: return "Sort by view count"
        case .date: return "Sort by date published"
        case .duration: return "Sort by video length"
        case .alphabetical: return "Sort alphabetically by title"
        case .shuffle: return "Shuffle into random order"
        }
    }
}

@MainActor
@Observable
final class DisplaySettings {
    var thumbnailSize: Double = 220
    var showMetadata: Bool = true {
        didSet {
            if !showMetadata { showInspector = true }
        }
    }
    var showInspector: Bool = false
    var sortOrder: SortOrder? = nil
    var sortAscending: Bool = false
    var toast = ActionToastState()
}
