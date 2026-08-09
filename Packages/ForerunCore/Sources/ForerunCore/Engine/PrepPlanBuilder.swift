import Foundation

/// The heart of the app: a playbook plus a lead time plus the user's limits, turned into dated
/// steps. Entirely deterministic, entirely synchronous, and dependent on nothing but Foundation.
/// The model is not consulted here and cannot be — nothing in this file can change *when* or
/// *whether* something fires.
///
/// The ten invariants from `CLAUDE.md` are enforced here, each with a named test in
/// `EngineInvariantTests`.
public enum PrepPlanBuilder {

    /// Invariant 7. Two steps for the same event never fire within four hours of each other,
    /// and compression drops steps rather than going below it.
    public static let minimumInterStepGap: TimeInterval = 4 * 3_600

    /// A compressed plan's first step lands here rather than exactly at `now`, so a step is
    /// never scheduled for an instant that has already passed by the time it is written.
    private static let compressionHeadroom: TimeInterval = 60

    /// How far a busy window is cleared by, so a step never lands on the very edge of a meeting.
    private static let busyWindowClearance: TimeInterval = 5 * 60

    /// Bounded because the passes feed each other — dropping a step for audience ordering can
    /// free a budget slot, which can move another step, which can break the gap rule. Four
    /// rounds is far more than any real plan needs; it exists so a pathological input cannot spin.
    private static let maxSettlingRounds = 6

    // MARK: - Entry point

    public static func build(
        input: PlanInput,
        settings: EngineSettings,
        context: SchedulingContext = SchedulingContext()
    ) -> PlanDraft {
        let playbook = PlaybookLibrary.playbook(for: input.kind)
        guard !playbook.steps.isEmpty else { return .empty(playbookID: playbook.id) }

        let calendar = context.calendar
        let anchor = anchorDate(for: input, settings: settings, calendar: calendar)
        let pinned = Dictionary(
            context.pinnedSteps.map { ($0.playbookStepID, $0.fireDate) },
            uniquingKeysWith: { first, _ in first }
        )

        // 1 — Lay the playbook out against the anchor, compressing if the run-up is short.
        let (laid, wasCompressed) = layOut(
            playbook: playbook,
            input: input,
            anchor: anchor,
            pinned: pinned,
            now: context.now
        )

        // Steps that are already in the past cannot be rescued. A follow-up step for an event
        // that happened last week is not useful; a pre-event step whose moment has gone is noise.
        var steps = laid.filter { $0.isPinned || $0.fireDate > context.now }

        // 2 — Invariant 3: the per-event cap, applied before re-timing so the user's "5 steps"
        // is a statement about which rungs they get, not an accident of quiet hours.
        steps = applyStepCap(steps, limit: settings.maxStepsPerEvent)

        // 3 — Settle. Re-timing can drop steps, dropping can free budget, and both can break the
        // ordering rule, so the passes run until nothing changes.
        for _ in 0..<maxSettlingRounds {
            let retimed = retime(steps, settings: settings, context: context, anchor: anchor)
            let ordered = enforceAudienceOrdering(retimed)
            let spaced = enforceMinimumGap(ordered)
            if spaced == steps { break }
            steps = spaced
        }

        // 4 — Final guarantees. Nothing in the past, sorted, contiguously ordered.
        steps = steps
            .filter { $0.fireDate > context.now }
            .sorted { $0.fireDate < $1.fireDate }
        for index in steps.indices { steps[index].order = index }

        return PlanDraft(
            playbookID: playbook.id,
            steps: steps,
            wasCompressed: wasCompressed,
            droppedStepCount: max(0, playbook.steps.count - steps.count)
        )
    }

    // MARK: - Anchoring

