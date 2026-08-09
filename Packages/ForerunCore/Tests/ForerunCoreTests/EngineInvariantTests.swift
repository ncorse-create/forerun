import Foundation
import Testing
@testable import ForerunCore

// MARK: - Fixtures

/// A fixed instant so every test reads the same clock. Wednesday 2026-03-04 09:00 in New York,
/// chosen because it is far from a DST boundary and lands in the middle of a working day.
private let newYork = TimeZone(identifier: "America/New_York") ?? .gmt

private var testCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = newYork
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0,
                  zone: TimeZone = newYork) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(
        timeZone: zone, year: year, month: month, day: day, hour: hour, minute: minute
    )) ?? Date(timeIntervalSinceReferenceDate: 0)
}

private let now = date(2026, 3, 4, 9)

private func input(
    title: String = "Sunday Morning Service",
    start: Date,
    isAllDay: Bool = false,
    kind: EventKind = .volunteerTeamEvent
) -> PlanInput {
    PlanInput(title: title, startDate: start, isAllDay: isAllDay, kind: kind)
}

private func context(
    now: Date = now,
    busy: [DateInterval] = [],
    existing: [Date] = [],
    pinned: [PinnedStep] = [],
    zone: TimeZone = newYork
) -> SchedulingContext {
    SchedulingContext(
        busyWindows: busy,
        existingFireDates: existing,
        pinnedSteps: pinned,
        now: now,
        timeZone: zone
    )
}

private extension PlanDraft {
    func step(_ id: String) -> StepDraft? { steps.first { $0.playbookStepID == id } }
    var ids: [String] { steps.map(\.playbookStepID) }
}

// MARK: - The ten invariants

@Suite("Engine invariants")
struct EngineInvariantTests {

