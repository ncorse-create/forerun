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

    let tickTickAuth = TickTickAuth()
    /// Nil in a build with no TickTick credentials, which hides the entire surface rather than
    /// showing a connect button that cannot work (ADR 002).
    let tickTick: TickTickSource? = TickTickSource.isConfigured ? TickTickSource() : nil

    private(set) var tickTickProjects: [TickTickProject] = []
    private(set) var tickTickError: String?
    private(set) var isTickTickConnected = false

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
        notifications.planning = planning

        // The provider is resolved once, asynchronously, because availability is a system
        // query. Until it resolves, the heuristic provider is already in place — so a plan
        // built in the first moments of launch is complete, just not tailored.
        planning.use(provider: await ProviderResolver.make())

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

        sync.attach(tickTickSource: tickTick)
        await applyRedRule()
        await refreshTickTickState()

        await reloadCalendars()
        await refresh()
    }

    // MARK: TickTick

    var isTickTickAvailable: Bool { tickTick != nil }

    func refreshTickTickState() async {
        guard let tickTick else { return }
        isTickTickConnected = await tickTick.isAuthorized
        guard isTickTickConnected else {
            tickTickProjects = []
            return
        }
        do {
            tickTickProjects = try await tickTick.availableProjects()
            tickTickError = nil
        } catch let error as EventSourceError {
            tickTickProjects = []
            tickTickError = Self.message(for: error)
        } catch {
            tickTickProjects = []
            tickTickError = error.localizedDescription
        }
    }

    func connectTickTick() async {
        do {
            try await tickTickAuth.connect()
            settings.tickTickConnectedAt = .now
            try? context.save()
            tickTickError = nil
            await refreshTickTickState()
            await refresh()
        } catch let error as TickTickAuth.AuthError {
            // A cancelled sign-in is not an error worth reporting back.
            tickTickError = error.errorDescription
        } catch {
            tickTickError = error.localizedDescription
        }
    }

    /// Revokes locally and purges the Keychain. Whether the tracked events go too is the user's
    /// call, because a plan they edited is theirs regardless of where the event came from.
    func disconnectTickTick(removingTrackedEvents: Bool) async {
        await tickTickAuth.disconnect()
        settings.tickTickConnectedAt = nil
        settings.tickTickRedProjectIDs = []

        if removingTrackedEvents {
            let all = (try? context.fetch(FetchDescriptor<TrackedEvent>())) ?? []
            for event in all where event.sourceType == .ticktick {
                if let plan = event.plan {
                    for step in plan.steps { scheduler.cancel(step) }
                }
                context.delete(event)
            }
        }
        try? context.save()
        await refreshTickTickState()
        await refresh()
    }

    func applyRedRule() async {
        await tickTick?.setRedRule(TickTickRedRule(
            treatsHighPriorityAsRed: settings.tickTickTreatsHighPriorityAsRed,
            redProjectIDs: Set(settings.tickTickRedProjectIDs)
        ))
    }

    func setTickTickHighPriorityIsRed(_ isRed: Bool) async {
        settings.tickTickTreatsHighPriorityAsRed = isRed
        try? context.save()
        await applyRedRule()
        await refresh()
    }

    func setTickTickProjectIsRed(_ projectID: String, isRed: Bool) async {
        if isRed {
            if !settings.tickTickRedProjectIDs.contains(projectID) {
                settings.tickTickRedProjectIDs.append(projectID)
            }
        } else {
            settings.tickTickRedProjectIDs.removeAll { $0 == projectID }
        }
        try? context.save()
        await applyRedRule()
        await refresh()
    }

    static func message(for error: EventSourceError) -> String {
        switch error {
        case .notDetermined: "Not connected yet."
        case .denied: "Access is turned off."
        case .restricted: "Access is restricted on this iPhone."
        case .writeOnlyAccess: "Forerun can write to your calendar but can't read it."
        case .noCalendarsResolved: "The calendars you picked aren't available right now."
        case .reauthenticationRequired: "Your TickTick connection expired. Connect again."
        case .network(let detail): detail
        case .decoding: "TickTick sent something Forerun couldn't read."
        }
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

    /// Returns false when the step cannot legally move any later — the caller says so rather
    /// than appearing to do nothing.
    @discardableResult
    func snooze(_ step: PrepStep) async -> Bool {
        await planning.snooze(step)
    }

    /// A step's copy, time or audience changed. The plan is not rebuilt — the user edited this
    /// deliberately — but the notification window has to catch up.
    func stepWasEdited() async {
        try? context.save()
        await scheduler.refreshWindow(context: context, settings: settings)
    }

    func deleteStep(_ step: PrepStep, from event: TrackedEvent) async {
        scheduler.cancel(step)
        event.plan?.steps.removeAll { $0.id == step.id }
        context.delete(step)
        try? context.save()
        await scheduler.refreshWindow(context: context, settings: settings)
    }

    /// A step the user wrote themselves. It has no playbook rung, so it is never rebuilt, never
    /// dropped by a cap, and never recorded in the skip-rate diagnostic — there is nothing about
    /// a playbook to learn from it.
    func addCustomStep(
        to event: TrackedEvent,
        copy: String,
        fireDate: Date,
        audience: Audience
    ) async {
        let plan: PrepPlan
        if let existing = event.plan {
            plan = existing
        } else {
            plan = PrepPlan(playbookID: event.kind.rawValue)
            context.insert(plan)
            event.plan = plan
        }

        let step = PrepStep(
            order: plan.steps.count,
            offsetSeconds: fireDate.timeIntervalSince(event.startDate),
            fireDate: fireDate,
            audience: audience,
            actionVerb: "Do",
            templateCopy: copy,
            isCore: true,
            userPinnedTime: true,
            playbookStepID: PlanningCoordinator.customStepID(),
            isCustom: true
        )
        step.plan = plan
        plan.steps.append(step)
        context.insert(step)

        // Re-order so the new step sits in the timeline where its date says it belongs.
        for (index, ordered) in plan.orderedStepsByDate.enumerated() {
            ordered.order = index
        }

        try? context.save()
        await requestNotificationsIfNeeded()
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
