import Foundation
import SwiftData

/// The ladder for one event.
@Model
public final class PrepPlan {
    @Attribute(.unique) public var id: UUID
    public var playbookID: String
    public var generatedAt: Date
    /// True when the lead time was shorter than the playbook wanted and the offsets had to be
    /// scaled into the window that was actually available.
    public var wasCompressed: Bool
    /// How much of the playbook did not survive, for any reason.
    public var droppedStepCount: Int
    /// How many of those the user's own per-event cap removed. The banner subtracts these so it
    /// never blames the squeeze for a limit the user set.
    public var droppedToCapCount: Int = 0

    /// Steps lost to the squeeze specifically.
    public var droppedToCompressionCount: Int {
        max(0, droppedStepCount - droppedToCapCount)
    }

    @Relationship(deleteRule: .cascade, inverse: \PrepStep.plan)
    public var steps: [PrepStep]

    public var event: TrackedEvent?

    public init(
        id: UUID = UUID(),
        playbookID: String,
        generatedAt: Date = .now,
        wasCompressed: Bool = false,
        droppedStepCount: Int = 0,
        droppedToCapCount: Int = 0,
        steps: [PrepStep] = []
    ) {
        self.id = id
        self.playbookID = playbookID
        self.generatedAt = generatedAt
        self.wasCompressed = wasCompressed
        self.droppedStepCount = droppedStepCount
        self.droppedToCapCount = droppedToCapCount
        self.steps = steps
    }
}

public extension PrepPlan {
    var orderedSteps: [PrepStep] {
        steps.sorted { $0.order < $1.order }
    }

    /// Chronological rather than by stored order. Used when a step is added or re-timed and the
    /// `order` field has to be brought back in line with the dates.
    var orderedStepsByDate: [PrepStep] {
        steps.sorted { ($0.snoozedUntil ?? $0.fireDate) < ($1.snoozedUntil ?? $1.fireDate) }
    }

    var pendingSteps: [PrepStep] {
        orderedSteps.filter { $0.state == .pending || $0.state == .snoozed }
    }

    /// Steps the user has personally touched. Regeneration must preserve every one of these,
    /// and the confirm dialog names the count before it runs.
    var userOwnedSteps: [PrepStep] {
        steps.filter(\.isUserOwned)
    }

    var nextStep: PrepStep? {
        pendingSteps.min { $0.fireDate < $1.fireDate }
    }
}
