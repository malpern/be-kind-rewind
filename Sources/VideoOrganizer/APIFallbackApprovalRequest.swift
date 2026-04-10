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

    var message: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        let resetString = formatter.string(from: resetAt)
        let remainingAfterApproval = max(0, remainingUnitsToday - estimatedUnits)

        var lines: [String] = [reason, ""]
        lines.append("Estimated cost: \(estimatedUnits) units.")
        if passActive && passBudgetUnits > 0 {
            let passRemaining = max(0, passBudgetUnits - passUnitsSpent)
            lines.append("This refresh has spent \(passUnitsSpent) of \(passBudgetUnits) budgeted units (\(passRemaining) remaining).")
        }
        lines.append("Remaining today: \(remainingUnitsToday) units (after approval: \(remainingAfterApproval)).")
        lines.append("Quota resets at \(resetString) Pacific.")
        return lines.joined(separator: "\n")
    }
}