    /// Invariant 9: an all-day event has no start time worth counting back from, so it anchors
    /// to the user's preferred delivery hour on its own date.
    static func anchorDate(
        for input: PlanInput,
        settings: EngineSettings,
        calendar: Calendar
    ) -> Date {
        guard input.isAllDay else { return input.startDate }
        let startOfDay = calendar.startOfDay(for: input.startDate)
        return calendar.date(
            bySettingHour: clampHour(settings.preferredDeliveryHour),
            minute: 0,
            second: 0,
            of: startOfDay
        ) ?? startOfDay
    }

    // MARK: - Layout and compression

    /// Invariant 1. When the event is closer than the playbook's first offset, every remaining
    /// offset is scaled proportionally into the window that actually exists, rather than a
    /// silent pile-up at the start.
    private static func layOut(
        playbook: Playbook,
        input: PlanInput,
        anchor: Date,
        pinned: [String: Date],
        now: Date
    ) -> (steps: [StepDraft], wasCompressed: Bool) {
        let available = anchor.timeIntervalSince(now)
        let wanted = playbook.maximumLeadTime
        // Only compress when there is a run-up left to compress into. A zero or negative
        // available window means the event has started — only follow-ups remain.
        let shouldCompress = available > 0 && wanted > 0 && available < wanted
        let scale = shouldCompress ? available / wanted : 1

        var drafts: [StepDraft] = []
        for (index, step) in playbook.steps.enumerated() {
            let scaledOffset = step.offset < 0 ? step.offset * scale : step.offset
            var fireDate = anchor.addingTimeInterval(scaledOffset)

            if shouldCompress, step.offset < 0, fireDate <= now {
                fireDate = now.addingTimeInterval(compressionHeadroom)
            }

            let pinnedDate = pinned[step.id]
            drafts.append(StepDraft(
                playbookStepID: step.id,
                order: index,
                // The *original* offset is stored, never the scaled one. Fire dates are derived
                // from offsets on every rebuild, so persisting a squeezed offset would bake a
                // one-off compression into the step forever.
                offsetSeconds: step.offset,
                fireDate: pinnedDate ?? fireDate,
                audience: step.audience,
                actionVerb: step.verb,
                templateCopy: step.copy(for: input.title),
                isCore: step.isCore,
                isPinned: pinnedDate != nil
            ))
        }
        return (drafts, shouldCompress)
    }

    // MARK: - Invariant 3: the cap

    static func applyStepCap(_ steps: [StepDraft], limit: Int) -> [StepDraft] {
        guard steps.count > limit, limit > 0 else { return steps }
        var survivors = steps

        // Non-core steps go first, latest-offset first. A pinned step is a user decision and is
        // never dropped to satisfy a cap.
        func dropOne(from candidates: [StepDraft]) -> StepDraft? {
            candidates.filter { !$0.isPinned }.max { $0.offsetSeconds < $1.offsetSeconds }
        }

        while survivors.count > limit {
            let nonCore = survivors.filter { !$0.isCore }
            let victim = dropOne(from: nonCore) ?? dropOne(from: survivors)
            guard let victim else { break }
            survivors.removeAll { $0.playbookStepID == victim.playbookStepID }
        }
        return survivors
    }

    // MARK: - Invariant 2: audience ordering

    /// Every leader/volunteer step fires strictly before every participant/student step. When
    /// that cannot hold, participant steps are dropped — never reordered, and never at the cost
    /// of a leader step. Contacting the team after you have already told the students is worse
    /// than not telling the students at all.
    ///
    /// **Only the run-up is ordered.** Post-event steps are excluded from both sides of the
    /// comparison, because the volunteer playbook ends with a +1d "thank your leads" step: count
    /// it as a leader step and it becomes the latest leader step in the plan, which makes every
    /// participant step look out of order and silently deletes the −24h "message the students"
    /// rung from every single team event. The invariant is about the sequence of the ask, not
    /// about follow-ups.
    static func enforceAudienceOrdering(_ steps: [StepDraft]) -> [StepDraft] {
        var survivors = steps
        while true {
            let runUp = survivors.filter { $0.offsetSeconds < 0 }
            let leaderLatest = runUp.filter { $0.audience.isLeadership }.map(\.fireDate).max()
            guard let leaderLatest else { return survivors }

            let offenders = runUp.filter { $0.audience.isAudienceSide && $0.fireDate <= leaderLatest }
            guard !offenders.isEmpty else { return survivors }

            // Drop the earliest offender: it is the one that is out in front of the leaders.
            // A pinned offender is the user's explicit choice, so it is left alone and the
            // leader step it conflicts with is the one that has to move on a later pass.
            guard let victim = offenders.filter({ !$0.isPinned }).min(by: { $0.fireDate < $1.fireDate }) else {
                return survivors
            }
            survivors.removeAll { $0.playbookStepID == victim.playbookStepID }
        }
    }

