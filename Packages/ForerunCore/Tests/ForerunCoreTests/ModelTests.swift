import Foundation
import SwiftData
import Testing
@testable import ForerunCore

@MainActor
private func makeContext() throws -> ModelContext {
    let container = try ForerunStore.container(inMemory: true)
    return ModelContext(container)
}

@MainActor
private func makeEvent(
    title: String = "Sunday Morning Service",
    start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
    kind: EventKind = .volunteerTeamEvent
) -> TrackedEvent {
    TrackedEvent(
        sourceID: "abc123|\(start.timeIntervalSinceReferenceDate)",
        sourceType: .eventkit,
        title: title,
        startDate: start,
        calendarID: "cal-1",
        calendarName: "Ministry",
        colorHex: "#C0392B",
        colorFamily: .red,
        kind: kind
    )
}

@Suite("Compact offsets")
struct CompactOffsetTests {

    private func step(_ seconds: TimeInterval) -> PrepStep {
        PrepStep(
            order: 0,
            offsetSeconds: seconds,
            fireDate: .now,
            audience: .leaders,
            actionVerb: "ask",
            templateCopy: "x",
            isCore: true,
            playbookStepID: "x"
        )
    }

    @Test("Days before carry a true minus sign, not a hyphen")
    func daysBefore() {
        // A hyphen sits too high and too short to read as a sign in the mono face.
        #expect(step(-4 * 86_400).compactOffsetLabel == "\u{2212}4d")
    }

    @Test("Days after carry a plus")
    func daysAfter() {
        #expect(step(86_400).compactOffsetLabel == "+1d")
    }

    @Test("Under a day reports hours, so an 18-hour step never claims to be a day out")
    func hours() {
        #expect(step(-18 * 3_600).compactOffsetLabel == "\u{2212}18h")
    }

    @Test("At the event itself there is no offset to show")
    func atTheEvent() {
        #expect(step(0).compactOffsetLabel == "0")
    }
}

@Suite("Persistence")
@MainActor
struct PersistenceTests {

