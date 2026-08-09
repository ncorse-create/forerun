import Foundation

/// Everything the engine needs to know about an event, as a value type.
///
/// The engine takes values in and gives values out. It never touches a SwiftData object, which
/// is what makes every invariant testable synchronously, on macOS, with no simulator.
public struct PlanInput: Sendable, Equatable, Hashable {
    public var eventID: UUID
    public var title: String
    public var startDate: Date
    public var endDate: Date?
    public var isAllDay: Bool
    public var kind: EventKind

    public init(
        eventID: UUID = UUID(),
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        kind: EventKind
    ) {
        self.eventID = eventID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.kind = kind
    }
}

/// The settings the engine reads, lifted out of SwiftData.
public struct EngineSettings: Sendable, Equatable, Hashable {
    public var quietHoursStart: Int
    public var quietHoursEnd: Int
    public var dailyNotificationBudget: Int
    public var maxStepsPerEvent: Int
    public var preferredDeliveryHour: Int

    public init(
        quietHoursStart: Int = 22,
        quietHoursEnd: Int = 7,
        dailyNotificationBudget: Int = 6,
        maxStepsPerEvent: Int = 5,
        preferredDeliveryHour: Int = 8
    ) {
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.dailyNotificationBudget = dailyNotificationBudget
        self.maxStepsPerEvent = maxStepsPerEvent
        self.preferredDeliveryHour = preferredDeliveryHour
    }

    public static let `default` = EngineSettings()
}

/// A step the user has pinned, carried into a rebuild so invariant 8 can exempt it.
public struct PinnedStep: Sendable, Equatable, Hashable {
    public var playbookStepID: String
    public var fireDate: Date

    public init(playbookStepID: String, fireDate: Date) {
        self.playbookStepID = playbookStepID
        self.fireDate = fireDate
    }
}

/// The world the plan is being built into: what else is already scheduled, what the user is
/// busy doing, and what time it is.
public struct SchedulingContext: Sendable, Equatable {
    /// Intervals during which another tracked event is in progress. Invariant 5.
    public var busyWindows: [DateInterval]
    /// Fire dates already committed by *other* plans, for the cross-event daily budget.
    public var existingFireDates: [Date]
    /// Steps the user pinned. Exempt from re-timing.
    public var pinnedSteps: [PinnedStep]
    public var now: Date
    public var timeZone: TimeZone

    public init(
        busyWindows: [DateInterval] = [],
        existingFireDates: [Date] = [],
        pinnedSteps: [PinnedStep] = [],
        now: Date = .now,
        timeZone: TimeZone = .current
    ) {
        self.busyWindows = busyWindows
        self.existingFireDates = existingFireDates
        self.pinnedSteps = pinnedSteps
        self.now = now
        self.timeZone = timeZone
    }

    /// Fire dates are always computed in the user's *current* calendar, never a stored one, so a
    /// timezone change re-derives them correctly (invariant 10).
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

/// One rung, before it becomes a `PrepStep`.
public struct StepDraft: Sendable, Equatable, Hashable, Identifiable {
    public var playbookStepID: String
    public var order: Int
    public var offsetSeconds: TimeInterval
    public var fireDate: Date
    public var audience: Audience
    public var actionVerb: String
    public var templateCopy: String
    public var isCore: Bool
    /// Carried through a rebuild so the scheduler leaves it alone.
    public var isPinned: Bool

    public var id: String { playbookStepID }

    public init(
        playbookStepID: String,
        order: Int,
        offsetSeconds: TimeInterval,
        fireDate: Date,
        audience: Audience,
        actionVerb: String,
        templateCopy: String,
        isCore: Bool,
        isPinned: Bool = false
    ) {
        self.playbookStepID = playbookStepID
        self.order = order
        self.offsetSeconds = offsetSeconds
        self.fireDate = fireDate
        self.audience = audience
        self.actionVerb = actionVerb
        self.templateCopy = templateCopy
        self.isCore = isCore
        self.isPinned = isPinned
    }
}

/// The engine's output.
public struct PlanDraft: Sendable, Equatable {
    public var playbookID: String
    public var steps: [StepDraft]
    public var wasCompressed: Bool
    /// How many playbook steps did not survive. Drives the banner's sentence.
    public var droppedStepCount: Int

    public init(
        playbookID: String,
        steps: [StepDraft],
        wasCompressed: Bool = false,
        droppedStepCount: Int = 0
    ) {
        self.playbookID = playbookID
        self.steps = steps
        self.wasCompressed = wasCompressed
        self.droppedStepCount = droppedStepCount
    }

    public static func empty(playbookID: String) -> PlanDraft {
        PlanDraft(playbookID: playbookID, steps: [], wasCompressed: false, droppedStepCount: 0)
    }

    public var isEmpty: Bool { steps.isEmpty }
}