    @Test("Invariant 1 — no step is ever scheduled in the past")
    func invariant1_noStepFiresInThePast() {
        for daysOut in [0, 1, 2, 3, 5, 8, 13, 21, 30, 45] {
            for kind in EventKind.selectable {
                let start = now.addingTimeInterval(Double(daysOut) * 86_400)
                let draft = PrepPlanBuilder.build(
                    input: input(start: start, kind: kind),
                    settings: .default,
                    context: context()
                )
                for step in draft.steps {
                    #expect(step.fireDate > now,
                            "\(kind.rawValue) at +\(daysOut)d scheduled \(step.playbookStepID) in the past")
                }
            }
        }
    }

    @Test("Invariant 1 — a short run-up compresses the ladder instead of dropping to nothing")
    func invariant1_shortLeadTimeCompresses() {
        let start = now.addingTimeInterval(5 * 86_400)
        let draft = PrepPlanBuilder.build(
            input: input(start: start),
            settings: .default,
            context: context()
        )
        #expect(draft.wasCompressed)
        #expect(!draft.steps.isEmpty)
        #expect(draft.steps.allSatisfy { $0.fireDate <= start })
    }

    @Test("Invariant 1 — a full run-up is not compressed and keeps the playbook's own offsets")
    func invariant1_longLeadTimeIsNotCompressed() {
        let start = now.addingTimeInterval(30 * 86_400)
        let draft = PrepPlanBuilder.build(
            input: input(start: start),
            settings: .default,
            context: context()
        )
        #expect(!draft.wasCompressed)
        let first = draft.step("volunteerTeamEvent.d-21.leaders")
        #expect(first != nil)
        // −21d from a 09:00 event is 09:00 three weeks earlier — outside quiet hours, so nothing
        // should have moved it.
        #expect(first?.fireDate == start.addingTimeInterval(-21 * 86_400))
    }

    @Test("Invariant 2 — every leader step in the run-up fires strictly before every participant step")
    func invariant2_leadersAlwaysPrecedeParticipants() {
        // Swept across every cap, not just the default. At the default cap of 5 the +1d
        // follow-up is dropped, which made this pass for the wrong reason — it was not
        // exercising the configurations where a post-event leader step actually exists.
        for cap in 3...8 {
            for daysOut in [1, 2, 3, 4, 5, 7, 10, 14, 21, 30, 60] {
                var settings = EngineSettings.default
                settings.maxStepsPerEvent = cap
                let start = now.addingTimeInterval(Double(daysOut) * 86_400)
                let draft = PrepPlanBuilder.build(
                    input: input(start: start),
                    settings: settings,
                    context: context()
                )
                let runUp = draft.steps.filter { $0.offsetSeconds < 0 }
                let leaderLatest = runUp.filter { $0.audience.isLeadership }.map(\.fireDate).max()
                let audienceEarliest = runUp.filter { $0.audience.isAudienceSide }.map(\.fireDate).min()
                if let leaderLatest, let audienceEarliest {
                    #expect(leaderLatest < audienceEarliest,
                            "cap \(cap), +\(daysOut)d: a participant step fires at or before a leader step" as Comment)
                }
            }
        }
    }

    @Test("Invariant 6 — the daily budget holds even when deferral has nowhere left to go")
    func invariant6_budgetHoldsWhenDeferralFails() {
        // The engine gate's finding: when `resolveBudget` could find no earlier day it returned
        // nil, and the caller read that as "keep the original date" — putting eight
        // notifications on a six-per-day budget under stock settings.
        let settings = EngineSettings.default
        let start = now.addingTimeInterval(1.5 * 86_400)

        var saturating: [Date] = []
        for dayOffset in 0..<3 {
            for slot in 0..<settings.dailyNotificationBudget {
                saturating.append(now.addingTimeInterval(
                    Double(dayOffset) * 86_400 + Double(slot) * 600
                ))
            }
        }

        let draft = PrepPlanBuilder.build(
            input: input(start: start),
            settings: settings,
            context: context(existing: saturating)
        )

        var perDay = Dictionary(grouping: saturating) { testCalendar.startOfDay(for: $0) }
            .mapValues(\.count)
        for step in draft.steps {
            perDay[testCalendar.startOfDay(for: step.fireDate), default: 0] += 1
        }
        for (day, count) in perDay {
            #expect(count <= settings.dailyNotificationBudget,
                    "\(count) notifications on \(day) against a budget of \(settings.dailyNotificationBudget)" as Comment)
        }
    }

    @Test("Invariant 6 — three events planned in sequence still share one budget")
    func invariant6_sequentialEventsShareTheBudget() {
        var settings = EngineSettings.default
        settings.dailyNotificationBudget = 3
        settings.maxStepsPerEvent = 8

        var committed: [Date] = []
        for offset in [0.75, 1.5, 2.25] {
            let draft = PrepPlanBuilder.build(
                input: input(title: "Event", start: now.addingTimeInterval(offset * 86_400)),
                settings: settings,
                context: context(existing: committed)
            )
            committed += draft.steps.map(\.fireDate)
        }

        let perDay = Dictionary(grouping: committed) { testCalendar.startOfDay(for: $0) }
        for (day, dates) in perDay {
            #expect(dates.count <= settings.dailyNotificationBudget, "\(dates.count) on \(day)" as Comment)
        }
    }

    @Test("An event exactly at the playbook's maximum lead time keeps its first rung")
    func exactMaximumLeadTimeKeepsEveryStep() {
        var settings = EngineSettings.default
        settings.maxStepsPerEvent = 8
        let lead = PlaybookLibrary.volunteerTeamEvent.maximumLeadTime
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(lead)),
            settings: settings,
            context: context()
        )
        #expect(draft.step("volunteerTeamEvent.d-21.leaders") != nil)
        #expect(draft.steps.count == 8)
    }

    @Test("The compression banner's count excludes steps the user's own cap removed")
    func droppedCountsAreSeparated() {
        var settings = EngineSettings.default
        settings.maxStepsPerEvent = 5
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(45 * 86_400)),
            settings: settings,
            context: context()
        )
        #expect(!draft.wasCompressed)
        #expect(draft.droppedStepCount == 3)
        #expect(draft.droppedToCapCount == 3)
        #expect(draft.droppedToCompressionCount == 0)
    }

    @Test("A snooze never lands over budget, inside quiet hours, or in a meeting")
    func snoozeRespectsEveryPlacementRule() {
        var settings = EngineSettings.default
        settings.dailyNotificationBudget = 2

        // Today is full, tomorrow morning is a long meeting.
        let saturating = (0..<2).map { now.addingTimeInterval(Double($0) * 600) }
        let meeting = DateInterval(
            start: date(2026, 3, 5, 7),
            end: date(2026, 3, 5, 9, 30)
        )

        let placed = PrepPlanBuilder.placeSnooze(
            desired: now.addingTimeInterval(86_400),
            offsetSeconds: 86_400,
            eventStart: now.addingTimeInterval(-3_600),
            isAllDay: false,
            settings: settings,
            context: context(busy: [meeting], existing: saturating)
        )

        guard let placed else { return }   // "nowhere legal" is a valid answer
        #expect(!meeting.contains(placed))
        #expect(!PrepPlanBuilder.isInQuietHours(placed, settings: settings, calendar: testCalendar))
        let sameDay = saturating.filter { testCalendar.isDate($0, inSameDayAs: placed) }
        #expect(sameDay.count < settings.dailyNotificationBudget)
    }

    @Test("A snooze with nowhere legal to go says so instead of inventing a slot")
    func snoozeReportsWhenThereIsNoRoom() {
        var settings = EngineSettings.default
        settings.dailyNotificationBudget = 2

        // Every day for a month is already at budget.
        var saturating: [Date] = []
        for day in 0..<30 {
            for slot in 0..<2 {
                saturating.append(now.addingTimeInterval(Double(day) * 86_400 + Double(slot) * 600))
            }
        }

        let placed = PrepPlanBuilder.placeSnooze(
            desired: now.addingTimeInterval(86_400),
            offsetSeconds: 86_400,
            eventStart: now.addingTimeInterval(-3_600),
            isAllDay: false,
            settings: settings,
            context: context(existing: saturating)
        )
        #expect(placed == nil)
    }

    @Test("Invariant 2 — a post-event follow-up to leaders does not delete the participant step")
    func invariant2_followUpsDoNotCountAsLeaderOrdering() {
        var settings = EngineSettings.default
        settings.maxStepsPerEvent = 8
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(30 * 86_400)),
            settings: settings,
            context: context()
        )
        // The volunteer playbook ends with a +1d "thank your leads" step. If that counted as
        // the latest leader step, the −24h "message the students" rung would be dropped from
        // every team event.
        #expect(draft.step("volunteerTeamEvent.d1.leaders") != nil)
        #expect(draft.step("volunteerTeamEvent.h-24.participants") != nil)
        #expect(draft.steps.count == 8)
    }

    @Test("Invariant 2 — when compression would break the ordering, participants are dropped, not leaders")
    func invariant2_compressionDropsParticipantsFirst() {
        // Two days out, the eight-step volunteer ladder has to squeeze hard.
        let start = now.addingTimeInterval(2 * 86_400)
        let draft = PrepPlanBuilder.build(
            input: input(start: start),
            settings: .default,
            context: context()
        )
        let leaderCount = draft.steps.filter { $0.audience.isLeadership }.count
        #expect(leaderCount > 0, "compression must never leave a team event with no leader step")

        let leaderLatest = draft.steps.filter { $0.audience.isLeadership }.map(\.fireDate).max()
        let audienceEarliest = draft.steps.filter { $0.audience.isAudienceSide }.map(\.fireDate).min()
        if let leaderLatest, let audienceEarliest {
            #expect(leaderLatest < audienceEarliest)
        }
    }

    @Test("Invariant 3 — the per-event cap is never exceeded")
    func invariant3_stepCapHolds() {
        for limit in 3...8 {
            var settings = EngineSettings.default
            settings.maxStepsPerEvent = limit
            let draft = PrepPlanBuilder.build(
                input: input(start: now.addingTimeInterval(45 * 86_400)),
                settings: settings,
                context: context()
            )
            #expect(draft.steps.count <= limit, "limit \(limit) produced \(draft.steps.count) steps")
        }
    }

    @Test("Invariant 3 — non-core steps are dropped before core ones, latest offset first")
    func invariant3_nonCoreDropsFirst() {
        var settings = EngineSettings.default
        settings.maxStepsPerEvent = 5
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(45 * 86_400)),
            settings: settings,
            context: context()
        )
        // The volunteer playbook has five core steps and three non-core (−3d, −2h, +1d).
        #expect(draft.steps.allSatisfy { $0.isCore })
        #expect(draft.step("volunteerTeamEvent.d1.leaders") == nil)
        #expect(draft.step("volunteerTeamEvent.h-2.self") == nil)
        #expect(draft.step("volunteerTeamEvent.d-3.leaders") == nil)
    }

    @Test("Invariant 4 — nothing fires inside quiet hours")
    func invariant4_quietHoursAreRespected() {
        let settings = EngineSettings.default
        // A 23:30 event drags several offsets into the small hours.
        let start = date(2026, 4, 15, 23, 30)
        let draft = PrepPlanBuilder.build(
            input: input(start: start, kind: .teachingPrep),
            settings: settings,
            context: context()
        )
        #expect(!draft.steps.isEmpty)
        for step in draft.steps {
            #expect(!PrepPlanBuilder.isInQuietHours(step.fireDate, settings: settings, calendar: testCalendar),
                    "\(step.playbookStepID) fired inside quiet hours")
        }
    }

    @Test("Invariant 4 — a step shifted out of quiet hours lands on the preferred delivery hour")
    func invariant4_shiftedStepsLandOnTheDeliveryHour() {
        let settings = EngineSettings.default
        let start = date(2026, 4, 15, 23, 30)
        let draft = PrepPlanBuilder.build(
            input: input(start: start, kind: .teachingPrep),
            settings: settings,
            context: context()
        )
        let moved = draft.steps.filter {
            testCalendar.component(.hour, from: $0.fireDate) != 23
        }
        #expect(!moved.isEmpty)
        for step in moved {
            #expect(testCalendar.component(.hour, from: step.fireDate) == settings.preferredDeliveryHour,
                    "\(step.playbookStepID) landed at an hour that is neither its own nor the delivery hour")
        }
    }

    @Test("Invariant 4 — quiet hours off means nothing is shifted")
    func invariant4_quietHoursCanBeTurnedOff() {
        var settings = EngineSettings.default
        settings.quietHoursStart = 0
        settings.quietHoursEnd = 0
        let start = date(2026, 4, 15, 23, 30)
        let draft = PrepPlanBuilder.build(
            input: input(start: start, kind: .teachingPrep),
            settings: settings,
            context: context()
        )
        for step in draft.steps where step.offsetSeconds <= -86_400 {
            #expect(testCalendar.component(.hour, from: step.fireDate) == 23)
        }
    }

    @Test("Invariant 5 — nothing fires while another tracked event is in progress")
    func invariant5_busyWindowsAreAvoided() {
        let settings = EngineSettings.default
        let start = now.addingTimeInterval(30 * 86_400)
        // Block the exact instants the untouched ladder would have used.
        let busy = (1...21).compactMap { offset -> DateInterval? in
            let point = start.addingTimeInterval(-Double(offset) * 86_400)
            return DateInterval(start: point.addingTimeInterval(-1_800), duration: 3_600)
        }
        let draft = PrepPlanBuilder.build(
            input: input(start: start),
            settings: settings,
            context: context(busy: busy)
        )
        #expect(!draft.steps.isEmpty)
        for step in draft.steps {
            #expect(!busy.contains { $0.contains(step.fireDate) },
                    "\(step.playbookStepID) fired during a tracked event")
        }
    }

    @Test("Invariant 6 — an over-budget day pushes a step earlier, never later")
    func invariant6_budgetDefersEarlierNeverLater() {
        var settings = EngineSettings.default
        settings.dailyNotificationBudget = 3
        let start = now.addingTimeInterval(30 * 86_400)

        // Saturate the day the −21d step would land on.
        let contested = start.addingTimeInterval(-21 * 86_400)
        let saturating = (0..<3).map { contested.addingTimeInterval(Double($0) * 600) }

        let unconstrained = PrepPlanBuilder.build(
            input: input(start: start),
            settings: settings,
            context: context()
        )
        let constrained = PrepPlanBuilder.build(
            input: input(start: start),
            settings: settings,
            context: context(existing: saturating)
        )

        guard let before = unconstrained.step("volunteerTeamEvent.d-21.leaders"),
              let after = constrained.step("volunteerTeamEvent.d-21.leaders")
        else {
            // Being dropped entirely is also acceptable — what is forbidden is firing later.
            #expect(constrained.step("volunteerTeamEvent.d-21.leaders") == nil)
            return
        }
        #expect(after.fireDate < before.fireDate, "the budget pushed a step later instead of earlier")
    }

    @Test("Invariant 6 — the daily budget holds across every step the plan schedules")
    func invariant6_dailyBudgetHolds() {
        var settings = EngineSettings.default
        settings.dailyNotificationBudget = 3
        settings.maxStepsPerEvent = 8
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(30 * 86_400)),
            settings: settings,
            context: context()
        )
        let perDay = Dictionary(grouping: draft.steps) { testCalendar.startOfDay(for: $0.fireDate) }
        for (day, steps) in perDay {
            #expect(steps.count <= settings.dailyNotificationBudget,
                    "\(steps.count) steps on \(day)" as Comment)
        }
    }

    @Test("Invariant 7 — two steps for one event never fire within four hours of each other")
    func invariant7_minimumGapHolds() {
        for daysOut in [1, 2, 3, 4, 5, 7, 10, 21, 30] {
            for kind in EventKind.selectable {
                let draft = PrepPlanBuilder.build(
                    input: input(start: now.addingTimeInterval(Double(daysOut) * 86_400), kind: kind),
                    settings: .default,
                    context: context()
                )
                let sorted = draft.steps.sorted { $0.fireDate < $1.fireDate }
                for pair in zip(sorted, sorted.dropFirst()) {
                    let gap = pair.1.fireDate.timeIntervalSince(pair.0.fireDate)
                    #expect(gap >= PrepPlanBuilder.minimumInterStepGap,
                            "\(kind.rawValue) +\(daysOut)d: \(pair.0.playbookStepID) then \(pair.1.playbookStepID), only \(Int(gap / 60))m apart")
                }
            }
        }
    }

    @Test("Invariant 8 — a pinned step keeps its exact time through quiet hours, budget and gap")
    func invariant8_pinnedStepsAreExempt() {
        var settings = EngineSettings.default
        settings.dailyNotificationBudget = 1
        let start = now.addingTimeInterval(30 * 86_400)
        // 02:00 is inside quiet hours, and the budget of one is already spent that day.
        let pinnedDate = date(2026, 3, 20, 2, 0)
        let draft = PrepPlanBuilder.build(
            input: input(start: start),
            settings: settings,
            context: context(
                existing: [pinnedDate.addingTimeInterval(3_600)],
                pinned: [PinnedStep(playbookStepID: "volunteerTeamEvent.d-14.leaders", fireDate: pinnedDate)]
            )
        )
        let pinned = draft.step("volunteerTeamEvent.d-14.leaders")
        #expect(pinned?.fireDate == pinnedDate)
        #expect(pinned?.isPinned == true)
    }

    @Test("Invariant 9 — an all-day event anchors to the preferred delivery hour on its date")
    func invariant9_allDayAnchorsToDeliveryHour() {
        var settings = EngineSettings.default
        settings.preferredDeliveryHour = 8
        let allDayStart = testCalendar.startOfDay(for: now.addingTimeInterval(30 * 86_400))
        let draft = PrepPlanBuilder.build(
            input: input(start: allDayStart, isAllDay: true, kind: .teachingPrep),
            settings: settings,
            context: context()
        )
        #expect(!draft.steps.isEmpty)
        for step in draft.steps {
            #expect(testCalendar.component(.hour, from: step.fireDate) == 8,
                    "\(step.playbookStepID) did not anchor to the delivery hour")
        }
    }

    @Test("Invariant 10 — the same plan in a different timezone keeps its local wall-clock hour")
    func invariant10_timezoneIsAppliedNotStored() {
        let settings = EngineSettings.default
        let start = date(2026, 4, 15, 10, 0)
        let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .gmt

        let inNewYork = PrepPlanBuilder.build(
            input: input(start: start, kind: .teachingPrep),
            settings: settings,
            context: context(zone: newYork)
        )
        let inTokyo = PrepPlanBuilder.build(
            input: input(start: start, kind: .teachingPrep),
            settings: settings,
            context: context(zone: tokyo)
        )

        // The event is a fixed instant, so the raw offsets match; what differs is which of them
        // quiet hours catches, because quiet hours are local.
        #expect(!inNewYork.steps.isEmpty)
        #expect(!inTokyo.steps.isEmpty)

        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = tokyo
        for step in inTokyo.steps {
            #expect(!PrepPlanBuilder.isInQuietHours(step.fireDate, settings: settings, calendar: tokyoCalendar))
        }
    }

    @Test("Invariant 10 — a plan spanning spring-forward keeps every step out of quiet hours")
    func invariant10_dstSpringForward() {
        let settings = EngineSettings.default
        // US DST begins 2026-03-08. A 2026-03-20 event's ladder reaches back across it.
        let start = date(2026, 3, 20, 19, 0)
        let draft = PrepPlanBuilder.build(
            input: input(start: start, kind: .volunteerTeamEvent),
            settings: settings,
            context: context(now: date(2026, 2, 20, 9))
        )
        #expect(!draft.steps.isEmpty)
        for step in draft.steps {
            #expect(!PrepPlanBuilder.isInQuietHours(step.fireDate, settings: settings, calendar: testCalendar),
                    "\(step.playbookStepID) crossed spring-forward into quiet hours")
        }
    }

    @Test("Invariant 10 — a plan spanning fall-back keeps every step out of quiet hours")
    func invariant10_dstFallBack() {
        let settings = EngineSettings.default
        // US DST ends 2026-11-01.
        let start = date(2026, 11, 12, 19, 0)
        let draft = PrepPlanBuilder.build(
            input: input(start: start, kind: .volunteerTeamEvent),
            settings: settings,
            context: context(now: date(2026, 10, 14, 9))
        )
        #expect(!draft.steps.isEmpty)
        for step in draft.steps {
            #expect(!PrepPlanBuilder.isInQuietHours(step.fireDate, settings: settings, calendar: testCalendar))
        }
    }
}

