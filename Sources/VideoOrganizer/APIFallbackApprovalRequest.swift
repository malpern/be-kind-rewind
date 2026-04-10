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

    init(
        title: String,
        reason: String,
        operation: YouTubeAPIOperation,
        estimatedUnits: Int,
        remainingUnitsToday: Int,
        resetAt: Date,
        kind: DiscoveryTelemetryKind
    ) {
        self.title = title
        self.reason = reason
        self.operation = operation
        self.estimatedUnits = estimatedUnits
        self.remainingUnitsToday = remainingUnitsToday
        self.resetAt = resetAt
        self.kind = kind
    }

    var message: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        let resetString = formatter.string(from: resetAt)
        let remainingAfterApproval = max(0, remainingUnitsToday - estimatedUnits)
        return "\(reason)\n\nEstimated cost: \(estimatedUnits) units.\nRemaining today: \(remainingUnitsToday) units.\nRemaining after approval: \(remainingAfterApproval) units.\nQuota resets at \(resetString) Pacific."
    }
}
