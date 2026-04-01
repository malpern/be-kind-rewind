import Foundation
import Observation

@MainActor
@Observable
final class DisplaySettings {
    var thumbnailSize: Double = 220
    var showChannelName: Bool = true
    var showChannelIcon: Bool = false
}
