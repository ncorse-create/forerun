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
    /// How much of the playbook survived, for the compression banner's sentence.
    public var droppedStepCount: Int

    @Relationship(deleteRule: .cascade, inverse: \PrepStep.plan)
    public var steps: [PrepStep]

    public var event: TrackedEvent?

    public init(
        id: UUID = UUID(),
        playbookID: String,
        generatedAt: Date = .now,
        wasCompressed: Bool = false,
        droppedStepCount: Int = 0,
        steps: [PrepStep] = []
    ) {
        self.id = id
        self.playbookID = playbookID
        self.generatedAt = generatedAt
        self.wasCompressed = wasCompressed
        self.droppedStepCount = droppedStepCount
        self.steps = steps
    }
}

public extension PrepPlan {
    var orderedSteps: [PrepStep] {
        steps.sorted { $0.order < $1.order }
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
