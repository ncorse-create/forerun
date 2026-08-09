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

    /// Set when a notification is tapped, cleared once the Plan screen has been pushed. Without
    /// this, tapping a reminder opened the app to whatever screen it was last on — which is the
    /// opposite of the whole point: the notification says "send leads the schedule," and the
    /// schedule is attached to the event.
    var deepLinkedEvent: TrackedEvent?

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

    /// Registers the notification delegate and its categories.
    ///
    /// Called from `ForerunApp.init`, not from `start()`. `start()` runs from a view's `.task`,
    /// which is after `didFinishLaunchingWithOptions` and after an `await` — so on a cold launch
    /// from a notification tap the response was already delivered and dropped: no deep link, and
    /// the step never left `.pending`.
    func registerNotificationHandling() {
        UNUserNotificationCenter.current().delegate = notifications
        scheduler.registerCategories()
    }

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

        // The delegate and the categories are registered in `ForerunApp.init`, before launch
        // finishes — a cold launch from a notification tap delivers its response before this
        // runs, and a delegate set afterwards misses it entirely. Everything the delegate needs
        // is wired here, which is why `wire(...)` is a separate step from registration.
        notifications.onDeepLink = { [weak self] eventID in
            guard let self else { return }
            var descriptor = FetchDescriptor<TrackedEvent>(predicate: #Predicate { $0.id == eventID })
            descriptor.fetchLimit = 1
            deepLinkedEvent = try? context.fetch(descriptor).first
        }

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

    // MARK: Undo

    /// What the last reversible action was, and how to say it.
    struct UndoableAction: Equatable {
        enum Kind: Equatable {
            case tracked(sourceIDs: [String])
            case untracked(sourceID: String)
        }

        var kind: Kind
        var sentence: String
    }

    /// How long an undo stays on offer. Long enough to notice a mistap, short enough that the
    /// row it is holding open does not linger.
    static let undoWindow: Duration = .seconds(6)

    private(set) var pendingUndo: UndoableAction?
    private var undoExpiry: Task<Void, Never>?

    private func offerUndo(_ action: UndoableAction) {
        pendingUndo = action
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await self?.expireUndo()
        }
    }

    /// The window closed. Anything being held open for an undo is now really gone.
    private func expireUndo() async {
        guard let action = pendingUndo else { return }
        pendingUndo = nil
        if case .untracked(let sourceID) = action.kind {
            sync.deferredUntrackIDs.remove(sourceID)
            if let tracked = anyEvent(for: sourceID) {
                if let plan = tracked.plan {
                    for step in plan.steps { scheduler.cancel(step) }
                }
                context.delete(tracked)
                try? context.save()
            }
            await scheduler.refreshWindow(context: context, settings: settings)
        }
    }

    func dismissUndo() {
        undoExpiry?.cancel()
        Task { await expireUndo() }
    }

    func performUndo() async {
        guard let action = pendingUndo else { return }
        undoExpiry?.cancel()
        pendingUndo = nil

        switch action.kind {
        case .tracked(let sourceIDs):
            // Nothing is lost undoing a track: the plan is seconds old and the user made none
            // of it.
            for sourceID in sourceIDs {
                await untrackImmediately(sourceID: sourceID)
            }
        case .untracked(let sourceID):
            // The row was held rather than deleted, so its plan, notes and contacts are intact.
            sync.deferredUntrackIDs.remove(sourceID)
            settings.manuallyExcludedSourceIDs.removeAll { $0 == sourceID }
            if !settings.manuallyIncludedSourceIDs.contains(sourceID) {
                settings.manuallyIncludedSourceIDs.append(sourceID)
            }
            anyEvent(for: sourceID)?.disappearedAt = nil
            try? context.save()
        }
        await scheduler.refreshWindow(context: context, settings: settings)
    }

    // MARK: Tracking

    /// The tracked row for a source id, excluding one that is being held open for an undo.
    ///
    /// Untracking now retires the row rather than deleting it, so the undo can restore its plan
    /// and notes intact — which means "is this tracked?" has to ignore retired rows, or an event
    /// the user just untracked would still show the amber rail.
    func trackedEvent(for sourceID: String) -> TrackedEvent? {
        guard let row = anyEvent(for: sourceID) else { return nil }
        return row.disappearedAt == nil ? row : nil
    }

    /// Including retired rows. Only the undo machinery wants this.
    private func anyEvent(for sourceID: String) -> TrackedEvent? {
        var descriptor = FetchDescriptor<TrackedEvent>(predicate: #Predicate { $0.sourceID == sourceID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func track(_ event: NormalizedEvent) async {
        await sync.track(event, context: context, settings: settings)
        // The first plan is the moment notifications become worth asking about.
        await requestNotificationsIfNeeded()
        await scheduler.refreshWindow(context: context, settings: settings)
        offerUndo(UndoableAction(
            kind: .tracked(sourceIDs: [event.sourceID]),
            sentence: "Tracking \(event.title)"
        ))
    }

    /// Tracks several events at once.
    ///
    /// Classification here is deliberately the **heuristic** one, even on a device where the
    /// model is available: a model call costs seconds, and twenty of them in a row would freeze
    /// the screen for most of a minute. The heuristic is the shippable fallback by design, and
    /// anything it is unsure about surfaces the confirmation chip on the Plan screen — which is
    /// a better trade than a progress bar.
    func trackBulk(_ events: [NormalizedEvent]) async {
        guard !events.isEmpty else { return }
        let previousProvider = planning.currentProvider
        planning.use(provider: HeuristicProvider())
        defer { planning.use(provider: previousProvider) }

        for event in events {
            await sync.track(event, context: context, settings: settings)
        }
        await requestNotificationsIfNeeded()
        await scheduler.refreshWindow(context: context, settings: settings)

        offerUndo(UndoableAction(
            kind: .tracked(sourceIDs: events.map(\.sourceID)),
            sentence: events.count == 1
                ? "Tracking \(events[0].title)"
                : "Tracking \(events.count) events"
        ))
    }

    /// Untracks, but holds the row open until the undo window closes — so an undo restores the
    /// plan, the notes and the people, not just the event.
    func untrack(_ event: NormalizedEvent) async {
        if let tracked = trackedEvent(for: event.sourceID), let plan = tracked.plan {
            for step in plan.steps { scheduler.cancel(step) }
        }
        sync.deferredUntrackIDs.insert(event.sourceID)

        settings.manuallyIncludedSourceIDs.removeAll { $0 == event.sourceID }
        if !settings.manuallyExcludedSourceIDs.contains(event.sourceID) {
            settings.manuallyExcludedSourceIDs.append(event.sourceID)
        }
        anyEvent(for: event.sourceID)?.disappearedAt = .now
        try? context.save()
        await scheduler.refreshWindow(context: context, settings: settings)

        offerUndo(UndoableAction(
            kind: .untracked(sourceID: event.sourceID),
            sentence: "Stopped tracking \(event.title)"
        ))
    }

    private func untrackImmediately(sourceID: String) async {
        if let tracked = anyEvent(for: sourceID), let plan = tracked.plan {
            for step in plan.steps { scheduler.cancel(step) }
        }
        sync.deferredUntrackIDs.remove(sourceID)
        await sync.untrack(sourceID: sourceID, context: context, settings: settings)
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

    /// Undoes a done or skipped step.
    ///
    /// Without this, a single stray swipe was permanent: nothing anywhere wrote `.pending` back,
    /// so the only way to recover a mis-swiped step was to delete it — which also destroyed the
    /// outcome the skip-rate diagnostic depends on. The recorded outcome is removed too, so the
    /// diagnostic does not keep counting a resolution the user took back.
    func reopen(_ step: PrepStep) async {
        guard step.state.isResolved || step.state == .fired else { return }
        StepOutcome.removeOutcome(forStepID: step.id, in: context)
        step.state = .pending
        step.snoozedUntil = nil
        try? context.save()
        await scheduler.refreshWindow(context: context, settings: settings)
    }

    /// True when reminders cannot arrive. Surfaced on Today and in Settings — an app whose whole
    /// job is notifications must not go quiet without saying why.
    var notificationsAreBlocked: Bool {
        switch scheduler.authorizationStatus {
        case .denied: true
        case .notDetermined: false
        default: false
        }
    }

    var notificationStatusLabel: String {
        switch scheduler.authorizationStatus {
        case .authorized: "On"
        case .provisional: "Quiet delivery"
        case .ephemeral: "Temporary"
        case .denied: "Off"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
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

    // MARK: People and handoff

    func addContacts(_ people: [(identifier: String, name: String)], to event: TrackedEvent, audience: Audience) {
        for person in people where !event.contacts.contains(where: { $0.contactIdentifier == person.identifier }) {
            let contact = EventContact(
                contactIdentifier: person.identifier,
                displayName: person.name,
                audience: audience
            )
            contact.event = event
            event.contacts.append(contact)
            context.insert(contact)
        }
        try? context.save()
    }

    func removeContact(_ contact: EventContact, from event: TrackedEvent) {
        event.contacts.removeAll { $0.id == contact.id }
        context.delete(contact)
        try? context.save()
    }

    /// The compose sheet reported `.sent`, so the step is genuinely done.
    func messageWasSent(for step: PrepStep) async {
        step.handedOffAt = .now
        await resolve(step, as: .done)
    }

    // MARK: Calendar write-back

    let calendarWriter = CalendarWriter()

    /// Creates the working block for a buildWork step and remembers it so it can be undone.
    /// Returns a sentence when it could not, rather than failing silently.
    func createWorkBlock(for step: PrepStep, event: TrackedEvent) async -> String? {
        guard step.calendarBlockIdentifier == nil else { return "That block is already on your calendar." }
        var block = WorkBlockPlanner.proposedBlock(for: event)
        block.calendarID = settings.writeBackCalendarID
        do {
            guard let identifier = try await calendarWriter.createBlock(block) else {
                return "None of your calendars can be written to. Subscribed calendars are read-only."
            }
            step.calendarBlockIdentifier = identifier
            try? context.save()
            await resolve(step, as: .done)
            return nil
        } catch EventSourceError.denied {
            return "Forerun needs permission to add to your calendar. You can turn that on in Settings."
        } catch {
            return "Forerun couldn't add the block."
        }
    }

    func removeWorkBlock(for step: PrepStep) async {
        guard let identifier = step.calendarBlockIdentifier else { return }
        _ = await calendarWriter.removeBlock(identifier: identifier)
        step.calendarBlockIdentifier = nil
        try? context.save()
    }

    // MARK: Scratchpad

    func addNote(_ text: String, to event: TrackedEvent) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        insertScratchpad(ScratchpadItem(kind: .note, text: trimmed), into: event)
    }

    func addLink(_ urlString: String, title: String, to event: TrackedEvent) {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // People paste "docs.google.com/…" far more often than they type the scheme.
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "https://\(trimmed)" }
        guard URL(string: trimmed) != nil else { return }
        insertScratchpad(
            ScratchpadItem(
                kind: .link,
                text: title.trimmingCharacters(in: .whitespacesAndNewlines),
                urlString: trimmed
            ),
            into: event
        )
    }

    func addPhoto(_ data: Data, to event: TrackedEvent) {
        guard !data.isEmpty else { return }
        insertScratchpad(ScratchpadItem(kind: .photo, imageData: data), into: event)
    }

    private func insertScratchpad(_ item: ScratchpadItem, into event: TrackedEvent) {
        item.sortOrder = (event.scratchpad.map(\.sortOrder).max() ?? -1) + 1
        item.event = event
        event.scratchpad.append(item)
        context.insert(item)
        try? context.save()
    }

    func removeScratchpadItem(_ item: ScratchpadItem, from event: TrackedEvent) {
        event.scratchpad.removeAll { $0.id == item.id }
        context.delete(item)
        try? context.save()
    }

    // MARK: Drafting

    /// The pre-filled message body. Same validator as a notification body, but a longer budget —
    /// a message to your team can afford a sentence a lock screen cannot.
    func draftMessage(for step: PrepStep, event: TrackedEvent) async -> String {
        let request = PhrasingRequest(
            eventTitle: event.title,
            actionVerb: step.actionVerb,
            templateCopy: step.effectiveCopy,
            audience: step.audience,
            relativeLabel: step.relativeLabel,
            characterBudget: 300
        )
        if let phrased = await planning.phraseForHandoff(request) { return phrased }
        return step.effectiveCopy
    }

    /// Plain text a co-leader can read in a message. No sync, no invitation, no account.
    func planAsText(for event: TrackedEvent) -> String {
        PlanTextRenderer.render(event)
    }

    // MARK: Data

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return [version, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    func exportJSON() -> Data? {
        try? DataExporter.export(
            from: context,
            settings: settings,
            appVersion: appVersion
        )
    }

    /// Leaves the app in a first-launch state without needing a relaunch.
    func deleteAllData() async {
        scheduler.cancelAll()
        // The TickTick token lives in the Keychain, which survives both this and deleting the
        // app itself. Leaving it behind made two sentences in the privacy policy false, and left
        // the app reporting TickTick as connected with no connection date.
        await tickTickAuth.disconnect()
        DataExporter.deleteAll(in: context, settings: settings)
        await refreshTickTickState()
        await refresh()
    }

    /// The skip-rate diagnostic's read model. A pure roll-up over outcomes — never over people.
    func skipRateRows() -> [SkipRateRow] {
        let outcomes = (try? context.fetch(FetchDescriptor<StepOutcome>())) ?? []
        return SkipRateRow.rows(from: outcomes.map {
            StepOutcomeSnapshot(
                playbookStepID: $0.playbookStepID,
                kind: $0.kind,
                audience: $0.audience,
                offsetSeconds: $0.offsetSeconds,
                state: $0.state
            )
        })
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
