import Foundation
import SwiftData
import Testing
@testable import ForerunCore

/// Round-trips through a store that is genuinely closed and reopened, not just a context
/// re-fetch. An in-memory container never exercises the on-disk encoding, and the acceptance
/// criterion is "100% of models persist and reload" — which is a claim about disk.
@MainActor
private final class TemporaryStore {
    let url: URL
    private(set) var container: ModelContainer

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forerun-tests-\(UUID().uuidString)")
            .appendingPathExtension("store")
        container = try Self.makeContainer(at: url)
    }

    private static func makeContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Schema(SchemaV1.models),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(SchemaV1.models),
            migrationPlan: ForerunMigrationPlan.self,
            configurations: configuration
        )
    }

    /// Drops the container entirely and builds a new one against the same file.
    func reopen() throws {
        container = try Self.makeContainer(at: url)
    }

    func cleanUp() {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}

@Suite("On-disk round trips")
@MainActor
struct RoundTripTests {

    @Test("Every model in the schema survives a close and reopen with its fields intact")
    func allSevenModelsRoundTrip() throws {
        let store = try TemporaryStore()
        defer { store.cleanUp() }

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let fireDate = start.addingTimeInterval(-7 * 86_400)
        // Big enough that SwiftData actually spills it to external storage.
        let blob = Data(repeating: 0xAB, count: 300_000)

        do {
            let context = ModelContext(store.container)

            let event = TrackedEvent(
                sourceID: "ek-1|123.0",
                sourceType: .eventkit,
                title: "Sunday Morning Service",
                notes: "Doors at 8:15",
                startDate: start,
                endDate: start.addingTimeInterval(5_400),
                isAllDay: false,
                location: "Main auditorium",
                calendarID: "cal-1",
                calendarName: "Ministry",
                colorHex: "#C0392B",
                colorFamily: .red,
                priority: 5,
                hasRecurrenceRules: true,
                kind: .volunteerTeamEvent,
                kindConfidence: 0.95,
                kindWasConfirmedByUser: true
            )

            let plan = PrepPlan(
                playbookID: "volunteerTeamEvent",
                wasCompressed: true,
                droppedStepCount: 2
            )
            let step = PrepStep(
                order: 3,
                offsetSeconds: -7 * 86_400,
                fireDate: fireDate,
                audience: .leaders,
                actionVerb: "Confirm",
                templateCopy: "Chase unconfirmed leads.",
                generatedCopy: "Chase the two leads who haven't replied.",
                userEditedCopy: "Text Sarah and Mike about Sunday.",
                isCore: true,
                state: .snoozed,
                userPinnedTime: true,
                playbookStepID: "volunteerTeamEvent.d-7.leaders"
            )
            step.snoozedUntil = fireDate.addingTimeInterval(86_400)
            step.handedOffAt = fireDate
            plan.steps = [step]
            event.plan = plan

            event.scratchpad = [ScratchpadItem(
                kind: .photo,
                text: "Whiteboard from Tuesday",
                imageData: blob,
                sortOrder: 2
            )]
            event.contacts = [EventContact(
                contactIdentifier: "cn-42",
                displayName: "Sarah",
                audience: .leaders
            )]

            context.insert(event)
            context.insert(StepOutcome(
                playbookStepID: "volunteerTeamEvent.d-21.leaders",
                kind: .volunteerTeamEvent,
                audience: .leaders,
                offsetSeconds: -21 * 86_400,
                state: .skipped,
                fromNotification: true
            ))

            let settings = try AppSettings.loadOrCreate(in: context)
            settings.quietHoursStart = 23
            settings.quietHoursEnd = 6
            settings.dailyNotificationBudget = 4
            settings.maxStepsPerEvent = 7
            settings.preferredDeliveryHour = 9
            settings.trackedCalendarIDs = ["cal-1", "cal-2"]
            settings.autoTrackColorFamilies = ["red", "blue"]
            settings.enabledKinds = ["volunteerTeamEvent", "teachingPrep"]
            settings.manuallyExcludedSourceIDs = ["ek-9|1.0"]
            settings.manuallyIncludedSourceIDs = ["ek-8|2.0"]
            settings.hasCompletedOnboarding = true
            settings.writeBackCalendarID = "cal-work"
            settings.tickTickRedProjectIDs = ["proj-1"]

            try context.save()
        }

        try store.reopen()
        let context = ModelContext(store.container)

        // TrackedEvent
        let event = try #require(try context.fetch(FetchDescriptor<TrackedEvent>()).first)
        #expect(event.sourceID == "ek-1|123.0")
        #expect(event.sourceType == .eventkit)
        #expect(event.title == "Sunday Morning Service")
        #expect(event.notes == "Doors at 8:15")
        #expect(event.startDate == start)
        #expect(event.endDate == start.addingTimeInterval(5_400))
        #expect(event.location == "Main auditorium")
        #expect(event.colorHex == "#C0392B")
        #expect(event.colorFamily == .red)
        #expect(event.priority == 5)
        #expect(event.hasRecurrenceRules)
        #expect(event.kind == .volunteerTeamEvent)
        #expect(event.kindConfidence == 0.95)
        #expect(event.kindWasConfirmedByUser)

        // PrepPlan
        let plan = try #require(event.plan)
        #expect(plan.playbookID == "volunteerTeamEvent")
        #expect(plan.wasCompressed)
        #expect(plan.droppedStepCount == 2)

        // PrepStep — including the copy-precedence chain
        let step = try #require(plan.steps.first)
        #expect(step.order == 3)
        #expect(step.offsetSeconds == -7 * 86_400)
        #expect(step.fireDate == fireDate)
        #expect(step.audience == .leaders)
        #expect(step.actionVerb == "Confirm")
        #expect(step.templateCopy == "Chase unconfirmed leads.")
        #expect(step.generatedCopy == "Chase the two leads who haven't replied.")
        #expect(step.userEditedCopy == "Text Sarah and Mike about Sunday.")
        #expect(step.effectiveCopy == "Text Sarah and Mike about Sunday.")
        #expect(step.isCore)
        #expect(step.state == .snoozed)
        #expect(step.userPinnedTime)
        #expect(step.playbookStepID == "volunteerTeamEvent.d-7.leaders")
        #expect(step.snoozedUntil == fireDate.addingTimeInterval(86_400))
        #expect(step.handedOffAt == fireDate)

        // ScratchpadItem — the external-storage blob is the riskiest column in the schema
        let item = try #require(event.scratchpad.first)
        #expect(item.kind == .photo)
        #expect(item.text == "Whiteboard from Tuesday")
        #expect(item.sortOrder == 2)
        #expect(item.imageData?.count == 300_000)
        #expect(item.imageData?.first == 0xAB)
        #expect(item.imageData?.last == 0xAB)

        // EventContact
        let contact = try #require(event.contacts.first)
        #expect(contact.contactIdentifier == "cn-42")
        #expect(contact.displayName == "Sarah")
        #expect(contact.audience == .leaders)

        // StepOutcome
        let outcome = try #require(try context.fetch(FetchDescriptor<StepOutcome>()).first)
        #expect(outcome.playbookStepID == "volunteerTeamEvent.d-21.leaders")
        #expect(outcome.kind == .volunteerTeamEvent)
        #expect(outcome.audience == .leaders)
        #expect(outcome.offsetSeconds == -21 * 86_400)
        #expect(outcome.state == .skipped)
        #expect(outcome.fromNotification)

        // AppSettings — every array column, not just the scalars
        let settings = try AppSettings.loadOrCreate(in: context)
        #expect(settings.quietHoursStart == 23)
        #expect(settings.quietHoursEnd == 6)
        #expect(settings.dailyNotificationBudget == 4)
        #expect(settings.maxStepsPerEvent == 7)
        #expect(settings.preferredDeliveryHour == 9)
        #expect(settings.trackedCalendarIDs == ["cal-1", "cal-2"])
        #expect(settings.autoTrackFamilies == [.red, .blue])
        #expect(settings.enabledKinds == ["volunteerTeamEvent", "teachingPrep"])
        #expect(settings.manuallyExcludedSourceIDs == ["ek-9|1.0"])
        #expect(settings.manuallyIncludedSourceIDs == ["ek-8|2.0"])
        #expect(settings.hasCompletedOnboarding)
        #expect(settings.writeBackCalendarID == "cal-work")
        #expect(settings.tickTickRedProjectIDs == ["proj-1"])
        #expect(try context.fetchCount(FetchDescriptor<AppSettings>()) == 1)
    }

