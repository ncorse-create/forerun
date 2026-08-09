import ForerunCore
import Foundation
import SwiftData

/// Turns tracked events into dated ladders and keeps them in step with reality.
///
/// The split is deliberate: `PrepPlanBuilder` decides *everything* about timing and does it in
/// pure Swift; this type only moves the result in and out of SwiftData and calls the phraser for
/// wording. Nothing here can change a fire date that the engine did not produce.
@MainActor
@Observable
final class PlanningCoordinator: PlanReconciling {
    private let context: ModelContext
    private var provider: any IntelligenceProvider
    private let settings: AppSettings
    weak var scheduler: NotificationScheduler?

    private(set) var isWorking = false

    init(
        context: ModelContext,
        settings: AppSettings,
        provider: any IntelligenceProvider = HeuristicProvider()
    ) {
        self.context = context
        self.settings = settings
        self.provider = provider
    }

    func use(provider: any IntelligenceProvider) {
        self.provider = provider
    }

    // MARK: PlanReconciling

    func planWasNeeded(for event: TrackedEvent) async {
        await classifyIfNeeded(event)
        await buildPlan(for: event)
    }

    func planNeedsRebuild(for event: TrackedEvent, previousStart: Date) async {
        await rebuildPlan(for: event)
    }

    func schedulingWindowNeedsRefresh() async {
        await scheduler?.refreshWindow(context: context, settings: settings)
    }

    // MARK: Classification

    /// Runs once per event, at track time — never in a loop over a whole calendar sync. A model
    /// call costs seconds on device, so a sweep over sixty days of events would freeze the app.
    func classifyIfNeeded(_ event: TrackedEvent) async {
        guard !event.kindWasConfirmedByUser else { return }
        guard event.kind == .unknown || event.kindConfidence == 0 else { return }

        let normalized = NormalizedEvent(
            sourceID: event.sourceID,
            sourceType: event.sourceType,
            title: event.title,
            notes: event.notes,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            calendarID: event.calendarID,
            calendarName: event.calendarName,
            colorHex: event.colorHex,
            colorFamily: event.colorFamily,
            priority: event.priority,
            hasRecurrenceRules: event.hasRecurrenceRules
        )
        let result = await provider.classify(normalized)
        event.kind = result.kind
        event.kindConfidence = result.confidence
        try? context.save()
    }

    /// The user answered the confirmation chip. Their answer is final and the plan is rebuilt
    /// against the playbook they picked.
    func confirmKind(_ kind: EventKind, for event: TrackedEvent) async {
        event.kind = kind
        event.kindConfidence = 1.0
        event.kindWasConfirmedByUser = true
        await rebuildPlan(for: event)
    }

    // MARK: Building

    func buildPlan(for event: TrackedEvent) async {
        guard settings.enabledEventKinds.contains(event.kind) || event.kindWasConfirmedByUser else { return }
        guard event.plan == nil else {
            await rebuildPlan(for: event)
            return
        }

        let draft = makeDraft(for: event)
        guard !draft.isEmpty else { return }

        let plan = PrepPlan(
            playbookID: draft.playbookID,
            wasCompressed: draft.wasCompressed,
            droppedStepCount: draft.droppedStepCount,
            droppedToCapCount: draft.droppedToCapCount
        )
        plan.steps = draft.steps.map(makeStep(from:))
        event.plan = plan
        context.insert(plan)
        try? context.save()

        await phraseSteps(of: plan, event: event)
        await schedulingWindowNeedsRefresh()
    }