// MARK: - The Sprint 4 test matrix

@Suite("Plan builder matrix")
struct PlanBuilderMatrixTests {

    @Test("Thirty days out, the full volunteer ladder survives within the cap")
    func thirtyDaysOutIsUncompressed() {
        var settings = EngineSettings.default
        settings.maxStepsPerEvent = 8
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(30 * 86_400)),
            settings: settings,
            context: context()
        )
        #expect(!draft.wasCompressed)
        #expect(draft.steps.count == 8)
        #expect(draft.droppedStepCount == 0)
    }

    @Test("Five days out, the ladder compresses and leaders still lead")
    func fiveDaysOutCompressesAndKeepsOrdering() {
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(5 * 86_400)),
            settings: .default,
            context: context()
        )
        #expect(draft.wasCompressed)
        #expect(!draft.steps.isEmpty)
        let leaderLatest = draft.steps.filter { $0.audience.isLeadership }.map(\.fireDate).max()
        let audienceEarliest = draft.steps.filter { $0.audience.isAudienceSide }.map(\.fireDate).min()
        if let leaderLatest, let audienceEarliest {
            #expect(leaderLatest < audienceEarliest)
        }
    }

    @Test("Six hours out yields a handful of steps, not the whole playbook")
    func sixHoursOutYieldsAFewSteps() {
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(6 * 3_600)),
            settings: .default,
            context: context()
        )
        #expect(draft.steps.count <= 3, "got \(draft.steps.count): \(draft.ids)" as Comment)
        #expect(draft.wasCompressed)
        #expect(draft.steps.allSatisfy { $0.fireDate > now })
    }

    @Test("An event in the past produces an empty plan and does not crash")
    func pastEventProducesNothing() {
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(-3 * 86_400)),
            settings: .default,
            context: context()
        )
        #expect(draft.isEmpty)
        #expect(!draft.wasCompressed)
    }

    @Test("An event that started an hour ago keeps only its follow-up")
    func inProgressEventKeepsFollowUps() {
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(-3_600), kind: .buildWork),
            settings: .default,
            context: context()
        )
        #expect(draft.ids == ["buildWork.d1.self"])
    }

    @Test("An unclassified event gets no ladder at all")
    func unknownKindGetsNoPlan() {
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(20 * 86_400), kind: .unknown),
            settings: .default,
            context: context()
        )
        #expect(draft.isEmpty)
    }

    @Test("A personal event gets exactly one step — no ladder for a dentist appointment")
    func personalEventsGetOneStep() {
        let draft = PrepPlanBuilder.build(
            input: input(title: "Dentist", start: now.addingTimeInterval(20 * 86_400), kind: .personal),
            settings: .default,
            context: context()
        )
        #expect(draft.steps.count == 1)
        #expect(draft.steps.first?.audience == .me)
    }

    @Test("Two events on the same day share one daily budget")
    func twoEventsShareTheDailyBudget() {
        var settings = EngineSettings.default
        settings.dailyNotificationBudget = 4
        settings.maxStepsPerEvent = 8

        let first = PrepPlanBuilder.build(
            input: input(title: "Service", start: now.addingTimeInterval(30 * 86_400)),
            settings: settings,
            context: context()
        )
        let second = PrepPlanBuilder.build(
            input: input(title: "Youth Night", start: now.addingTimeInterval(30 * 86_400), kind: .studentFacing),
            settings: settings,
            context: context(existing: first.steps.map(\.fireDate))
        )

        let combined = first.steps.map(\.fireDate) + second.steps.map(\.fireDate)
        let perDay = Dictionary(grouping: combined) { testCalendar.startOfDay(for: $0) }
        for (day, dates) in perDay {
            #expect(dates.count <= settings.dailyNotificationBudget, "\(dates.count) on \(day)" as Comment)
        }
    }

    @Test("The event title is substituted into every step's copy")
    func titleIsSubstituted() {
        let draft = PrepPlanBuilder.build(
            input: input(title: "Fall Kickoff", start: now.addingTimeInterval(30 * 86_400)),
            settings: .default,
            context: context()
        )
        let withPlaceholder = draft.steps.filter { $0.templateCopy.contains("{title}") }
        #expect(withPlaceholder.isEmpty)
        #expect(draft.steps.contains { $0.templateCopy.contains("Fall Kickoff") })
    }

    @Test("Steps are ordered contiguously from zero, in fire-date order")
    func ordersAreContiguousAndChronological() {
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(30 * 86_400)),
            settings: .default,
            context: context()
        )
        #expect(draft.steps.map(\.order) == Array(0..<draft.steps.count))
        let dates = draft.steps.map(\.fireDate)
        #expect(dates == dates.sorted())
    }

    @Test("The stored offset is the playbook's own, never the compressed one")
    func compressionDoesNotBakeItselfIntoTheOffset() {
        let draft = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(4 * 86_400)),
            settings: .default,
            context: context()
        )
        #expect(draft.wasCompressed)
        for step in draft.steps {
            let playbookStep = PlaybookLibrary.volunteerTeamEvent.steps
                .first { $0.id == step.playbookStepID }
            #expect(step.offsetSeconds == playbookStep?.offset)
        }
    }

    @Test("A delivery hour set inside quiet hours resolves rather than looping forever")
    func deliveryHourInsideQuietHoursIsResolved() {
        var settings = EngineSettings.default
        settings.preferredDeliveryHour = 3    // inside 22 → 7
        let draft = PrepPlanBuilder.build(
            input: input(start: date(2026, 4, 15, 23, 30), kind: .teachingPrep),
            settings: settings,
            context: context()
        )
        #expect(!draft.steps.isEmpty)
        for step in draft.steps {
            #expect(!PrepPlanBuilder.isInQuietHours(step.fireDate, settings: settings, calendar: testCalendar))
        }
        #expect(PrepPlanBuilder.deliveryHour(for: settings) == settings.quietHoursEnd)
    }

    @Test("Every playbook produces a plan at a comfortable lead time")
    func everyPlaybookProducesAPlan() {
        for kind in EventKind.selectable {
            let draft = PrepPlanBuilder.build(
                input: input(start: now.addingTimeInterval(45 * 86_400), kind: kind),
                settings: .default,
                context: context()
            )
            #expect(!draft.isEmpty, "\(kind.rawValue) produced no steps")
        }
    }

    @Test("Playbook step identifiers are unique across the whole library")
    func playbookStepIDsAreUnique() {
        let ids = PlaybookLibrary.all.flatMap { $0.steps.map(\.id) }
        #expect(Set(ids).count == ids.count)
    }
}