    @Test("Settings written in one session are still there in the next")
    func settingsSurviveRelaunch() throws {
        let store = try TemporaryStore()
        defer { store.cleanUp() }

        do {
            let context = ModelContext(store.container)
            let settings = try AppSettings.loadOrCreate(in: context)
            settings.preferredDeliveryHour = 11
            settings.trackedCalendarIDs = ["keep-me"]
            try context.save()
        }

        try store.reopen()
        let context = ModelContext(store.container)
        let settings = try AppSettings.loadOrCreate(in: context)
        #expect(settings.preferredDeliveryHour == 11)
        #expect(settings.trackedCalendarIDs == ["keep-me"])
        #expect(try context.fetchCount(FetchDescriptor<AppSettings>()) == 1)
    }

    @Test("Outcomes past the retention window are pruned and recent ones are not")
    func outcomePruningRespectsTheWindow() throws {
        let store = try TemporaryStore()
        defer { store.cleanUp() }
        let context = ModelContext(store.container)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func outcome(daysAgo: Int) -> StepOutcome {
            StepOutcome(
                playbookStepID: "volunteerTeamEvent.d-21.leaders",
                kind: .volunteerTeamEvent,
                audience: .leaders,
                offsetSeconds: -21 * 86_400,
                state: .skipped,
                decidedAt: now.addingTimeInterval(-Double(daysAgo) * 86_400)
            )
        }
        context.insert(outcome(daysAgo: 400))
        context.insert(outcome(daysAgo: 366))
        context.insert(outcome(daysAgo: 300))
        context.insert(outcome(daysAgo: 1))
        try context.save()

        let pruned = StepOutcome.prune(in: context, now: now)
        try context.save()
        #expect(pruned == 2)
        #expect(try context.fetchCount(FetchDescriptor<StepOutcome>()) == 2)
    }
}

