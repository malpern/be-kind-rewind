import Foundation
import Observation

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
}
