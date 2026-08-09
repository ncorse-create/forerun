import Foundation

/// The tracking rules, lifted out of SwiftData so they are a pure function of their inputs.
public struct TrackingSettings: Sendable, Equatable {
    public var trackedCalendarIDs: Set<String>
    public var autoTrackColorFamilies: Set<ColorFamily>
    /// Events the user untracked by hand. Nothing in here is ever re-tracked by a rule.
    public var manuallyExcludedSourceIDs: Set<String>
    /// Events the user tracked by hand that no rule covers. A rule change never drops these.
    public var manuallyIncludedSourceIDs: Set<String>

    public init(
        trackedCalendarIDs: Set<String> = [],
        autoTrackColorFamilies: Set<ColorFamily> = [],
        manuallyExcludedSourceIDs: Set<String> = [],
        manuallyIncludedSourceIDs: Set<String> = []
    ) {
        self.trackedCalendarIDs = trackedCalendarIDs
        self.autoTrackColorFamilies = autoTrackColorFamilies
        self.manuallyExcludedSourceIDs = manuallyExcludedSourceIDs
        self.manuallyIncludedSourceIDs = manuallyIncludedSourceIDs
    }
}

/// Why an event is or is not tracked. Carried through so the UI can explain itself — "tracked
/// because it's on Ministry" is a very different sentence from "you tracked this one."
public enum TrackingReason: String, Sendable, Equatable {
    case manuallyIncluded
    case manuallyExcluded
    case calendarRule
    case colorRule
    case noRuleMatched
}

public struct TrackingDecision: Sendable, Equatable {
    public let shouldTrack: Bool
    public let reason: TrackingReason

    public init(shouldTrack: Bool, reason: TrackingReason) {
        self.shouldTrack = shouldTrack
        self.reason = reason
    }
}

public enum TrackingRules {
    /// Rules are OR'd, and the two manual sets outrank both of them.
    ///
    /// The precedence exists because of one specific failure the plan calls out: a user
    /// untracks a Tuesday standup that happens to be on a red calendar, and the next sync
    /// helpfully tracks it again. An exclusion is permanent until the user reverses it.
    public static func decide(
        for event: NormalizedEvent,
        settings: TrackingSettings
    ) -> TrackingDecision {
        if settings.manuallyExcludedSourceIDs.contains(event.sourceID) {
            return TrackingDecision(shouldTrack: false, reason: .manuallyExcluded)
        }
        if settings.manuallyIncludedSourceIDs.contains(event.sourceID) {
            return TrackingDecision(shouldTrack: true, reason: .manuallyIncluded)
        }
        if settings.trackedCalendarIDs.contains(event.calendarID) {
            return TrackingDecision(shouldTrack: true, reason: .calendarRule)
        }
        if settings.autoTrackColorFamilies.contains(event.colorFamily) {
            return TrackingDecision(shouldTrack: true, reason: .colorRule)
        }
        return TrackingDecision(shouldTrack: false, reason: .noRuleMatched)
    }

    /// Deduplicates across sources, keeping the EventKit record when a TickTick task describes
    /// the same thing. Returns the survivors and, for each dropped record, the sourceID of the
    /// record it lost to — so the dropped one can be marked rather than deleted.
    ///
    /// This matters because subscribing your TickTick calendar into Apple Calendar is the
    /// *recommended* setup, so a user with both connected sees everything twice by default.
    public static func deduplicate(
        _ events: [NormalizedEvent],
        within tolerance: TimeInterval = 15 * 60
    ) -> (kept: [NormalizedEvent], duplicates: [(dropped: NormalizedEvent, keptSourceID: String)]) {
        let calendarEvents = events.filter { $0.sourceType == .eventkit }
        guard !calendarEvents.isEmpty else { return (events, []) }

        var kept: [NormalizedEvent] = calendarEvents
        var duplicates: [(dropped: NormalizedEvent, keptSourceID: String)] = []

        for candidate in events where candidate.sourceType != .eventkit {
            if let match = calendarEvents.first(where: { $0.isProbableDuplicate(of: candidate, within: tolerance) }) {
                duplicates.append((candidate, match.sourceID))
            } else {
                kept.append(candidate)
            }
        }
        // Sorted, not source-grouped. Callers group by day, and handing back "all calendar
        // events, then all tasks" would silently interleave wrong.
        kept.sort { $0.startDate < $1.startDate }
        return (kept, duplicates)
    }
}
