import ForerunCore
import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// The one place services are constructed and wired together. Views reach for this through the
/// environment rather than building anything themselves, which keeps a screen from quietly
/// spinning up a second `EKEventStore` and breaking change notifications.
///
/// Injected once at the app root with `.environment(app)`, the `@Observable` way — an
/// `EnvironmentKey` would need a default value constructed off the main actor, which this type
/// cannot provide. Because the injection happens at the root rather than in a presenting view,
/// sheets and full-screen covers inherit it correctly.
@MainActor
@Observable
final class AppEnvironment {
    let context: ModelContext
    let settings: AppSettings
    let sync: EventSyncService
    let scheduler = NotificationScheduler()
    let planning: PlanningCoordinator
    let notifications = NotificationDelegate()

    private let calendarChanges = CalendarChangeMonitor()
    private let timeZoneChanges = TimeZoneChangeMonitor()

    /// Calendars offered on the tracking-rules screen. Empty until access is granted.
    private(set) var availableCalendars: [CalendarSummary] = []
    private(set) var calendarAccessError: EventSourceError?
    private(set) var hasStarted = false

    init(container: ModelContainer, sync: EventSyncService = EventSyncService()) {
        let context = ModelContext(container)
        self.context = context
        self.sync = sync
        // A failure here means the store is unusable, which the app has already surfaced as a
        // real screen — falling back to defaults keeps the type non-optional for every view.
        let settings = (try? AppSettings.loadOrCreate(in: context)) ?? AppSettings.detachedDefaults()
        self.settings = settings
        self.planning = PlanningCoordinator(context: context, settings: settings)
    }

    // MARK: Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        planning.scheduler = scheduler
        sync.reconciler = planning
        notifications.context = context
        notifications.settings = settings
        notifications.scheduler = scheduler

        UNUserNotificationCenter.current().delegate = notifications
        scheduler.registerCategories()
        await scheduler.refreshAuthorizationStatus()

        calendarChanges.start { [weak self] in
            await self?.refresh()
        }
        timeZoneChanges.start { [weak self] in
            // Offsets are stored as intervals, so a timezone change is fixed by re-deriving
            // every fire date, never by shifting the stored ones (invariant 10).
            await self?.planning.rebuildAllPlans()
            await self?.refresh()
        }

        await reloadCalendars()
        await refresh()
    }

    /// Called on foreground, on pull-to-refresh, on a calendar change and from the background
    /// refresh task. All four want the same thing: re-read the sources, reconcile, re-derive the
    /// notification window.
    func refresh() async {
        await reloadCalendars()
        await sync.sync(context: context, settings: settings)
        await scheduler.refreshWindow(context: context, settings: settings)
        BackgroundRefresh.schedule()
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

    /// Notifications are asked for when the first plan is saved, not at launch.
    @discardableResult
    func requestNotificationsIfNeeded() async -> Bool {
        await scheduler.requestAuthorizationIfNeeded()
    }

    // MARK: Tracking

    func trackedEvent(for sourceID: String) -> TrackedEvent? {
        var descriptor = FetchDescriptor<TrackedEvent>(predicate: #Predicate { $0.sourceID == sourceID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func track(_ event: NormalizedEvent) async {
        await sync.track(event, context: context, settings: settings)
        // The first plan is the moment notifications become worth asking about.
        await requestNotificationsIfNeeded()
        await scheduler.refreshWindow(context: context, settings: settings)
    }

    func untrack(_ event: NormalizedEvent) async {
        if let tracked = trackedEvent(for: event.sourceID), let plan = tracked.plan {
            for step in plan.steps { scheduler.cancel(step) }
        }
        await sync.untrack(sourceID: event.sourceID, context: context, settings: settings)
    }

    // MARK: Step actions

    func resolve(_ step: PrepStep, as state: StepState) async {
        notifications.resolve(step, as: state, fromNotification: false, context: context)
        scheduler.cancel(step)
        try? context.save()
        await scheduler.refreshWindow(context: context, settings: settings)
    }

    func snooze(_ step: PrepStep) async {
        step.snoozedUntil = (step.snoozedUntil ?? step.fireDate)
            .addingTimeInterval(NotificationDelegate.snoozeInterval)
        step.state = .snoozed
        try? context.save()
        await scheduler.refreshWindow(context: context, settings: settings)
    }

    // MARK: Rules

    func setCalendarTracked(_ calendarID: String, tracked: Bool) async {
        if tracked {
            if !settings.trackedCalendarIDs.contains(calendarID) {
                settings.trackedCalendarIDs.append(calendarID)
            }
        } else {
            settings.trackedCalendarIDs.removeAll { $0 == calendarID }
        }
        try? context.save()
        await refresh()
    }

    func setColorFamilyTracked(_ family: ColorFamily, tracked: Bool) async {
        var families = settings.autoTrackFamilies
        if tracked { families.insert(family) } else { families.remove(family) }
        settings.autoTrackFamilies = families
        try? context.save()
        await refresh()
    }

    /// A setting that changes *when* things fire has to rebuild every plan, not just reschedule
    /// — the fire dates themselves were computed from these numbers.
    func settingsAffectingTimingChanged() async {
        settings.clampToLimits()
        try? context.save()
        await planning.rebuildAllPlans()
        await scheduler.refreshWindow(context: context, settings: settings)
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        try? context.save()
    }
}