// MARK: - Regressions from the Sprint 1 gate

@Suite("Sprint 1 gate regressions")
struct GateRegressionTests {

    @Test("A title with a variation selector normalizes the same as one without")
    func variationSelectorsDoNotBreakDedup() {
        let withSelector = NormalizedEvent(sourceID: "1", sourceType: .eventkit, title: "☕️ Coffee",
                                           startDate: .now, calendarID: "c", calendarName: "n")
        let without = NormalizedEvent(sourceID: "2", sourceType: .ticktick, title: "☕ Coffee",
                                      startDate: .now, calendarID: "p", calendarName: "n")
        #expect(withSelector.normalizedTitle == "coffee")
        #expect(without.normalizedTitle == "coffee")
        #expect(withSelector.isProbableDuplicate(of: without))
    }

    @Test("Two different emoji-only titles do not collapse into the same key")
    func emojiOnlyTitlesDoNotFalselyMatch() {
        let heart = NormalizedEvent(sourceID: "1", sourceType: .eventkit, title: "❤️",
                                    startDate: .now, calendarID: "c", calendarName: "n")
        let smile = NormalizedEvent(sourceID: "2", sourceType: .ticktick, title: "☺️",
                                    startDate: .now, calendarID: "p", calendarName: "n")
        #expect(heart.normalizedTitle.isEmpty)
        #expect(smile.normalizedTitle.isEmpty)
        #expect(!heart.isProbableDuplicate(of: smile))
    }

    @Test("Exotic titles normalize without crashing")
    func exoticTitlesAreSafe() {
        let titles = ["👨‍👩‍👧‍👦 Family night", "🇺🇸 Fourth of July", "नमस्ते सभा",
                      "e\u{0301}glise", "𝐁𝐨𝐥𝐝 meeting", "🏳️‍🌈 Pride picnic"]
        for title in titles {
            let event = NormalizedEvent(sourceID: title, sourceType: .eventkit, title: title,
                                        startDate: .now, calendarID: "c", calendarName: "n")
            _ = event.normalizedTitle
        }
        let accented = NormalizedEvent(sourceID: "a", sourceType: .eventkit, title: "e\u{0301}glise",
                                       startDate: .now, calendarID: "c", calendarName: "n")
        #expect(accented.normalizedTitle == "eglise")
    }