    @Test("A tracked event survives a save and a fresh fetch with every field intact")
    func trackedEventRoundTrips() throws {
        let context = try makeContext()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let event = makeEvent(start: start)
        event.notes = "Doors at 8:15"
        event.location = "Main auditorium"
        event.priority = 5
        event.hasRecurrenceRules = true
        event.kindConfidence = 0.95
        context.insert(event)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<TrackedEvent>()).first)
        #expect(fetched.title == "Sunday Morning Service")
        #expect(fetched.notes == "Doors at 8:15")
        #expect(fetched.location == "Main auditorium")
        #expect(fetched.startDate == start)
        #expect(fetched.sourceType == .eventkit)
        #expect(fetched.colorFamily == .red)
        #expect(fetched.kind == .volunteerTeamEvent)
        #expect(fetched.kindConfidence == 0.95)
        #expect(fetched.priority == 5)
        #expect(fetched.hasRecurrenceRules)
    }

    @Test("Deleting a tracked event cascades to its plan, its steps, its scratchpad and its contacts")
    func cascadeDeleteRemovesEverythingBelow() throws {
        let context = try makeContext()
        let event = makeEvent()
        let plan = PrepPlan(playbookID: "volunteerTeamEvent")
        let step = PrepStep(
            order: 0,
            offsetSeconds: -21 * 86_400,
            fireDate: .now,
            audience: .leaders,
            actionVerb: "Send",
            templateCopy: "Send the ask to your team leads.",
            isCore: true,
            playbookStepID: "volunteerTeamEvent.d-21.leaders"
        )
        plan.steps = [step]
        event.plan = plan
        event.scratchpad = [ScratchpadItem(kind: .note, text: "Whiteboard says 4 teams")]
        event.contacts = [EventContact(contactIdentifier: "cn-1", displayName: "Sarah")]
        context.insert(event)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<PrepPlan>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PrepStep>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ScratchpadItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<EventContact>()) == 1)

        context.delete(event)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<TrackedEvent>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PrepPlan>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PrepStep>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ScratchpadItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<EventContact>()) == 0)
    }

    @Test("Step outcomes are not cascaded away with the event they came from")
    func outcomesOutliveTheirEvent() throws {
        let context = try makeContext()
        let event = makeEvent()
        context.insert(event)
        context.insert(StepOutcome(
            playbookStepID: "volunteerTeamEvent.d-21.leaders",
            kind: .volunteerTeamEvent,
            audience: .leaders,
            offsetSeconds: -21 * 86_400,
            state: .skipped
        ))
        try context.save()

        context.delete(event)
        try context.save()

        // The diagnostic is about the playbook, not the event. Deleting a Sunday service must
        // not erase what it taught us about the −21d ask.
        #expect(try context.fetchCount(FetchDescriptor<StepOutcome>()) == 1)
    }

    @Test("Settings seed once on first launch and are returned unchanged on the second call")
    func settingsSeedExactlyOnce() throws {
        let context = try makeContext()
        let first = try AppSettings.loadOrCreate(in: context)
        try context.save()
        first.preferredDeliveryHour = 9
        try context.save()

        let second = try AppSettings.loadOrCreate(in: context)
        #expect(second.preferredDeliveryHour == 9)
        #expect(try context.fetchCount(FetchDescriptor<AppSettings>()) == 1)
    }

    @Test("Settings defaults match the locked decisions")
    func settingsDefaultsMatchLockedDecisions() throws {
        let context = try makeContext()
        let settings = try AppSettings.loadOrCreate(in: context)
        #expect(settings.quietHoursStart == 22)
        #expect(settings.quietHoursEnd == 7)
        #expect(settings.dailyNotificationBudget == 6)
        #expect(settings.maxStepsPerEvent == 5)
        #expect(settings.preferredDeliveryHour == 8)
        #expect(settings.hasCompletedOnboarding == false)
        #expect(settings.enabledEventKinds.count == EventKind.selectable.count)
    }

    @Test("Clamping refuses to let the caps be raised past the locked ceiling")
    func clampingHoldsTheCaps() throws {
        let context = try makeContext()
        let settings = try AppSettings.loadOrCreate(in: context)
        settings.dailyNotificationBudget = 99
        settings.maxStepsPerEvent = 42
        settings.preferredDeliveryHour = 31
        settings.clampToLimits()
        #expect(settings.dailyNotificationBudget == AppSettings.maxDailyBudget)
        #expect(settings.maxStepsPerEvent == AppSettings.maxStepsCeiling)
        #expect(settings.preferredDeliveryHour == 23)

        settings.dailyNotificationBudget = 0
        settings.maxStepsPerEvent = 0
        settings.clampToLimits()
        #expect(settings.dailyNotificationBudget == AppSettings.minDailyBudget)
        #expect(settings.maxStepsPerEvent == AppSettings.minStepsFloor)
    }

    @Test("A re-sync updates the event's fields but never its kind or the user's confirmation")
    func syncDoesNotClobberUserOwnedFields() throws {
        let context = try makeContext()
        let event = makeEvent()
        event.kindWasConfirmedByUser = true
        context.insert(event)

        let moved = Date(timeIntervalSinceReferenceDate: 800_500_000)
        event.apply(NormalizedEvent(
            sourceID: event.sourceID,
            sourceType: .eventkit,
            title: "Sunday Morning Service — moved",
            startDate: moved,
            calendarID: "cal-1",
            calendarName: "Ministry",
            colorFamily: .blue
        ))

        #expect(event.title == "Sunday Morning Service — moved")
        #expect(event.startDate == moved)
        #expect(event.colorFamily == .blue)
        #expect(event.kind == .volunteerTeamEvent)
        #expect(event.kindWasConfirmedByUser)
    }
}

@Suite("Audience ordering")
struct AudienceTests {

    @Test("Leaders and volunteers sort ahead of participants and students, and self sorts last")
    func sortPriorityEncodesLockedDecisionTwo() {
        #expect(Audience.leaders.sortPriority == 0)
        #expect(Audience.volunteers.sortPriority == 1)
        #expect(Audience.participants.sortPriority == 2)
        #expect(Audience.students.sortPriority == 2)
        #expect(Audience.me.sortPriority == 3)

        let sorted = Audience.allCases.sorted { $0.sortPriority < $1.sortPriority }
        #expect(sorted.first == .leaders)
        #expect(sorted.last == .me)
    }