    /// Rebuilds against the current start date, preserving everything a human owns.
    @discardableResult
    func rebuildPlan(for event: TrackedEvent) async -> PlanMergeResult? {
        guard let plan = event.plan else {
            await buildPlan(for: event)
            return nil
        }

        let draft = makeDraft(for: event, pinned: plan.steps.filter(\.userPinnedTime).map {
            PinnedStep(playbookStepID: $0.playbookStepID, fireDate: $0.fireDate)
        })
        let existing = plan.steps.map {
            ExistingStep(
                playbookStepID: $0.playbookStepID,
                fireDate: $0.fireDate,
                state: $0.state,
                hasUserEditedCopy: $0.userEditedCopy != nil,
                userPinnedTime: $0.userPinnedTime,
                isCustom: $0.isCustom
            )
        }

        let result = PlanRegenerator.merge(existing: existing, draft: draft)
        apply(result, to: plan, event: event, draft: draft)
        try? context.save()

        await phraseSteps(of: plan, event: event)
        await schedulingWindowNeedsRefresh()
        return result
    }

    /// The confirmation the Plan screen shows before regenerating, computed without changing
    /// anything — so the count it names is the count that will actually be preserved.
    func regenerationPreview(for event: TrackedEvent) -> PlanMergeResult? {
        guard let plan = event.plan else { return nil }
        let draft = makeDraft(for: event, pinned: plan.steps.filter(\.userPinnedTime).map {
            PinnedStep(playbookStepID: $0.playbookStepID, fireDate: $0.fireDate)
        })
        let existing = plan.steps.map {
            ExistingStep(
                playbookStepID: $0.playbookStepID,
                fireDate: $0.fireDate,
                state: $0.state,
                hasUserEditedCopy: $0.userEditedCopy != nil,
                userPinnedTime: $0.userPinnedTime,
                isCustom: $0.isCustom
            )
        }
        return PlanRegenerator.merge(existing: existing, draft: draft)
    }

    /// Rebuilds every plan. Called when a setting that affects timing changes, and when the
    /// timezone changes — offsets are stored as intervals, so the fix is always to re-derive.
    func rebuildAllPlans() async {
        guard let events = try? context.fetch(FetchDescriptor<TrackedEvent>()) else { return }
        isWorking = true
        defer { isWorking = false }
        for event in events where event.plan != nil {
            await rebuildPlan(for: event)
        }
    }

    // MARK: Snoozing

    /// Snooze goes through the engine's placement rules, not through arithmetic.
    ///
    /// Adding 86,400 seconds to a fire date escaped three invariants at once: it could land in
    /// quiet hours, it ignored the daily budget — so "6 per day across all events" stopped
    /// holding as soon as anything was snoozed — and it could push a pre-event reminder past the
    /// event it was reminding you about.
    ///
    /// Returns false when there is nowhere legal left to put it, which the UI reports as "there
    /// is no later left" rather than silently doing nothing.
    @discardableResult
    func snooze(_ step: PrepStep, by interval: TimeInterval = NotificationDelegate.snoozeInterval) async -> Bool {
        guard let event = step.plan?.event else { return false }
        let desired = (step.snoozedUntil ?? step.fireDate).addingTimeInterval(interval)

        let placed = PrepPlanBuilder.placeSnooze(
            desired: desired,
            offsetSeconds: step.offsetSeconds,
            eventStart: event.startDate,
            isAllDay: event.isAllDay,
            settings: settings.engineSettings,
            context: schedulingContext(excluding: event, pinned: [])
        )
        guard let placed else { return false }

        step.snoozedUntil = placed
        step.state = .snoozed
        try? context.save()
        await scheduler?.refreshWindow(context: context, settings: settings)
        return true
    }

    // MARK: Engine plumbing

    private func makeDraft(for event: TrackedEvent, pinned: [PinnedStep] = []) -> PlanDraft {
        PrepPlanBuilder.build(
            input: event.planInput,
            settings: settings.engineSettings,
            context: schedulingContext(excluding: event, pinned: pinned)
        )
    }

