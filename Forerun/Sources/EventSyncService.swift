import EventKit
import ForerunCore
import Foundation
import SwiftData

/// What sync hands off to after the database is up to date. Implemented in Sprint 4 by the
/// planning coordinator; a no-op stand-in keeps sync testable and keeps this file free of any
/// knowledge of playbooks.
@MainActor
protocol PlanReconciling: AnyObject {
    /// A new event just started being tracked and has no plan yet.
    func planWasNeeded(for event: TrackedEvent) async
    /// An event's start date moved, so its ladder is now wrong.
    func planNeedsRebuild(for event: TrackedEvent, previousStart: Date) async
    /// Anything at all changed; re-derive the notification window.
    func schedulingWindowNeedsRefresh() async
}

@MainActor
final class NoOpPlanReconciler: PlanReconciling {
    func planWasNeeded(for event: TrackedEvent) async {}
    func planNeedsRebuild(for event: TrackedEvent, previousStart: Date) async {}
    func schedulingWindowNeedsRefresh() async {}
}

/// Pulls every configured source, deduplicates across them, and reconciles the result into the
/// database. The whole calendar is *not* persisted — only tracked events are. Everything else
/// lives in memory for as long as the Events screen needs it.
@MainActor
@Observable
final class EventSyncService {
    /// How far ahead Forerun looks. Sixty days covers the longest playbook's −21d lead with a
    /// month of room to spare.
    static let windowDays = 60
    /// A tracked event that vanished from its calendar is kept this long before it is purged,
    /// so a sync hiccup or a temporarily-unshared calendar does not destroy an edited plan.
    static let disappearedGraceDays = 14
    /// Finished events are kept this long so their follow-up steps can still fire and their
    /// outcomes can still be recorded.
    static let pastRetentionDays = 30
    /// How far behind `now` the fetch reaches. Must exceed the largest positive playbook offset
    /// (+1 day) plus the slack a quiet-hours shift can add.
    static let lookBehindDays = 3

    let calendarSource: EventKitSource
    private(set) var tickTickSource: TickTickSource?

    /// Everything in the window, tracked or not, for the Events screen.
    private(set) var browsableEvents: [NormalizedEvent] = []
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: EventSourceError?

    weak var reconciler: (any PlanReconciling)?

    init(calendarSource: EventKitSource = EventKitSource(), tickTickSource: TickTickSource? = nil) {
        self.calendarSource = calendarSource
        self.tickTickSource = tickTickSource
    }

    func attach(tickTickSource: TickTickSource?) {
        self.tickTickSource = tickTickSource
    }

    // MARK: Sync

