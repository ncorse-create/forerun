import Foundation
import Testing
@testable import ForerunCore

private let referenceStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func event(
    id: String = "evt-1",
    source: EventSourceType = .eventkit,
    title: String = "Sunday Morning Service",
    calendarID: String = "cal-ministry",
    color: ColorFamily = .red,
    start: Date = referenceStart
) -> NormalizedEvent {
    NormalizedEvent(
        sourceID: id,
        sourceType: source,
        title: title,
        startDate: start,
        calendarID: calendarID,
        calendarName: "Ministry",
        colorFamily: color
    )
}

@Suite("Tracking rules")
struct TrackingRulesTests {

    @Test("With no rules configured, nothing is tracked")
    func nothingIsTrackedByDefault() {
        let decision = TrackingRules.decide(for: event(), settings: TrackingSettings())
        #expect(!decision.shouldTrack)
        #expect(decision.reason == .noRuleMatched)
    }

    @Test("A calendar rule tracks everything on that calendar")
    func calendarRuleTracks() {
        let settings = TrackingSettings(trackedCalendarIDs: ["cal-ministry"])
        let decision = TrackingRules.decide(for: event(), settings: settings)
        #expect(decision.shouldTrack)
        #expect(decision.reason == .calendarRule)
    }

    @Test("A colour rule tracks everything in that family regardless of which calendar it is on")
    func colorRuleTracks() {
        let settings = TrackingSettings(autoTrackColorFamilies: [.red])
        let decision = TrackingRules.decide(for: event(calendarID: "cal-other"), settings: settings)
        #expect(decision.shouldTrack)
        #expect(decision.reason == .colorRule)
    }

    @Test("Calendar and colour rules are OR'd, not AND'd")
    func rulesAreOrdTogether() {
        let settings = TrackingSettings(
            trackedCalendarIDs: ["cal-ministry"],
            autoTrackColorFamilies: [.blue]
        )
        #expect(TrackingRules.decide(for: event(color: .green), settings: settings).shouldTrack)
        #expect(TrackingRules.decide(for: event(calendarID: "cal-x", color: .blue), settings: settings).shouldTrack)
        #expect(!TrackingRules.decide(for: event(calendarID: "cal-x", color: .green), settings: settings).shouldTrack)
    }

    @Test("A manual untrack outranks every rule and survives a re-sync")
    func manualExclusionBeatsEveryRule() {
        let settings = TrackingSettings(
            trackedCalendarIDs: ["cal-ministry"],
            autoTrackColorFamilies: [.red],
            manuallyExcludedSourceIDs: ["evt-1"]
        )
        let decision = TrackingRules.decide(for: event(), settings: settings)
        #expect(!decision.shouldTrack)
        #expect(decision.reason == .manuallyExcluded)
    }

    @Test("A manual track survives a rule change that would otherwise drop it")
    func manualInclusionSurvivesRuleChanges() {
        let settings = TrackingSettings(
            trackedCalendarIDs: [],
            autoTrackColorFamilies: [],
            manuallyIncludedSourceIDs: ["evt-1"]
        )
        let decision = TrackingRules.decide(for: event(), settings: settings)
        #expect(decision.shouldTrack)
        #expect(decision.reason == .manuallyIncluded)
    }

    @Test("An exclusion outranks an inclusion, so the most recent user action wins")
    func exclusionOutranksInclusion() {
        let settings = TrackingSettings(
            manuallyExcludedSourceIDs: ["evt-1"],
            manuallyIncludedSourceIDs: ["evt-1"]
        )
        #expect(!TrackingRules.decide(for: event(), settings: settings).shouldTrack)
    }

    @Test("A grey calendar is never picked up by a colour rule for a real colour")
    func grayIsNotACatchAll() {
        let settings = TrackingSettings(autoTrackColorFamilies: [.red, .blue, .green])
        #expect(!TrackingRules.decide(for: event(color: .gray), settings: settings).shouldTrack)
    }
}

@Suite("Cross-source deduplication")
struct DeduplicationTests {

    @Test("A TickTick task matching a calendar event is dropped and the calendar event is kept")
    func calendarWinsOverTickTick() {
        let calendarEvent = event(id: "ek-1", source: .eventkit)
        let task = event(id: "tt-1", source: .ticktick, start: referenceStart.addingTimeInterval(300))
        let result = TrackingRules.deduplicate([calendarEvent, task])

        #expect(result.kept.map(\.sourceID) == ["ek-1"])
        #expect(result.duplicates.count == 1)
        #expect(result.duplicates.first?.dropped.sourceID == "tt-1")
        #expect(result.duplicates.first?.keptSourceID == "ek-1")
    }

    @Test("A TickTick task with no calendar counterpart is kept")
    func unmatchedTasksSurvive() {
        let calendarEvent = event(id: "ek-1", source: .eventkit, title: "Sunday Morning Service")
        let task = event(id: "tt-1", source: .ticktick, title: "File the quarterly return")
        let result = TrackingRules.deduplicate([calendarEvent, task])

        #expect(Set(result.kept.map(\.sourceID)) == ["ek-1", "tt-1"])
        #expect(result.duplicates.isEmpty)
    }

    @Test("Two calendar events with the same title are never deduplicated against each other")
    func sameSourceEventsAreNeverMerged() {
        let first = event(id: "ek-1", source: .eventkit)
        let second = event(id: "ek-2", source: .eventkit)
        let result = TrackingRules.deduplicate([first, second])
        #expect(result.kept.count == 2)
        #expect(result.duplicates.isEmpty)
    }

    @Test("With no calendar events at all, every task is kept untouched")
    func tickTickOnlyIsPassedThrough() {
        let tasks = [
            event(id: "tt-1", source: .ticktick, title: "A"),
            event(id: "tt-2", source: .ticktick, title: "B")
        ]
        let result = TrackingRules.deduplicate(tasks)
        #expect(result.kept.count == 2)
        #expect(result.duplicates.isEmpty)
    }

    @Test("Recurring occurrences of the same series survive as distinct events")
    func recurringOccurrencesAreDistinct() {
        let week1 = event(id: "ek-1|0", source: .eventkit, start: referenceStart)
        let week2 = event(id: "ek-1|604800", source: .eventkit,
                          start: referenceStart.addingTimeInterval(7 * 86_400))
        let result = TrackingRules.deduplicate([week1, week2])
        #expect(result.kept.count == 2)
    }
}
