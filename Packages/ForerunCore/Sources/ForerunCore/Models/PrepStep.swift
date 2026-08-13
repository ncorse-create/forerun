import Foundation
import SwiftData

/// Where a step is in its life. Four states, and none of them is a score. Skipping costs
/// nothing — it is a first-class outcome, not a failure (locked decision 4).
public enum StepState: String, Codable, CaseIterable, Sendable {
    case pending
    case fired
    case done
    case snoozed
    case skipped

    public var isResolved: Bool { self == .done || self == .skipped }
    /// States that still want a notification on the schedule.
    public var isSchedulable: Bool { self == .pending || self == .snoozed }
}

/// One rung of the ladder.
@Model
public final class PrepStep {
    @Attribute(.unique) public var id: UUID
    public var order: Int
    /// Negative is before the event start. Stored as an interval so a timezone or DST change
    /// re-derives the fire date rather than shifting a stored wall-clock time (invariant 10).
    public var offsetSeconds: TimeInterval
    /// Absolute, after budget and quiet hours have been applied.
    public var fireDate: Date
    public var audienceRaw: String
    public var actionVerb: String
    /// Deterministic fallback. Always present, always shippable on its own.
    public var templateCopy: String
    /// Model output. Nil whenever the model was unavailable or its output failed the validator.
    public var generatedCopy: String?
    /// Wins over everything, forever.
    public var userEditedCopy: String?
    /// Survives the per-event cap.
    public var isCore: Bool
    public var stateRaw: String
    public var stateChangedAt: Date?
    /// Exempt from quiet hours, the daily budget, and the inter-step gap (invariant 8).
    public var userPinnedTime: Bool
    /// Stable identity across regenerations. Matching on `order` would break the moment a step
    /// ahead of it is dropped, which is exactly when preserving a user edit matters most.
    public var playbookStepID: String
    /// True for steps the user added by hand. These have no playbook counterpart and are never
    /// dropped by regeneration.
    public var isCustom: Bool
    /// Set when snoozed, so the scheduler knows the new target without losing the original.
    public var snoozedUntil: Date?
    /// Set once a message composer reported `.sent` for this step.
    public var handedOffAt: Date?
    /// The `EKEvent` identifier of a working block this step created, so the block can be
    /// removed again. Only ever set by the buildWork write-back.
    public var calendarBlockIdentifier: String?

    public var plan: PrepPlan?

    public init(
        id: UUID = UUID(),
        order: Int,
        offsetSeconds: TimeInterval,
        fireDate: Date,
        audience: Audience,
        actionVerb: String,
        templateCopy: String,
        generatedCopy: String? = nil,
        userEditedCopy: String? = nil,
        isCore: Bool = false,
        state: StepState = .pending,
        userPinnedTime: Bool = false,
        playbookStepID: String,
        isCustom: Bool = false
    ) {
        self.id = id
        self.order = order
        self.offsetSeconds = offsetSeconds
        self.fireDate = fireDate
        self.audienceRaw = audience.rawValue
        self.actionVerb = actionVerb
        self.templateCopy = templateCopy
        self.generatedCopy = generatedCopy
        self.userEditedCopy = userEditedCopy
        self.isCore = isCore
        self.stateRaw = state.rawValue
        self.stateChangedAt = nil
        self.userPinnedTime = userPinnedTime
        self.playbookStepID = playbookStepID
        self.isCustom = isCustom
        self.snoozedUntil = nil
        self.handedOffAt = nil
        self.calendarBlockIdentifier = nil
    }
}

public extension PrepStep {
    /// Falls back to `.leaders`, not `.me`. An unreadable raw value must fail *toward* locked
    /// decision 2: `.me` sorts last, is not leadership, is not contactable, and would drop the
    /// step out of the ordering check entirely. `.leaders` keeps it protected and contactable,
    /// which is the safe direction to be wrong in.
    var audience: Audience {
        get { Audience(rawValue: audienceRaw) ?? .leaders }
        set { audienceRaw = newValue.rawValue }
    }

    /// Falls back to `.skipped`, not `.pending`. `.pending` is schedulable, so an unreadable
    /// state would re-arm work the user already finished and fire it at them a second time —
    /// the over-notification failure this app is built to avoid. `.skipped` costs nothing.
    var state: StepState {
        get { StepState(rawValue: stateRaw) ?? .skipped }
        set {
            // Only stamp on a real transition. Re-assigning the same value would otherwise
            // dirty the context and throw away the time the step actually changed.
            guard newValue.rawValue != stateRaw else { return }
            stateRaw = newValue.rawValue
            stateChangedAt = .now
        }
    }

    /// The sentence that actually ships. User edit beats model output beats template — in that
    /// order, always (locked decision 7).
    var effectiveCopy: String {
        userEditedCopy ?? generatedCopy ?? templateCopy
    }

    /// True once a human has put their hands on this step. Regeneration preserves these.
    var isUserOwned: Bool {
        userEditedCopy != nil || userPinnedTime || isCustom
    }

    /// The notification identifier. One scheme, everywhere, so cancellation is exact.
    var notificationIdentifier: String {
        "step.\(id.uuidString)"
    }

    /// Relative label for the timeline: "3 days before", "2 hours before", "1 day after".
    ///
    /// The hour/day split is on the raw interval, not on a rounded day count — rounding first
    /// makes everything from 12 hours upward report as "1 day," so a −18h step would claim to
    /// be a day out.
    var relativeLabel: String {
        let magnitude = abs(offsetSeconds)
        let after = offsetSeconds > 0
        if magnitude < 3_600 { return after ? "just after" : "at the start" }
        if magnitude < 86_400 {
            let hours = Int((magnitude / 3_600).rounded())
            let unit = hours == 1 ? "hour" : "hours"
            return after ? "\(hours) \(unit) after" : "\(hours) \(unit) before"
        }
        let days = Int((magnitude / 86_400).rounded())
        let unit = days == 1 ? "day" : "days"
        return after ? "\(days) \(unit) after" : "\(days) \(unit) before"
    }

    /// `−4d`, `−18h`, `+1d`. The compact form, for the mono column on a card where the sentence
    /// is already carrying the meaning and the offset only has to be scannable.
    ///
    /// A true minus sign (U+2212), not a hyphen: at mono sizes a hyphen sits too high and too
    /// short to read as a sign.
    var compactOffsetLabel: String {
        let magnitude = abs(offsetSeconds)
        let sign = offsetSeconds > 0 ? "+" : "\u{2212}"
        if magnitude < 3_600 { return "0" }
        if magnitude < 86_400 {
            return "\(sign)\(Int((magnitude / 3_600).rounded()))h"
        }
        return "\(sign)\(Int((magnitude / 86_400).rounded()))d"
    }
}