    @Test("An unreadable audience falls back to leaders, keeping the step inside invariant 2")
    func audienceFallsBackToLeaders() {
        let step = PrepStep(order: 0, offsetSeconds: -86_400, fireDate: .now, audience: .leaders,
                            actionVerb: "Send", templateCopy: "x", playbookStepID: "x")
        step.audienceRaw = "elders"
        #expect(step.audience == .leaders)
        #expect(step.audience.isLeadership)
        #expect(step.audience.isContactable)
    }

    @Test("An unreadable state falls back to skipped so finished work is never re-armed")
    func stateFallsBackToSkipped() {
        let step = PrepStep(order: 0, offsetSeconds: -86_400, fireDate: .now, audience: .leaders,
                            actionVerb: "Send", templateCopy: "x", playbookStepID: "x")
        step.stateRaw = "half-done"
        #expect(step.state == .skipped)
        #expect(!step.state.isSchedulable)
    }

    @Test("Assigning the same state twice does not rewrite the transition time")
    func redundantStateWritesAreIgnored() {
        let step = PrepStep(order: 0, offsetSeconds: -86_400, fireDate: .now, audience: .leaders,
                            actionVerb: "Send", templateCopy: "x", playbookStepID: "x")
        step.state = .done
        let stamped = step.stateChangedAt
        #expect(stamped != nil)
        step.state = .done
        #expect(step.stateChangedAt == stamped)
    }

    @Test("Applying a sync record for a different event is refused")
    func applyRefusesAMismatchedRecord() {
        let event = TrackedEvent(sourceID: "ek-1|1.0", sourceType: .eventkit, title: "Original",
                                 startDate: Date(timeIntervalSinceReferenceDate: 0),
                                 calendarID: "c", calendarName: "n")
        event.apply(NormalizedEvent(sourceID: "ek-2|9.0", sourceType: .eventkit, title: "Someone else's",
                                    startDate: Date(timeIntervalSinceReferenceDate: 99_999),
                                    calendarID: "c", calendarName: "n"))
        #expect(event.title == "Original")
        #expect(event.startDate == Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test("Relative labels report hours in hours, not as a rounded-up day")
    func relativeLabelSplitsHoursFromDays() {
        func label(_ offset: TimeInterval) -> String {
            PrepStep(order: 0, offsetSeconds: offset, fireDate: .now, audience: .me,
                     actionVerb: "x", templateCopy: "x", playbookStepID: "x").relativeLabel
        }
        #expect(label(-2 * 3_600) == "2 hours before")
        #expect(label(-12 * 3_600) == "12 hours before")
        #expect(label(-18 * 3_600) == "18 hours before")
        #expect(label(-23 * 3_600) == "23 hours before")
        #expect(label(-86_400) == "1 day before")
        #expect(label(-3 * 86_400) == "3 days before")
        #expect(label(86_400) == "1 day after")
        #expect(label(-1_800) == "at the start")
    }

    @Test("An eight-digit hex with a trailing zero pair is read as ARGB, not as transparent")
    func eightDigitHexDisambiguates() {
        // CSS reading: #RRGGBBAA. Trailing FF is opaque, so the leading six are the colour.
        #expect(ColorFamily.from(hex: "#34C759FF") == .green)
        // Trailing 00 would mean fully transparent, which no calendar publishes — so this is
        // Android's #AARRGGBB with an opaque-black alpha.
        #expect(ColorFamily.from(hex: "#FF000000") == .gray)
        #expect(ColorFamily.from(hex: "#00000000") == .gray)
    }

    @Test("Deduplication returns events in chronological order, not grouped by source")
    func deduplicationPreservesChronology() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let task = NormalizedEvent(sourceID: "tt-1", sourceType: .ticktick, title: "File taxes",
                                   startDate: base, calendarID: "p", calendarName: "Admin")
        let event = NormalizedEvent(sourceID: "ek-1", sourceType: .eventkit, title: "Service",
                                    startDate: base.addingTimeInterval(86_400),
                                    calendarID: "c", calendarName: "Ministry")
        let result = TrackingRules.deduplicate([event, task])
        #expect(result.kept.map(\.sourceID) == ["tt-1", "ek-1"])
    }
}
