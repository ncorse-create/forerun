import Foundation
import SwiftData

/// One resolved step, recorded so the *playbook* can be judged — never the person.
///
/// This is a diagnostic, not a score. If the −21d ask gets skipped nine times out of ten, the
/// offset is wrong and the user should be able to see that. There is deliberately no streak, no
/// completion rate framed as an achievement, and no comparison over time (locked decision 4).
/// The row is keyed by `playbookStepID` because the question is always "is this rung of this
/// ladder any good," never "how is the user doing."
@Model
public final class StepOutcome {
    @Attribute(.unique) public var id: UUID
    /// e.g. `volunteerTeamEvent.d-21.leaders`
    public var playbookStepID: String
    public var kindRaw: String
    public var audienceRaw: String
    public var offsetSeconds: TimeInterval
    /// `done` or `skipped`. Pending steps are never recorded.
    public var stateRaw: String
    public var decidedAt: Date
    /// True when the step was resolved from a notification action rather than in the app. Useful
    /// for telling "I ignored this" apart from "I dealt with it somewhere else."
    public var fromNotification: Bool

    public init(
        id: UUID = UUID(),
        playbookStepID: String,
        kind: EventKind,
        audience: Audience,
        offsetSeconds: TimeInterval,
        state: StepState,
        decidedAt: Date = .now,
        fromNotification: Bool = false
    ) {
        self.id = id
        self.playbookStepID = playbookStepID
        self.kindRaw = kind.rawValue
        self.audienceRaw = audience.rawValue
        self.offsetSeconds = offsetSeconds
        self.stateRaw = state.rawValue
        self.decidedAt = decidedAt
        self.fromNotification = fromNotification
    }
}

public extension StepOutcome {
    var kind: EventKind { EventKind(rawValue: kindRaw) ?? .unknown }
    var audience: Audience { Audience(rawValue: audienceRaw) ?? .leaders }
    var state: StepState { StepState(rawValue: stateRaw) ?? .skipped }
    var wasSkipped: Bool { state == .skipped }

    /// Outcomes deliberately have no relationship to the event they came from — the question is
    /// always "is this rung of this ladder any good," never "how is the user doing" — which also
    /// means nothing cascades them away and the table only grows.
    ///
    /// A year is long enough to see a seasonal pattern and short enough that a playbook you
    /// corrected six months ago stops dragging its old numbers along.
    static let retentionDays = 365

    /// Trims outcomes past the retention window. Called from the same place the sync purges
    /// finished events, so there is one housekeeping pass rather than several.
    @MainActor
    @discardableResult
    static func prune(in context: ModelContext, now: Date = .now) -> Int {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else {
            return 0
        }
        let descriptor = FetchDescriptor<StepOutcome>(
            predicate: #Predicate { $0.decidedAt < cutoff }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return 0 }
        for outcome in stale { context.delete(outcome) }
        return stale.count
    }

    /// Removes every outcome belonging to one playbook rung. This is what "delete all my data"
    /// reaches for; there is no per-event deletion because an outcome is not about an event.
    @MainActor
    static func deleteAll(in context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<StepOutcome>()) else { return }
        for outcome in all { context.delete(outcome) }
    }
}

/// The read model behind the skip-rate screen. Pure value type, computed from outcomes, so the
/// whole diagnostic is unit-testable without a database.
public struct SkipRateRow: Sendable, Equatable, Identifiable {
    public var playbookStepID: String
    public var kind: EventKind
    public var audience: Audience
    public var offsetSeconds: TimeInterval
    public var doneCount: Int
    public var skippedCount: Int

    public var id: String { playbookStepID }
    public var total: Int { doneCount + skippedCount }
    public var skipRate: Double { total == 0 ? 0 : Double(skippedCount) / Double(total) }

    /// Below this many resolutions there is nothing to learn and the row is not shown at all.
    /// Four is enough to distinguish a habit from a bad week without waiting a season.
    public static let minimumSampleSize = 4

    /// The threshold at which the offset itself is the suspect rather than the user.
    public static let noteworthySkipRate = 0.6

    public var isNoteworthy: Bool {
        total >= Self.minimumSampleSize && skipRate >= Self.noteworthySkipRate
    }

    public init(
        playbookStepID: String,
        kind: EventKind,
        audience: Audience,
        offsetSeconds: TimeInterval,
        doneCount: Int,
        skippedCount: Int
    ) {
        self.playbookStepID = playbookStepID
        self.kind = kind
        self.audience = audience
        self.offsetSeconds = offsetSeconds
        self.doneCount = doneCount
        self.skippedCount = skippedCount
    }

    /// Rolls a flat list of outcomes into one row per playbook step, newest-agnostic — order
    /// does not matter and nothing decays, because a diagnostic that changes when you look at it
    /// is not a diagnostic.
    public static func rows(from outcomes: [StepOutcomeSnapshot]) -> [SkipRateRow] {
        var byStep: [String: SkipRateRow] = [:]
        for outcome in outcomes where outcome.state.isResolved {
            var row = byStep[outcome.playbookStepID] ?? SkipRateRow(
                playbookStepID: outcome.playbookStepID,
                kind: outcome.kind,
                audience: outcome.audience,
                offsetSeconds: outcome.offsetSeconds,
                doneCount: 0,
                skippedCount: 0
            )
            if outcome.state == .skipped { row.skippedCount += 1 } else { row.doneCount += 1 }
            byStep[outcome.playbookStepID] = row
        }
        return byStep.values.sorted {
            if $0.skipRate != $1.skipRate { return $0.skipRate > $1.skipRate }
            return $0.offsetSeconds < $1.offsetSeconds
        }
    }
}

/// A `StepOutcome` lifted out of SwiftData so the roll-up is a pure function.
public struct StepOutcomeSnapshot: Sendable, Equatable {
    public var playbookStepID: String
    public var kind: EventKind
    public var audience: Audience
    public var offsetSeconds: TimeInterval
    public var state: StepState

    public init(
        playbookStepID: String,
        kind: EventKind,
        audience: Audience,
        offsetSeconds: TimeInterval,
        state: StepState
    ) {
        self.playbookStepID = playbookStepID
        self.kind = kind
        self.audience = audience
        self.offsetSeconds = offsetSeconds
        self.state = state
    }
}
