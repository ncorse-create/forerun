import EventKit
import ForerunCore
import Testing
@testable import Forerun

/// Tests for logic that lives in the app target and therefore cannot live in `ForerunCore`.
///
/// These run on a **real device**, not a simulator — this project does not use simulators. They
/// exist because the code they cover is pure and testable even though its file imports EventKit
/// or UIKit; leaving it untested because of an import would be the wrong reason.
///
/// Everything genuinely device-dependent (EventKit permission, notification delivery, the
/// contact picker) is covered by the manual checklist in `docs/store/submission.md` instead,
/// because a unit test of those would only be testing a mock.

@Suite("TickTick date parsing")
struct TickTickDateTests {

    @Test("The colonless offset TickTick actually emits parses")
    func colonlessOffsetParses() {
        // This is the shape in TickTick's own docs, and it is the one that breaks
        // ISO8601DateFormatter's defaults.
        #expect(TickTickDate.parse("2019-11-13T03:00:00+0000") != nil)
    }

    @Test("Fractional seconds parse too")
    func fractionalSecondsParse() {
        #expect(TickTickDate.parse("2026-03-04T23:58:20.000+0000") != nil)
    }

    @Test("The colon-bearing ISO form parses, in case the API changes")
    func standardISOParses() {
        #expect(TickTickDate.parse("2026-03-04T23:58:20+00:00") != nil)
        #expect(TickTickDate.parse("2026-03-04T23:58:20Z") != nil)
    }

    @Test("All four shapes agree on the same instant")
    func everyShapeAgrees() throws {
        let expected = try #require(TickTickDate.parse("2026-03-04T12:00:00Z"))
        #expect(TickTickDate.parse("2026-03-04T12:00:00+0000") == expected)
        #expect(TickTickDate.parse("2026-03-04T12:00:00+00:00") == expected)
        #expect(TickTickDate.parse("2026-03-04T12:00:00.000+0000") == expected)
    }

    @Test("An offset is honoured rather than ignored")
    func offsetsAreHonoured() throws {
        let utc = try #require(TickTickDate.parse("2026-03-04T12:00:00+0000"))
        let plusFive = try #require(TickTickDate.parse("2026-03-04T12:00:00+0500"))
        #expect(utc.timeIntervalSince(plusFive) == 5 * 3_600)
    }

    @Test("Nonsense returns nil rather than a wrong date")
    func garbageReturnsNil() {
        #expect(TickTickDate.parse(nil) == nil)
        #expect(TickTickDate.parse("") == nil)
        #expect(TickTickDate.parse("tomorrow") == nil)
        #expect(TickTickDate.parse("2026-13-45T99:99:99+0000") == nil)
    }
}

@Suite("The red rule")
struct TickTickRedRuleTests {

    @Test("High priority counts as red when the user says so")
    func highPriorityIsRed() {
        let rule = TickTickRedRule(treatsHighPriorityAsRed: true, redProjectIDs: [])
        #expect(rule.matches(priority: 5, projectID: "p1"))
        #expect(!rule.matches(priority: 3, projectID: "p1"))
        #expect(!rule.matches(priority: nil, projectID: "p1"))
    }

    @Test("Only priority 5 is high — 4 is never used by TickTick")
    func onlyFiveIsHigh() {
        let rule = TickTickRedRule(treatsHighPriorityAsRed: true, redProjectIDs: [])
        for priority in [0, 1, 2, 3, 4] {
            #expect(!rule.matches(priority: priority, projectID: "p1"))
        }
    }

    @Test("A named project counts as red regardless of priority")
    func namedProjectsAreRed() {
        let rule = TickTickRedRule(treatsHighPriorityAsRed: false, redProjectIDs: ["ministry"])
        #expect(rule.matches(priority: 0, projectID: "ministry"))
        #expect(!rule.matches(priority: 5, projectID: "other"))
    }

    @Test("The two rules are OR'd, matching the settings copy")
    func rulesAreOrd() {
        let rule = TickTickRedRule(treatsHighPriorityAsRed: true, redProjectIDs: ["ministry"])
        #expect(rule.matches(priority: 5, projectID: "other"))
        #expect(rule.matches(priority: 0, projectID: "ministry"))
        #expect(!rule.matches(priority: 0, projectID: "other"))
    }

