import Foundation
import TaggingKit

struct APIFallbackApprovalRequest: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let reason: String
    let operation: YouTubeAPIOperation
    let estimatedUnits: Int
    let remainingUnitsToday: Int
    let resetAt: Date
    let kind: DiscoveryTelemetryKind
    let passUnitsSpent: Int
    let passBudgetUnits: Int
    let passActive: Bool

    init(
        title: String,
        reason: String,
        operation: YouTubeAPIOperation,
        estimatedUnits: Int,
        remainingUnitsToday: Int,
        resetAt: Date,
        kind: DiscoveryTelemetryKind,
        passUnitsSpent: Int = 0,
        passBudgetUnits: Int = 0,
        passActive: Bool = false
    ) {
        self.title = title
        self.reason = reason
        self.operation = operation
        self.estimatedUnits = estimatedUnits
        self.remainingUnitsToday = remainingUnitsToday
        self.resetAt = resetAt
        self.kind = kind
        self.passUnitsSpent = passUnitsSpent
        self.passBudgetUnits = passBudgetUnits
        self.passActive = passActive
    }

    /// Single-sentence summary suitable for the simplified approval dialog.
    /// Drops the per-pass budget accounting and the quota-reset timestamp —
    /// both belonged in a Settings inspector, not in a yes/no decision dialog.
    /// The user just needs to know what failed, what it costs, and how much
    /// daily quota is left.
    var message: String {
        return "\(reason) This will use \(estimatedUnits) of \(remainingUnitsToday) units remaining today."
    }
}