    /// The daily budget is across *all* events, so building one plan has to see what every other
    /// plan already committed to — and the busy windows come from the tracked events themselves.
    private func schedulingContext(
        excluding event: TrackedEvent,
        pinned: [PinnedStep]
    ) -> SchedulingContext {
        let all = (try? context.fetch(FetchDescriptor<TrackedEvent>())) ?? []
        let others = all.filter { $0.id != event.id }

        // `snoozedUntil ?? fireDate` — the same expression the scheduler fires on. Counting the
        // original date instead charged the budget to a day the step will not fire on and left
        // the day it *will* fire on looking empty, so every snooze quietly loosened the cap.
        let existingFireDates = others
            .compactMap(\.plan)
            .flatMap(\.steps)
            .filter { $0.state.isSchedulable }
            .map { $0.snoozedUntil ?? $0.fireDate }

        // Built from `all`, not `others`, on purpose: you should not be reminded about something
        // *during* the event it is about, including the event being planned. `existingFireDates`
        // above correctly uses `others`, since an event's own steps must not consume its budget.
        let busyWindows = all.compactMap { tracked -> DateInterval? in
            guard !tracked.isAllDay else { return nil }
            let end = tracked.endDate ?? tracked.startDate.addingTimeInterval(3_600)
            guard end > tracked.startDate else { return nil }
            return DateInterval(start: tracked.startDate, end: end)
        }

        return SchedulingContext(
            busyWindows: busyWindows,
            existingFireDates: existingFireDates,
            pinnedSteps: pinned,
            now: .now,
            timeZone: .current
        )
    }

    /// Custom steps are namespaced so one can never collide with a playbook rung. A collision
    /// would permanently suppress that rung — regeneration sees the id already present and never
    /// inserts the real one.
    static func customStepID() -> String {
        "custom.\(UUID().uuidString)"
    }

    private func makeStep(from draft: StepDraft) -> PrepStep {
        PrepStep(
            order: draft.order,
            offsetSeconds: draft.offsetSeconds,
            fireDate: draft.fireDate,
            audience: draft.audience,
            actionVerb: draft.actionVerb,
            templateCopy: draft.templateCopy,
            isCore: draft.isCore,
            userPinnedTime: draft.isPinned,
            playbookStepID: draft.playbookStepID
        )
    }

    private func apply(
        _ result: PlanMergeResult,
        to plan: PrepPlan,
        event: TrackedEvent,
        draft: PlanDraft
    ) {
        var byID = Dictionary(
            plan.steps.map { ($0.playbookStepID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for action in result.actions {
            switch action {
            case .keep:
                continue

            case .retime(let id, let fireDate, let order, let templateCopy, let replaceCopy):
                guard let step = byID[id] else { continue }
                step.fireDate = fireDate
                step.order = order
                step.templateCopy = templateCopy
                if replaceCopy {
                    // The template moved, so any sentence generated from the old one is stale.
                    // Clearing it makes the phraser regenerate rather than leaving a sentence
                    // that describes the previous date.
                    step.generatedCopy = nil
                }

            case .insert(let stepDraft):
                let step = makeStep(from: stepDraft)
                step.plan = plan
                plan.steps.append(step)
                context.insert(step)
                byID[stepDraft.playbookStepID] = step

            case .remove(let id):
                guard let step = byID[id] else { continue }
                scheduler?.cancel(step)
                plan.steps.removeAll { $0.id == step.id }
                context.delete(step)
                byID[id] = nil
            }
        }

        plan.playbookID = result.playbookID
        plan.wasCompressed = result.wasCompressed
        plan.droppedStepCount = result.droppedStepCount
        plan.droppedToCapCount = result.droppedToCapCount
        plan.generatedAt = .now
    }

    // MARK: Phrasing

    /// Wording only. Runs after the plan is already built and saved, so a slow or absent model
    /// never delays a ladder from existing — and the notification path never calls the model at
    /// all, because the sentence is persisted by the time anything is scheduled.
    private func phraseSteps(of plan: PrepPlan, event: TrackedEvent) async {
        guard await provider.isAvailable else { return }
        for step in plan.steps where step.generatedCopy == nil && step.userEditedCopy == nil {
            let request = PhrasingRequest(
                eventTitle: event.title,
                actionVerb: step.actionVerb,
                templateCopy: step.templateCopy,
                audience: step.audience,
                relativeLabel: step.relativeLabel
            )
            if let phrased = await provider.phrase(request) {
                step.generatedCopy = phrased
            }
        }
        try? context.save()
    }
}