    @Test("With neither rule on, nothing is red")
    func nothingIsRedByDefault() {
        let rule = TickTickRedRule(treatsHighPriorityAsRed: false, redProjectIDs: [])
        #expect(!rule.matches(priority: 5, projectID: "ministry"))
    }
}

@Suite("Composite source identifiers")
struct SourceIdentifierTests {

    @Test("A composite id round-trips through its two accessors")
    func compositeRoundTrips() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let composite = EventKitSource.compositeSourceID(identifier: "EK-ABC", start: start)
        #expect(EventKitSource.seriesIdentifier(from: composite) == "EK-ABC")
        #expect(EventKitSource.occurrenceStart(from: composite) == start)
    }

    @Test("Every occurrence of a series shares one series identifier")
    func occurrencesShareASeries() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ids = (0..<8).map {
            EventKitSource.compositeSourceID(
                identifier: "EK-WEEKLY",
                start: base.addingTimeInterval(Double($0) * 7 * 86_400)
            )
        }
        #expect(Set(ids).count == 8, "occurrences must be distinct")
        #expect(Set(ids.map(EventKitSource.seriesIdentifier(from:))).count == 1)
    }

    @Test("An identifier containing a pipe does not confuse the split")
    func pipesInIdentifiersAreSafe() {
        // `maxSplits: 1` means only the first pipe separates, so a pipe inside the identifier
        // itself cannot swallow the timestamp.
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let composite = EventKitSource.compositeSourceID(identifier: "EK|ODD", start: start)
        #expect(EventKitSource.seriesIdentifier(from: composite) == "EK")
        // The remainder is not a valid interval, so the start is reported as unknown rather
        // than as a wrong date.
        #expect(EventKitSource.occurrenceStart(from: composite) == nil)
    }

    @Test("A malformed id yields nil rather than a wrong date")
    func malformedIdsAreSafe() {
        #expect(EventKitSource.occurrenceStart(from: "no-pipe-here") == nil)
        #expect(EventKitSource.occurrenceStart(from: "id|not-a-number") == nil)
        #expect(EventKitSource.seriesIdentifier(from: "") == "")
    }
}

@Suite("Work block planning")
@MainActor
struct WorkBlockPlannerTests {

    private func event(
        title: String = "Sprint 4 — rules engine",
        start: Date,
        end: Date? = nil,
        isAllDay: Bool = false,
        kind: EventKind = .buildWork
    ) -> TrackedEvent {
        TrackedEvent(
            sourceID: "ek-1|1",
            sourceType: .eventkit,
            title: title,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            calendarID: "c",
            calendarName: "Work",
            kind: kind
        )
    }

    @Test("A timed event blocks its own span")
    func timedEventsUseTheirOwnSpan() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let end = start.addingTimeInterval(2 * 3_600)
        let block = WorkBlockPlanner.proposedBlock(for: event(start: start, end: end))
        #expect(block.start == start)
        #expect(block.end == end)
        #expect(block.title == "Sprint 4 — rules engine")
    }

    @Test("A zero-length event gets the default duration rather than a zero-length block")
    func zeroLengthEventsGetADefault() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let block = WorkBlockPlanner.proposedBlock(for: event(start: start, end: start))
        #expect(block.end.timeIntervalSince(block.start) == WorkBlockPlanner.defaultDuration)
    }

    @Test("An event with no end date gets the default duration")
    func missingEndGetsADefault() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let block = WorkBlockPlanner.proposedBlock(for: event(start: start, end: nil))
        #expect(block.end.timeIntervalSince(block.start) == WorkBlockPlanner.defaultDuration)
    }

    @Test("An all-day event blocks a morning rather than the whole day")
    func allDayEventsBlockAMorning() {
        let start = Calendar.current.startOfDay(
            for: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let block = WorkBlockPlanner.proposedBlock(for: event(start: start, isAllDay: true))
        #expect(Calendar.current.component(.hour, from: block.start) == 9)
        #expect(block.end.timeIntervalSince(block.start) == WorkBlockPlanner.defaultDuration)
    }

    @Test("An inverted end date does not produce a backwards block")
    func invertedEndDatesAreIgnored() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let block = WorkBlockPlanner.proposedBlock(
            for: event(start: start, end: start.addingTimeInterval(-3_600))
        )
        #expect(block.end > block.start)
    }

    @Test("Only the buildWork block-out rung offers to write to the calendar")
    func onlyTheRightRungIsOfferable() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let buildEvent = event(start: start)
        let teachingEvent = event(start: start, kind: .teachingPrep)

        let blockStep = PrepStep(
            order: 0, offsetSeconds: -3 * 86_400, fireDate: start,
            audience: .me, actionVerb: "Block", templateCopy: "x",
            playbookStepID: WorkBlockPlanner.stepID
        )
        let otherStep = PrepStep(
            order: 0, offsetSeconds: -7 * 86_400, fireDate: start,
            audience: .me, actionVerb: "Define", templateCopy: "x",
            playbookStepID: "buildWork.d-7.self"
        )

        #expect(WorkBlockPlanner.isOfferable(blockStep, event: buildEvent))
        #expect(!WorkBlockPlanner.isOfferable(otherStep, event: buildEvent))
        // A teaching event has no block-out rung, so it must never offer one.
        #expect(!WorkBlockPlanner.isOfferable(blockStep, event: teachingEvent))
    }

    @Test("The step this feature hangs off actually exists in the playbook")
    func theOfferedRungIsRealForever() {
        // If this fails, someone renamed a playbook step id and silently disabled the whole
        // calendar write-back feature.
        #expect(PlaybookLibrary.buildWork.steps.contains { $0.id == WorkBlockPlanner.stepID })
    }
}