    func sync(context: ModelContext, settings: AppSettings, now: Date = .now) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: Self.windowDays, to: now) ?? now
        // The reach-back has to cover the largest *positive* playbook offset plus quiet-hours
        // slack, not merely "an event that started an hour ago." The volunteer and buildWork
        // playbooks both end at +1d, and a follow-up shifted out of quiet hours can land a day
        // later again — so a one-day reach-back let a finished Sunday service fall out of the
        // fetch, get stamped as disappeared, and have its still-pending "thank your leads"
        // notification removed and never re-added.
        let start = calendar.date(byAdding: .day, value: -Self.lookBehindDays, to: now) ?? now

        await calendarSource.setSelectedCalendarIDs(Set(settings.trackedCalendarIDs))

        var gathered: [NormalizedEvent] = []
        var failure: EventSourceError?

        do {
            gathered += try await calendarSource.fetchEvents(from: start, to: end)
        } catch let error as EventSourceError {
            failure = error
        } catch {
            failure = .network(error.localizedDescription)
        }

        if let tickTickSource, await tickTickSource.isAuthorized {
            do {
                gathered += try await tickTickSource.fetchEvents(from: start, to: end)
            } catch let error as EventSourceError {
                // A TickTick failure must never take the calendar down with it.
                failure = failure ?? error
            } catch {
                failure = failure ?? .network(error.localizedDescription)
            }
        }

        lastError = failure

        // If the only configured source failed outright, leave the database alone. Reconciling
        // against an empty fetch would mark every tracked event as having disappeared.
        if failure != nil && gathered.isEmpty {
            return
        }

        let (kept, duplicates) = TrackingRules.deduplicate(gathered)
        browsableEvents = kept.sorted { $0.startDate < $1.startDate }

        await reconcile(
            events: kept,
            duplicates: duplicates,
            context: context,
            settings: settings,
            now: now,
            fetchStart: start
        )

        // One housekeeping pass, in the one place that already walks the store.
        StepOutcome.prune(in: context, now: now)

        settings.lastSyncAt = now
        lastSyncedAt = now
        try? context.save()
        await reconciler?.schedulingWindowNeedsRefresh()
    }

    // MARK: Reconciliation

    private func reconcile(
        events: [NormalizedEvent],
        duplicates: [(dropped: NormalizedEvent, keptSourceID: String)],
        context: ModelContext,
        settings: AppSettings,
        now: Date,
        fetchStart: Date
    ) async {
        let rules = TrackingSettings(
            trackedCalendarIDs: Set(settings.trackedCalendarIDs),
            autoTrackColorFamilies: settings.autoTrackFamilies,
            manuallyExcludedSourceIDs: Set(settings.manuallyExcludedSourceIDs),
            manuallyIncludedSourceIDs: Set(settings.manuallyIncludedSourceIDs)
        )

        let existing = collapseDuplicateRows(
            (try? context.fetch(FetchDescriptor<TrackedEvent>())) ?? [],
            context: context
        )
        var bySourceID = Dictionary(existing.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        var seenSourceIDs: Set<String> = []

        for event in events {
            seenSourceIDs.insert(event.sourceID)
            let decision = TrackingRules.decide(for: event, settings: rules)

            // A moved occurrence arrives with a *different* sourceID, because the composite id
            // includes the occurrence start. Rekeying it here is what makes "drag an event five
            // minutes in Calendar" a reschedule rather than a delete-and-recreate that takes the
            // plan, the edited sentences, the scratchpad and the contacts with it.
            if bySourceID[event.sourceID] == nil,
               let moved = rekeyMovedOccurrence(event, among: bySourceID, seen: seenSourceIDs) {
                let previousStart = moved.startDate
                bySourceID[moved.sourceID] = nil
                moved.sourceID = event.sourceID
                moved.apply(event, at: now)
                bySourceID[event.sourceID] = moved
                await reconciler?.planNeedsRebuild(for: moved, previousStart: previousStart)
                continue
            }

            if let tracked = bySourceID[event.sourceID] {
                if decision.reason == .manuallyExcluded {
                    context.delete(tracked)
                    bySourceID[event.sourceID] = nil
                    continue
                }
                let previousStart = tracked.startDate
                tracked.apply(event, at: now)
                if previousStart != event.startDate {
                    await reconciler?.planNeedsRebuild(for: tracked, previousStart: previousStart)
                }
            } else if decision.shouldTrack {
                let tracked = TrackedEvent(
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
                    hasRecurrenceRules: event.hasRecurrenceRules,
                    trackedAt: now,
                    lastSyncedAt: now
                )
                context.insert(tracked)
                bySourceID[event.sourceID] = tracked
                await reconciler?.planWasNeeded(for: tracked)
            }
        }

        // Mark TickTick records that lost a dedup match. The scheduler reads this to keep a
        // duplicate from producing a second set of notifications; the Events screen does not
        // list them at all, because `browsableEvents` already holds the deduplicated set.
        let duplicateIDs = Dictionary(
            duplicates.map { ($0.dropped.sourceID, $0.keptSourceID) },
            uniquingKeysWith: { first, _ in first }
        )
        for (sourceID, keptID) in duplicateIDs {
            bySourceID[sourceID]?.isDuplicateOfSourceID = keptID
        }

        markDisappeared(
            existing: Array(bySourceID.values),
            seenSourceIDs: seenSourceIDs,
            context: context,
            now: now,
            fetchStart: fetchStart,
            sourcesReturnedNothing: events.isEmpty
        )
    }

    /// Finds the tracked row that this event *is*, after a time change moved its composite id.
    ///
    /// The match is deliberately narrow — same series identifier, same source, not already
    /// claimed by another event in this batch, and the nearest such candidate wins. A recurring
    /// series has many occurrences sharing one series identifier, so a loose match would happily
    /// rekey next month's Sunday service onto this week's.
    private func rekeyMovedOccurrence(
        _ event: NormalizedEvent,
        among tracked: [String: TrackedEvent],
        seen: Set<String>
    ) -> TrackedEvent? {
        guard event.sourceType == .eventkit else { return nil }
        let series = EventKitSource.seriesIdentifier(from: event.sourceID)
        guard !series.isEmpty else { return nil }

        let candidates = tracked.values.filter { candidate in
            candidate.sourceType == .eventkit
                && EventKitSource.seriesIdentifier(from: candidate.sourceID) == series
                // A row the current batch already matched exactly is not a move — it is itself.
                && !seen.contains(candidate.sourceID)
        }
        guard !candidates.isEmpty else { return nil }

        return candidates.min {
            abs($0.startDate.timeIntervalSince(event.startDate))
                < abs($1.startDate.timeIntervalSince(event.startDate))
        }
    }

    /// `sourceID` is the natural key but carries no unique constraint — SwiftData's uniqueness
    /// is upsert rather than throw, so constraining it would silently *replace* a row and wipe
    /// the plan attached to it. The guard lives here instead: if two rows ever share a
    /// `sourceID`, keep the one with real work on it and delete the rest, before anything
    /// downstream can schedule two sets of notifications for one event.
    private func collapseDuplicateRows(
        _ events: [TrackedEvent],
        context: ModelContext
    ) -> [TrackedEvent] {
        var bySourceID: [String: TrackedEvent] = [:]
        var survivors: [TrackedEvent] = []

        for event in events.sorted(by: { $0.trackedAt < $1.trackedAt }) {
            guard let incumbent = bySourceID[event.sourceID] else {
                bySourceID[event.sourceID] = event
                survivors.append(event)
                continue
            }
            // Prefer whichever row a human has actually touched.
            let incumbentWeight = weight(of: incumbent)
            let challengerWeight = weight(of: event)
            if challengerWeight > incumbentWeight {
                context.delete(incumbent)
                survivors.removeAll { $0 === incumbent }
                bySourceID[event.sourceID] = event
                survivors.append(event)
            } else {
                context.delete(event)
            }
        }
        return survivors
    }

    private func weight(of event: TrackedEvent) -> Int {
        var score = 0
        if let plan = event.plan {
            score += 4
            // A plan the user has edited is worth far more than an untouched one.
            score += plan.steps.filter(\.isUserOwned).count * 3
        }
        score += event.scratchpad.count
        score += event.contacts.count
        if event.kindWasConfirmedByUser { score += 2 }
        return score
    }

    /// Soft-delete, then purge on a delay. An event that briefly vanishes because a shared
    /// calendar hiccuped must not take an edited plan with it.
    private func markDisappeared(
        existing: [TrackedEvent],
        seenSourceIDs: Set<String>,
        context: ModelContext,
        now: Date,
        fetchStart: Date,
        sourcesReturnedNothing: Bool
    ) {
        // Every source came back empty. That is indistinguishable from "the user deleted their
        // whole calendar," and it happens for mundane reasons — iCloud signed out, an account
        // removed, calendar IDs gone stale after a restore. Refusing to judge is the only safe
        // response; fourteen days of this would otherwise purge every plan in the app.
        guard !sourcesReturnedNothing || existing.isEmpty else { return }

        let calendar = Calendar.current
        let purgeBefore = calendar.date(byAdding: .day, value: -Self.disappearedGraceDays, to: now) ?? now
        let pastCutoff = calendar.date(byAdding: .day, value: -Self.pastRetentionDays, to: now) ?? now
        let windowEnd = calendar.date(byAdding: .day, value: Self.windowDays, to: now) ?? now

        for tracked in existing {
            // Long-finished events are removed regardless of whether the source still lists them.
            if tracked.startDate < pastCutoff {
                context.delete(tracked)
                continue
            }
            // Only events that *should* have been in this fetch can be judged missing, and the
            // test has to be two-sided: the fetch range is [fetchStart, windowEnd], so an event
            // that has fallen out the back is absent because it was never asked for, not because
            // it was deleted.
            let wasInWindow = tracked.startDate >= fetchStart && tracked.startDate <= windowEnd
            guard wasInWindow else { continue }

            // A record dropped by deduplication is not missing — it lost to its twin, and the
            // twin is what the user sees. Purging it would resurrect it on the next sync.
            if tracked.isDuplicate {
                tracked.disappearedAt = nil
                continue
            }
            if seenSourceIDs.contains(tracked.sourceID) {
                tracked.disappearedAt = nil
            } else if let disappearedAt = tracked.disappearedAt {
                if disappearedAt < purgeBefore { context.delete(tracked) }
            } else {
                tracked.disappearedAt = now
            }
        }
    }

    // MARK: Manual tracking

    func track(_ event: NormalizedEvent, context: ModelContext, settings: AppSettings) async {
        settings.manuallyExcludedSourceIDs.removeAll { $0 == event.sourceID }
        if !settings.manuallyIncludedSourceIDs.contains(event.sourceID) {
            settings.manuallyIncludedSourceIDs.append(event.sourceID)
        }

        let target = event.sourceID
        var descriptor = FetchDescriptor<TrackedEvent>(predicate: #Predicate { $0.sourceID == target })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.apply(event)
            try? context.save()
            return
        }

        let tracked = TrackedEvent(
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
        context.insert(tracked)
        try? context.save()
        await reconciler?.planWasNeeded(for: tracked)
        await reconciler?.schedulingWindowNeedsRefresh()
    }

    func untrack(sourceID: String, context: ModelContext, settings: AppSettings) async {
        settings.manuallyIncludedSourceIDs.removeAll { $0 == sourceID }
        if !settings.manuallyExcludedSourceIDs.contains(sourceID) {
            settings.manuallyExcludedSourceIDs.append(sourceID)
        }
        var descriptor = FetchDescriptor<TrackedEvent>(predicate: #Predicate { $0.sourceID == sourceID })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        }
        try? context.save()
        await reconciler?.schedulingWindowNeedsRefresh()
    }
}
