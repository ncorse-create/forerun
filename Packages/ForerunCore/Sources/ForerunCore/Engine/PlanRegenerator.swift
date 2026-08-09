import Foundation

/// A persisted step, lifted out of SwiftData so regeneration is a pure function.
public struct ExistingStep: Sendable, Equatable, Hashable {
    public var playbookStepID: String
    public var fireDate: Date
    public var state: StepState
    public var hasUserEditedCopy: Bool
    public var userPinnedTime: Bool
    public var isCustom: Bool

    public init(
        playbookStepID: String,
        fireDate: Date,
        state: StepState,
        hasUserEditedCopy: Bool = false,
        userPinnedTime: Bool = false,
        isCustom: Bool = false
    ) {
        self.playbookStepID = playbookStepID
        self.fireDate = fireDate
        self.state = state
        self.hasUserEditedCopy = hasUserEditedCopy
        self.userPinnedTime = userPinnedTime
        self.isCustom = isCustom
    }

    /// Locked decision 7: once a human has put their hands on a step, regeneration works around
    /// it rather than over it.
    public var isUserOwned: Bool {
        hasUserEditedCopy || userPinnedTime || isCustom
    }
}

/// What regeneration wants done to one step.
public enum StepMergeAction: Sendable, Equatable {
    /// Left exactly as it is — a custom step, a resolved step, or a pinned one.
    case keep(playbookStepID: String)
    /// Same step, new fire date and position. Copy is only replaced when the user never wrote
    /// their own.
    case retime(playbookStepID: String, fireDate: Date, order: Int, templateCopy: String, replaceCopy: Bool)
    /// A rung the previous plan did not have.
    case insert(StepDraft)
    /// A rung the new plan does not have, that nobody has touched.
    case remove(playbookStepID: String)
}

public struct PlanMergeResult: Sendable, Equatable {
    public var actions: [StepMergeAction]
    /// How many steps survived because a human owned them. The regenerate confirmation names
    /// this number before it runs, so "regenerate" is never a surprise.
    public var preservedCount: Int
    public var insertedCount: Int
    public var removedCount: Int
    public var wasCompressed: Bool
    public var droppedStepCount: Int
    public var droppedToCapCount: Int
    public var playbookID: String

    public init(
        actions: [StepMergeAction],
        preservedCount: Int,
        insertedCount: Int,
        removedCount: Int,
        wasCompressed: Bool,
        droppedStepCount: Int,
        droppedToCapCount: Int = 0,
        playbookID: String
    ) {
        self.actions = actions
        self.preservedCount = preservedCount
        self.insertedCount = insertedCount
        self.removedCount = removedCount
        self.wasCompressed = wasCompressed
        self.droppedStepCount = droppedStepCount
        self.droppedToCapCount = droppedToCapCount
        self.playbookID = playbookID
    }
}

public enum PlanRegenerator {

    /// Rebuilds a plan against a moved event and reconciles it with what is already there.
    ///
    /// Three categories are never overwritten:
    /// - **custom steps**, which have no playbook counterpart to be rebuilt from;
    /// - **resolved steps** (done or skipped), because re-timing something you already dealt
    ///   with would fire it at you a second time;
    /// - **user-owned steps**, where the specific thing preserved depends on what the user
    ///   actually did — an edited sentence keeps its words but still follows the event when it
    ///   moves, while a pinned time keeps its time.
    public static func merge(
        existing: [ExistingStep],
        draft: PlanDraft
    ) -> PlanMergeResult {
        var actions: [StepMergeAction] = []
        var preserved = 0
        var inserted = 0
        var removed = 0

        let draftByID = Dictionary(
            draft.steps.map { ($0.playbookStepID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingIDs = Set(existing.map(\.playbookStepID))

        for step in existing {
            // A custom step belongs to the user entirely. There is no playbook rung to rebuild.
            if step.isCustom {
                actions.append(.keep(playbookStepID: step.playbookStepID))
                preserved += 1
                continue
            }

            // Already dealt with. Leave it alone — its outcome is history now.
            if step.state.isResolved {
                actions.append(.keep(playbookStepID: step.playbookStepID))
                continue
            }

            guard let rebuilt = draftByID[step.playbookStepID] else {
                // The rung is gone from the new plan. Only drop it if nobody owns it.
                if step.isUserOwned {
                    actions.append(.keep(playbookStepID: step.playbookStepID))
                    preserved += 1
                } else {
                    actions.append(.remove(playbookStepID: step.playbookStepID))
                    removed += 1
                }
                continue
            }

            // A pinned time stays put; an edited sentence still follows the event.
            let fireDate = step.userPinnedTime ? step.fireDate : rebuilt.fireDate
            actions.append(.retime(
                playbookStepID: step.playbookStepID,
                fireDate: fireDate,
                order: rebuilt.order,
                templateCopy: rebuilt.templateCopy,
                replaceCopy: !step.hasUserEditedCopy
            ))
            if step.isUserOwned { preserved += 1 }
        }

        for step in draft.steps where !existingIDs.contains(step.playbookStepID) {
            actions.append(.insert(step))
            inserted += 1
        }

        return PlanMergeResult(
            actions: actions,
            preservedCount: preserved,
            insertedCount: inserted,
            removedCount: removed,
            wasCompressed: draft.wasCompressed,
            droppedStepCount: draft.droppedStepCount,
            droppedToCapCount: draft.droppedToCapCount,
            playbookID: draft.playbookID
        )
    }

    /// The sentence the regenerate confirmation shows. Naming the number is the whole point —
    /// "regenerate" with nothing at stake should not read the same as "regenerate and lose the
    /// three sentences you rewrote."
    /// Deliberately says "your wording" rather than "kept as they are": a step whose sentence
    /// the user rewrote keeps that sentence but still follows the event if it moved, so claiming
    /// nothing about it changes would be an over-claim.
    public static func confirmationMessage(for result: PlanMergeResult) -> String {
        switch result.preservedCount {
        case 0:
            "Forerun will rebuild this plan from the playbook. Nothing you've written will be lost."
        case 1:
            "Forerun will rebuild this plan. The one step you changed keeps your wording, your "
                + "pinned time, or both."
        default:
            "Forerun will rebuild this plan. The \(result.preservedCount) steps you changed keep "
                + "your wording, your pinned times, or both."
        }
    }
}