@Suite("Scratchpad images")
struct ScratchpadImageTests {

    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("A large capture is downscaled to the long-edge limit")
    func largeImagesAreDownscaled() {
        let scaled = ScratchpadImage.downscale(image(width: 4_032, height: 3_024))
        #expect(max(scaled.size.width, scaled.size.height) <= ScratchpadImage.maxDimension + 1)
    }

    @Test("Downscaling preserves the aspect ratio")
    func aspectRatioIsPreserved() {
        let original = image(width: 4_032, height: 3_024)
        let scaled = ScratchpadImage.downscale(original)
        let before = original.size.width / original.size.height
        let after = scaled.size.width / scaled.size.height
        #expect(abs(before - after) < 0.01)
    }

    @Test("A small image is left alone rather than upscaled")
    func smallImagesAreUntouched() {
        let original = image(width: 800, height: 600)
        let scaled = ScratchpadImage.downscale(original)
        #expect(scaled.size == original.size)
    }

    @Test("Encoding produces non-empty JPEG data")
    func encodingProducesData() {
        let data = ScratchpadImage.encode(image(width: 1_200, height: 900))
        #expect(!data.isEmpty)
        // JPEG magic number, so this is genuinely a JPEG and not a PNG by accident.
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test("A whiteboard-sized capture stays well under a megabyte")
    func encodedSizeIsReasonable() {
        // The whole point of downscaling before storage: a full-resolution capture is several
        // megabytes and nothing here needs more than legible handwriting.
        let data = ScratchpadImage.encode(image(width: 4_032, height: 3_024))
        #expect(data.count < 1_000_000, "encoded to \(data.count) bytes")
    }
}

@Suite("Intent rows")
struct IntentRowTests {

    private func row(daysFromNow: Int) -> IntentStepRow {
        let fireDate = Calendar.current.date(byAdding: .day, value: daysFromNow, to: .now) ?? .now
        return IntentStepRow(
            id: UUID(),
            copy: "Send the ask to your team leads.",
            eventTitle: "Sunday Service",
            fireDate: fireDate,
            audience: .leaders
        )
    }

    @Test("Relative labels read the way a person would say them")
    func labelsReadNaturally() {
        #expect(row(daysFromNow: 0).whenLabel == "today")
        #expect(row(daysFromNow: 1).whenLabel == "tomorrow")
        #expect(row(daysFromNow: 4).whenLabel == "in 4 days")
        #expect(row(daysFromNow: -1).whenLabel == "overdue")
    }

    @Test("The audience filter matches the engine's own classification")
    func audienceFilterMatchesTheDomain() {
        #expect(IntentAudience.everyone.matches(.leaders))
        #expect(IntentAudience.everyone.matches(.me))
        #expect(IntentAudience.leaders.matches(.leaders))
        #expect(IntentAudience.leaders.matches(.volunteers))
        #expect(!IntentAudience.leaders.matches(.participants))
        #expect(IntentAudience.participants.matches(.students))
        #expect(!IntentAudience.participants.matches(.me))
    }
}