    // MARK: - Invariant 7: minimum gap

    /// Compression never squeezes below four hours between two steps for the same event — it
    /// drops a step instead. Two notifications about the same event within an afternoon is the
    /// exact behaviour that trains people to swipe them away.
    static func enforceMinimumGap(_ steps: [StepDraft]) -> [StepDraft] {
        var survivors = steps.sorted { $0.fireDate < $1.fireDate }
        var index = 1
        while index < survivors.count {
            let previous = survivors[index - 1]
            let current = survivors[index]
            guard current.fireDate.timeIntervalSince(previous.fireDate) < minimumInterStepGap else {
                index += 1
                continue
            }

            // Pinned wins. Otherwise keep the core one; if both or neither are core, keep the
            // earlier, because lead time is the thing this app exists to protect.
            let victim: StepDraft
            if previous.isPinned && current.isPinned {
                index += 1
                continue
            } else if previous.isPinned {
                victim = current
            } else if current.isPinned {
                victim = previous
            } else if previous.isCore != current.isCore {
                victim = previous.isCore ? current : previous
            } else {
                victim = current
            }

            survivors.removeAll { $0.playbookStepID == victim.playbookStepID }
            index = max(1, index - 1)
        }
        return survivors
    }

    // MARK: - Invariants 4, 5, 6: re-timing

    private static func retime(
        _ steps: [StepDraft],
        settings: EngineSettings,
        context: SchedulingContext,
        anchor: Date
    ) -> [StepDraft] {
        let calendar = context.calendar
        var placed: [StepDraft] = []
        // Fire dates already committed by other plans count against the same daily budget.
        var perDayCount = Dictionary(
            grouping: context.existingFireDates,
            by: { calendar.startOfDay(for: $0) }
        ).mapValues(\.count)

        for step in steps.sorted(by: { $0.fireDate < $1.fireDate }) {
            // Invariant 8: a pinned step is exempt from quiet hours, the budget and the gap.
            if step.isPinned {
                placed.append(step)
                perDayCount[calendar.startOfDay(for: step.fireDate), default: 0] += 1
                continue
            }

            guard var date = resolveQuietHoursAndBusy(
                step.fireDate,
                step: step,
                anchor: anchor,
                settings: settings,
                context: context
            ) else { continue }

            // Invariant 6: over budget defers the step *earlier*, never later. A prep step that
            // slides past the thing it was preparing for is worse than no step.
            date = resolveBudget(
                date,
                step: step,
                anchor: anchor,
                settings: settings,
                context: context,
                perDayCount: &perDayCount
            ) ?? date

            guard date > context.now else { continue }
            // A pre-event step that got pushed past its own event is dropped rather than fired
            // late — invariant 6 again, and the reason it is stated as "never later."
            if step.offsetSeconds < 0 && date >= anchor { continue }

            var resolved = step
            resolved.fireDate = date
            placed.append(resolved)
            perDayCount[calendar.startOfDay(for: date), default: 0] += 1
        }
        return placed
    }

