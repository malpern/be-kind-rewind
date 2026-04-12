import Foundation
import Observation

/// Sort order options for the video grid.
enum SortOrder: String, CaseIterable {
    case views
    case date
    case duration
    case creator
    case alphabetical
    case shuffle

    var sfSymbol: String {
        switch self {
        case .views: return "chart.bar.fill"
        case .date: return "calendar"
        case .duration: return "timer"
        case .creator: return "person.2"
        case .alphabetical: return "textformat.abc"
        case .shuffle: return "shuffle"
        }
    }

    var label: String {
        switch self {
        case .views: return "Views"
        case .date: return "Date"
        case .duration: return "Length"
        case .creator: return "Creator"
        case .alphabetical: return "A-Z"
        case .shuffle: return "Shuffle"
        }
    }

    var helpText: String {
        switch self {
        case .views: return "Sort by view count"
        case .date: return "Sort by publish date"
        case .duration: return "Sort by length"
        case .creator: return "Group by creator"
        case .alphabetical: return "Sort alphabetically"
        case .shuffle: return "Random order"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .views: return "Sort by view count"
        case .date: return "Sort by date published"
        case .duration: return "Sort by video length"
        case .creator: return "Group by creator within each topic"
        case .alphabetical: return "Sort alphabetically by title"
        case .shuffle: return "Shuffle into random order"
        }
    }
}

@MainActor
@Observable
final class DisplaySettings {
    private enum DefaultsKey {
        static let thumbnailSize = "display.thumbnailSize"
        static let showMetadata = "display.showMetadata"
        static let showInspector = "display.showInspector"
    }

    var thumbnailSize: Double = 220 {
        didSet {
            UserDefaults.standard.set(thumbnailSize, forKey: DefaultsKey.thumbnailSize)
        }
    }
    var showMetadata: Bool = true {
        didSet {
            if !showMetadata { showInspector = true }
            UserDefaults.standard.set(showMetadata, forKey: DefaultsKey.showMetadata)
        }
    }
    var showInspector: Bool = false {
        didSet {
            UserDefaults.standard.set(showInspector, forKey: DefaultsKey.showInspector)
        }
    }
    var sortOrder: SortOrder? = nil
    var sortAscending: Bool = false
    var toast = ActionToastState()
    var searchRequested = false
    var showQuickNavigator = false
    var showKeyboardShortcuts = false
    var focusSidebarRequested = false
    var focusGridRequested = false
    var scrollToTopicRequested: Int64?
    var scrollToSectionRequested: String?
    var alert: AppAlertState?

    init() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: DefaultsKey.thumbnailSize) != nil {
            thumbnailSize = defaults.double(forKey: DefaultsKey.thumbnailSize)
        }

        if defaults.object(forKey: DefaultsKey.showMetadata) != nil {
            showMetadata = defaults.bool(forKey: DefaultsKey.showMetadata)
        }

        if defaults.object(forKey: DefaultsKey.showInspector) != nil {
            showInspector = defaults.bool(forKey: DefaultsKey.showInspector)
        }

        if !showMetadata {
            showInspector = true
        }
    }
}

struct AppAlertState: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
