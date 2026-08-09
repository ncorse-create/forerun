import ForerunCore
import Foundation
import SwiftData
import SwiftUI

/// The one place services are constructed and wired together. Views reach for this through the
/// environment rather than building anything themselves, which keeps a screen from quietly
/// spinning up a second `EKEventStore` and breaking change notifications.
@MainActor
@Observable
final class AppEnvironment {
    let sync: EventSyncService
    let calendarChanges = CalendarChangeMonitor()
    let timeZoneChanges = TimeZoneChangeMonitor()

    /// Set once the model container exists. Everything that writes goes through this.
    private(set) var context: ModelContext?
    private(set) var settings: AppSettings?

    /// Calendars offered on the tracking-rules screen. Empty until access is granted.
    private(set) var availableCalendars: [CalendarSummary] = []
    private(set) var calendarAccessError: EventSourceError?

    init(sync: EventSyncService = EventSyncService()) {
        self.sync = sync
    }

    // MARK: Lifecycle

    func bootstrap(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        settings = try? AppSettings.loadOrCreate(in: context)
        try? context.save()

        calendarChanges.start { [weak self] in
            await self?.refresh()
        }
        timeZoneChanges.start { [weak self] in
            await self?.refresh()
        }
    }

    /// Called on foreground, on pull-to-refresh, on a calendar change and on a timezone change.
    /// All four want the same thing: re-read the sources, reconcile, re-derive the schedule.
    func refresh() async {
        guard let context, let settings else { return }
        await reloadCalendars()
        await sync.sync(context: context, settings: settings)
    }

    func reloadCalendars() async {
        calendarAccessError = EventKitSource.authorizationError
        availableCalendars = calendarAccessError == nil
            ? await sync.calendarSource.availableCalendars()
            : []
    }

    // MARK: Permissions

    /// Contextual, per locked decision 6 — this is only ever reached from a button that says
    /// what it is about to do.
    @discardableResult
    func connectAppleCalendar() async -> Bool {
        let granted = (try? await sync.calendarSource.requestAccess()) ?? false
        await reloadCalendars()
        if granted { await refresh() }
        return granted
    }

    // MARK: Tracking

    func isTracked(_ event: NormalizedEvent) -> Bool {
        trackedEvent(for: event.sourceID) != nil
    }

    func trackedEvent(for sourceID: String) -> TrackedEvent? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<TrackedEvent>(predicate: #Predicate { $0.sourceID == sourceID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func track(_ event: NormalizedEvent) async {
        guard let context, let settings else { return }
        await sync.track(event, context: context, settings: settings)
    }

    func untrack(_ event: NormalizedEvent) async {
        guard let context, let settings else { return }
        await sync.untrack(sourceID: event.sourceID, context: context, settings: settings)
    }

    // MARK: Rules

    func setCalendarTracked(_ calendarID: String, tracked: Bool) async {
        guard let settings else { return }
        if tracked {
            if !settings.trackedCalendarIDs.contains(calendarID) {
                settings.trackedCalendarIDs.append(calendarID)
            }
        } else {
            settings.trackedCalendarIDs.removeAll { $0 == calendarID }
        }
        await refresh()
    }

    func setColorFamilyTracked(_ family: ColorFamily, tracked: Bool) async {
        guard let settings else { return }
        var families = settings.autoTrackFamilies
        if tracked { families.insert(family) } else { families.remove(family) }
        settings.autoTrackFamilies = families
        await refresh()
    }

    func completeOnboarding() {
        settings?.hasCompletedOnboarding = true
        try? context?.save()
    }
}

// Injected once at the app root with `.environment(app)`, the @Observable way — an
// `EnvironmentKey` would need a default value constructed off the main actor, which this type
// cannot provide. Because the injection happens at the root rather than in a presenting view,
// sheets and full-screen covers inherit it correctly.