    /// Invariants 4 and 5, resolved together because fixing one can break the other.
    private static func resolveQuietHoursAndBusy(
        _ start: Date,
        step: StepDraft,
        anchor: Date,
        settings: EngineSettings,
        context: SchedulingContext
    ) -> Date? {
        var date = start
        // Each iteration either shifts the date forward or exits, and the forward shift is at
        // least an hour, so this cannot spin. The bound is belt-and-braces.
        for _ in 0..<12 {
            if isInQuietHours(date, settings: settings, calendar: context.calendar) {
                date = nextDeliverySlot(after: date, settings: settings, calendar: context.calendar)
                continue
            }
            if let window = context.busyWindows.first(where: { $0.contains(date) }) {
                // Clear the meeting rather than interrupting it — people act on prompts at
                // boundaries, not mid-task.
                date = window.end.addingTimeInterval(busyWindowClearance)
                continue
            }
            break
        }

        guard date > context.now else { return nil }
        // Shifting forward must not push a pre-event step past its event. When it would, fall
        // back to the previous day's delivery slot rather than firing after the fact.
        if step.offsetSeconds < 0 && date >= anchor {
            let earlier = previousDeliverySlot(before: start, settings: settings, calendar: context.calendar)
            guard earlier > context.now, earlier < anchor else { return nil }
            return earlier
        }
        return date
    }

    /// Invariant 6. Walks backwards a day at a time looking for room, and gives up rather than
    /// scheduling into the past or past the event.
    private static func resolveBudget(
        _ start: Date,
        step: StepDraft,
        anchor: Date,
        settings: EngineSettings,
        context: SchedulingContext,
        perDayCount: inout [Date: Int]
    ) -> Date? {
        let calendar = context.calendar
        let budget = max(1, settings.dailyNotificationBudget)
        var date = start

        for _ in 0..<14 {
            let day = calendar.startOfDay(for: date)
            if perDayCount[day, default: 0] < budget { return date }
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            guard let slot = calendar.date(
                bySettingHour: deliveryHour(for: settings),
                minute: 0,
                second: 0,
                of: previousDay
            ) else { return nil }
            guard slot > context.now else { return nil }
            date = slot
        }
        return nil
    }

    // MARK: - Quiet hours

    /// The window wraps midnight when `start > end`, which is the normal case (22 → 7).
    /// `start == end` means the user turned quiet hours off.
    static func isInQuietHours(_ date: Date, settings: EngineSettings, calendar: Calendar) -> Bool {
        let start = clampHour(settings.quietHoursStart)
        let end = clampHour(settings.quietHoursEnd)
        guard start != end else { return false }
        let hour = calendar.component(.hour, from: date)
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    /// The hour notifications are delivered at. If the user has managed to put their preferred
    /// hour inside their own quiet hours, the end of quiet hours wins — otherwise every shifted
    /// step would bounce forever.
    static func deliveryHour(for settings: EngineSettings) -> Int {
        let preferred = clampHour(settings.preferredDeliveryHour)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let probe = Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(TimeInterval(preferred) * 3_600)
        return isInQuietHours(probe, settings: settings, calendar: calendar)
            ? clampHour(settings.quietHoursEnd)
            : preferred
    }

    static func nextDeliverySlot(after date: Date, settings: EngineSettings, calendar: Calendar) -> Date {
        let hour = deliveryHour(for: settings)
        let today = calendar.startOfDay(for: date)
        if let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today), slot > date {
            return slot
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)
        else {
            // Adding an hour still makes progress, which is all the caller needs to avoid a loop.
            return date.addingTimeInterval(3_600)
        }
        return slot
    }

    static func previousDeliverySlot(before date: Date, settings: EngineSettings, calendar: Calendar) -> Date {
        let hour = deliveryHour(for: settings)
        let today = calendar.startOfDay(for: date)
        if let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today), slot < date {
            return slot
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: yesterday)
        else {
            return date.addingTimeInterval(-3_600)
        }
        return slot
    }

    private static func clampHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }
}