    @Test("Leadership and audience-side classification is exhaustive and disjoint")
    func leadershipAndAudienceSidesDoNotOverlap() {
        for audience in Audience.allCases {
            #expect(!(audience.isLeadership && audience.isAudienceSide))
        }
        #expect(Audience.allCases.filter(\.isLeadership) == [.leaders, .volunteers])
        #expect(Audience.allCases.filter(\.isAudienceSide) == [.participants, .students])
    }

    @Test("The persisted raw value for self stays \"self\" even though Swift calls it me")
    func selfKeepsItsWireName() {
        #expect(Audience.me.rawValue == "self")
        #expect(Audience(rawValue: "self") == .me)
    }

    @Test("Only steps aimed at other people can hand off to a composer")
    func onlyOtherPeopleAreContactable() {
        #expect(Audience.leaders.isContactable)
        #expect(Audience.volunteers.isContactable)
        #expect(Audience.participants.isContactable)
        #expect(Audience.students.isContactable)
        #expect(!Audience.me.isContactable)
    }
}

@Suite("Normalized events")
struct NormalizedEventTests {

    @Test("Titles normalize past case, punctuation and spacing before they are compared")
    func titleNormalizationIsAggressiveEnoughToMatch() {
        let a = NormalizedEvent(sourceID: "1", sourceType: .eventkit, title: "Sunday Service!",
                                startDate: .now, calendarID: "c", calendarName: "n")
        let b = NormalizedEvent(sourceID: "2", sourceType: .ticktick, title: "  sunday   service ",
                                startDate: .now, calendarID: "p", calendarName: "n")
        #expect(a.normalizedTitle == b.normalizedTitle)
        #expect(a.normalizedTitle == "sunday service")
    }

    @Test("Duplicates are only ever detected across sources, never within one")
    func duplicatesAreCrossSourceOnly() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let calendar = NormalizedEvent(sourceID: "1", sourceType: .eventkit, title: "Sunday Service",
                                       startDate: start, calendarID: "c", calendarName: "n")
        let task = NormalizedEvent(sourceID: "2", sourceType: .ticktick, title: "Sunday Service",
                                   startDate: start.addingTimeInterval(600),
                                   calendarID: "p", calendarName: "n")
        let sibling = NormalizedEvent(sourceID: "3", sourceType: .eventkit, title: "Sunday Service",
                                      startDate: start, calendarID: "c", calendarName: "n")

        #expect(calendar.isProbableDuplicate(of: task))
        #expect(!calendar.isProbableDuplicate(of: sibling))
    }

    @Test("A sixteen-minute gap is far enough apart to be two different things")
    func duplicateToleranceIsFifteenMinutes() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let calendar = NormalizedEvent(sourceID: "1", sourceType: .eventkit, title: "Serve Day",
                                       startDate: start, calendarID: "c", calendarName: "n")
        let inside = NormalizedEvent(sourceID: "2", sourceType: .ticktick, title: "Serve Day",
                                     startDate: start.addingTimeInterval(15 * 60),
                                     calendarID: "p", calendarName: "n")
        let outside = NormalizedEvent(sourceID: "3", sourceType: .ticktick, title: "Serve Day",
                                      startDate: start.addingTimeInterval(16 * 60),
                                      calendarID: "p", calendarName: "n")
        #expect(calendar.isProbableDuplicate(of: inside))
        #expect(!calendar.isProbableDuplicate(of: outside))
    }

    @Test("An empty title never matches another empty title")
    func emptyTitlesAreNeverDuplicates() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let a = NormalizedEvent(sourceID: "1", sourceType: .eventkit, title: "  ",
                                startDate: start, calendarID: "c", calendarName: "n")
        let b = NormalizedEvent(sourceID: "2", sourceType: .ticktick, title: "!!!",
                                startDate: start, calendarID: "p", calendarName: "n")
        #expect(!a.isProbableDuplicate(of: b))
    }
}