// MARK: - Regeneration

@Suite("Plan regeneration")
struct PlanRegeneratorTests {

    private func draft(daysOut: Double = 30) -> PlanDraft {
        PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(daysOut * 86_400)),
            settings: EngineSettings(maxStepsPerEvent: 8),
            context: context()
        )
    }

    @Test("An edited sentence survives a rebuild but still follows the event when it moves")
    func editedCopySurvivesButStillMoves() {
        let original = draft()
        let moved = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(37 * 86_400)),
            settings: EngineSettings(maxStepsPerEvent: 8),
            context: context()
        )
        let existing = original.steps.map {
            ExistingStep(
                playbookStepID: $0.playbookStepID,
                fireDate: $0.fireDate,
                state: .pending,
                hasUserEditedCopy: $0.playbookStepID == "volunteerTeamEvent.d-7.leaders"
            )
        }

        let result = PlanRegenerator.merge(existing: existing, draft: moved)
        #expect(result.preservedCount == 1)

        let action = result.actions.compactMap { action -> (Date, Bool)? in
            if case .retime(let id, let fireDate, _, _, let replaceCopy, _) = action,
               id == "volunteerTeamEvent.d-7.leaders" {
                return (fireDate, replaceCopy)
            }
            return nil
        }.first
        #expect(action?.1 == false, "the user's sentence was going to be overwritten")
        #expect(action?.0 == moved.step("volunteerTeamEvent.d-7.leaders")?.fireDate)
    }

    @Test("A pinned time is not moved by a rebuild")
    func pinnedTimesDoNotMove() {
        let original = draft()
        let moved = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(37 * 86_400)),
            settings: EngineSettings(maxStepsPerEvent: 8),
            context: context()
        )
        guard let pinnedStep = original.step("volunteerTeamEvent.d-14.leaders") else {
            Issue.record("fixture missing")
            return
        }
        let existing = [ExistingStep(
            playbookStepID: pinnedStep.playbookStepID,
            fireDate: pinnedStep.fireDate,
            state: .pending,
            userPinnedTime: true
        )]

        let result = PlanRegenerator.merge(existing: existing, draft: moved)
        let retimed = result.actions.compactMap { action -> Date? in
            if case .retime(_, let fireDate, _, _, _, _) = action { return fireDate }
            return nil
        }.first
        #expect(retimed == pinnedStep.fireDate)
    }

    @Test("A custom step is never touched by a rebuild")
    func customStepsAreUntouchable() {
        let existing = [ExistingStep(
            playbookStepID: "custom.\(UUID().uuidString)",
            fireDate: now.addingTimeInterval(86_400),
            state: .pending,
            isCustom: true
        )]
        let result = PlanRegenerator.merge(existing: existing, draft: draft())
        #expect(result.actions.contains { action in
            if case .keep = action { return true }
            return false
        })
        #expect(result.removedCount == 0)
        #expect(result.preservedCount == 1)
    }

    @Test("A step already done or skipped is left alone rather than re-armed")
    func resolvedStepsAreNotRebuilt() {
        let original = draft()
        guard let first = original.steps.first else { return }
        let existing = [ExistingStep(
            playbookStepID: first.playbookStepID,
            fireDate: first.fireDate,
            state: .done
        )]
        let result = PlanRegenerator.merge(existing: existing, draft: original)
        #expect(result.actions.contains { action in
            if case .keep(let id) = action { return id == first.playbookStepID }
            return false
        })
    }

    @Test("A rung that no longer exists is removed when nobody owns it")
    func orphanedStepsAreRemoved() {
        let existing = [ExistingStep(
            playbookStepID: "volunteerTeamEvent.d-3.leaders",
            fireDate: now.addingTimeInterval(86_400),
            state: .pending
        )]
        // Tightening the cap to five drops every non-core rung, −3d among them. Note that
        // compression alone would NOT have dropped it — a squeezed rung is still present, just
        // closer in, which is why this fixture uses the cap rather than a short run-up.
        var settings = EngineSettings.default
        settings.maxStepsPerEvent = 5
        let capped = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(45 * 86_400)),
            settings: settings,
            context: context()
        )
        #expect(capped.step("volunteerTeamEvent.d-3.leaders") == nil)

        let result = PlanRegenerator.merge(existing: existing, draft: capped)
        #expect(result.removedCount == 1)
    }

    @Test("A rebuild clears a stale snooze rather than letting it override the new date")
    func rebuildClearsTheSnooze() {
        let original = draft()
        guard let step = original.step("volunteerTeamEvent.d-7.leaders") else {
            Issue.record("fixture missing")
            return
        }
        let existing = [ExistingStep(
            playbookStepID: step.playbookStepID,
            fireDate: step.fireDate,
            state: .snoozed
        )]
        let result = PlanRegenerator.merge(existing: existing, draft: draft(daysOut: 37))

        let clears = result.actions.compactMap { action -> Bool? in
            if case .retime(_, _, _, _, _, let clearSnooze) = action { return clearSnooze }
            return nil
        }.first
        // Otherwise the scheduler fires on `snoozedUntil` while the engine budgeted for the
        // recomputed `fireDate` — the step can land after its own event, inside quiet hours,
        // and uncounted against the daily cap, all at once.
        #expect(clears == true)
    }

    @Test("A pinned step keeps its snooze, because its time is the user's decision")
    func pinnedStepsKeepTheirSnooze() {
        let original = draft()
        guard let step = original.step("volunteerTeamEvent.d-7.leaders") else { return }
        let existing = [ExistingStep(
            playbookStepID: step.playbookStepID,
            fireDate: step.fireDate,
            state: .snoozed,
            userPinnedTime: true
        )]
        let result = PlanRegenerator.merge(existing: existing, draft: draft(daysOut: 37))
        let clears = result.actions.compactMap { action -> Bool? in
            if case .retime(_, _, _, _, _, let clearSnooze) = action { return clearSnooze }
            return nil
        }.first
        #expect(clears == false)
    }

    @Test("Rewording a step does not make it immune to the per-event cap")
    func editedCopyDoesNotEscapeTheCap() {
        var full = EngineSettings.default
        full.maxStepsPerEvent = 8
        let wide = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(45 * 86_400)),
            settings: full,
            context: context()
        )
        let existing = wide.steps.map {
            ExistingStep(
                playbookStepID: $0.playbookStepID,
                fireDate: $0.fireDate,
                state: .pending,
                hasUserEditedCopy: $0.playbookStepID == "volunteerTeamEvent.d-3.leaders"
            )
        }

        var tight = EngineSettings.default
        tight.maxStepsPerEvent = 3
        let capped = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(45 * 86_400)),
            settings: tight,
            context: context()
        )
        let result = PlanRegenerator.merge(existing: existing, draft: capped)

        let surviving = existing.count - result.removedCount
        #expect(surviving <= tight.maxStepsPerEvent,
                "\(surviving) steps survive a cap of \(tight.maxStepsPerEvent)" as Comment)
    }

    @Test("A reworded rung the new plan dropped is removed, not kept")
    func rewordedOrphansDoNotSurvive() {
        // This asserted the opposite until the QA pass showed what it cost: `isUserOwned`
        // includes `hasUserEditedCopy`, so merely rewording a sentence made a step immune to the
        // per-event cap — a path straight past locked decision 3, which calls the cap hard and
        // unraisable. Invariant 8 exempts `userPinnedTime`, and nothing else.
        let existing = [ExistingStep(
            playbookStepID: "volunteerTeamEvent.d-3.leaders",
            fireDate: now.addingTimeInterval(86_400),
            state: .pending,
            hasUserEditedCopy: true
        )]
        var settings = EngineSettings.default
        settings.maxStepsPerEvent = 5
        let capped = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(45 * 86_400)),
            settings: settings,
            context: context()
        )
        let result = PlanRegenerator.merge(existing: existing, draft: capped)
        #expect(result.removedCount == 1)
        #expect(result.preservedCount == 0)
    }

    @Test("A pinned rung the new plan dropped is kept, because a pin is a deliberate placement")
    func pinnedOrphansSurvive() {
        let existing = [ExistingStep(
            playbookStepID: "volunteerTeamEvent.d-3.leaders",
            fireDate: now.addingTimeInterval(86_400),
            state: .pending,
            userPinnedTime: true
        )]
        var settings = EngineSettings.default
        settings.maxStepsPerEvent = 5
        let capped = PrepPlanBuilder.build(
            input: input(start: now.addingTimeInterval(45 * 86_400)),
            settings: settings,
            context: context()
        )
        let result = PlanRegenerator.merge(existing: existing, draft: capped)
        #expect(result.removedCount == 0)
        #expect(result.preservedCount == 1)
    }

    @Test("The confirmation sentence names how many edits will be kept")
    func confirmationNamesThePreservedCount() {
        let none = PlanMergeResult(actions: [], preservedCount: 0, insertedCount: 0,
                                   removedCount: 0, wasCompressed: false,
                                   droppedStepCount: 0, playbookID: "x")
        #expect(PlanRegenerator.confirmationMessage(for: none).contains("Nothing you've written"))

        var one = none
        one.preservedCount = 1
        #expect(PlanRegenerator.confirmationMessage(for: one).contains("one step"))

        var three = none
        three.preservedCount = 3
        #expect(PlanRegenerator.confirmationMessage(for: three).contains("3 steps"))
    }
}
