import ForerunCore
import Foundation
import SwiftData
import UserNotifications

/// Puts the ladder on the system's schedule and keeps it there.
///
/// The engine has already decided every fire date by the time anything here runs. This type's
/// only judgement is *which* of those dates fit inside iOS's pending-request limit, and it
/// resolves that purely by taking the earliest ones.
@MainActor
@Observable
final class NotificationScheduler {

    /// iOS keeps at most 64 pending local notification requests per app and silently drops the
    /// rest. Staying under 50 leaves room for the ones a rescheduling pass adds before it has
    /// finished removing the ones it replaced.
    static let maxPendingRequests = 50
    /// A rolling window rather than "everything." Sixty days of tracked events would blow the
    /// limit on its own; two weeks is comfortably more than a background refresh cycle.
    static let windowDays = 14
    static let backgroundTaskIdentifier = "app.persue.forerun.refresh"

    enum Category {
        static let step = "forerun.step"
    }

    enum Action {
        static let done = "forerun.step.done"
        static let snooze = "forerun.step.snooze"
        static let skip = "forerun.step.skip"
    }

    private let center: UNUserNotificationCenter
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var pendingCount = 0
    /// Set when the window was larger than the limit, so Settings can say so honestly rather
    /// than letting later steps quietly not arrive.
    private(set) var truncatedStepCount = 0
    private var isRefreshing = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: Authorization

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    /// Contextual, per locked decision 6 — asked when the first plan is saved, not at launch.
    /// Badges are deliberately **not** requested: locked decision 5 forbids a count on the icon,
    /// and asking for a permission the app will never use is a reviewer flag.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorizationStatus()
        switch authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshAuthorizationStatus()
            return granted
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    func registerCategories() {
        let done = UNNotificationAction(
            identifier: Action.done,
            title: "Done",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze,
            title: "Snooze 1 day",
            options: []
        )
        let skip = UNNotificationAction(
            identifier: Action.skip,
            title: "Skip",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Category.step,
            actions: [done, snooze, skip],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: Scheduling

    /// Rebuilds the whole pending set from the database.
    ///
    /// A full rebuild rather than a diff, deliberately: the alternative is tracking which
    /// requests correspond to which steps across snoozes, edits, regenerations and calendar
    /// changes, and getting that wrong means either a missing notification or a duplicate. The
    /// set is small enough that correctness is worth more than the saved work.
    func refreshWindow(context: ModelContext, settings: AppSettings, now: Date = .now) async {
        // Three callers race this on a cold launch — app start, the scene becoming active, and
        // the Events screen's task. Interleaved passes can remove an identifier another pass
        // just added, leaving the window short until the next refresh.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral
        else { return }

        let windowEnd = Calendar.current.date(byAdding: .day, value: Self.windowDays, to: now) ?? now
        let steps = schedulableSteps(context: context, from: now, to: windowEnd)

        let ordered = steps.sorted { $0.effectiveFireDate < $1.effectiveFireDate }
        let scheduled = Array(ordered.prefix(Self.maxPendingRequests))
        truncatedStepCount = max(0, ordered.count - scheduled.count)

        // Remove everything of ours, then re-add. Requests are all prefixed, so this cannot
        // touch a notification some other part of the app owns.
        let existing = await center.pendingNotificationRequests()
        let ours = existing.map(\.identifier).filter { $0.hasPrefix("step.") }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        for entry in scheduled {
            let request = makeRequest(for: entry, now: now)
            try? await center.add(request)
        }
        pendingCount = scheduled.count
    }

    /// A step and the date it should actually fire, which is its snooze target when it has one.
    struct ScheduledStep {
        let step: PrepStep
        let eventTitle: String
        let eventID: UUID
        let effectiveFireDate: Date
    }

    private func schedulableSteps(
        context: ModelContext,
        from start: Date,
        to end: Date
    ) -> [ScheduledStep] {
        let events = (try? context.fetch(FetchDescriptor<TrackedEvent>())) ?? []
        var results: [ScheduledStep] = []

        for event in events where event.disappearedAt == nil && !event.isDuplicate {
            guard let plan = event.plan else { continue }
            for step in plan.steps where step.state.isSchedulable {
                let fireDate = step.snoozedUntil ?? step.fireDate
                guard fireDate > start, fireDate <= end else { continue }
                results.append(ScheduledStep(
                    step: step,
                    eventTitle: event.title,
                    eventID: event.id,
                    effectiveFireDate: fireDate
                ))
            }
        }
        return results
    }

    private func makeRequest(for entry: ScheduledStep, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = entry.eventTitle
        content.body = entry.step.effectiveCopy
        content.sound = .default
        content.categoryIdentifier = Category.step
        // Grouped per event so five steps for one Sunday service stack rather than filling the
        // lock screen.
        content.threadIdentifier = entry.eventID.uuidString
        content.userInfo = [
            "stepID": entry.step.id.uuidString,
            "eventID": entry.eventID.uuidString
        ]
        content.interruptionLevel = .active
        // No badge. Ever. Locked decision 5 — `content.badge` is left nil on purpose.

        // A calendar trigger, not an interval one. An interval trigger fires at an absolute
        // instant, so a fire date up to fourteen days out that straddles a DST transition
        // arrives an hour off its intended wall clock — which can put it inside quiet hours.
        // The `NSSystemTimeZoneDidChange` recompute cannot save it either: the app is suspended
        // at 02:00 when the transition lands, so the correction only arrives on the next
        // foreground, possibly after the mis-timed notification has already gone out.
        let target = max(entry.effectiveFireDate, now.addingTimeInterval(1))
        // `.second` is included deliberately. Dropping it floors the trigger to the top of the
        // minute, so a step due later in the *current* minute produced components that had
        // already elapsed — and a non-repeating calendar trigger whose date has passed never
        // delivers at all.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: target
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(
            identifier: entry.step.notificationIdentifier,
            content: content,
            trigger: trigger
        )
    }

    // MARK: Verification

    /// A pending request as **iOS** holds it, not as the app believes it to be.
    ///
    /// The distinction is the whole point. `pendingCount` is what the last scheduling pass
    /// thought it wrote; this is what the system actually accepted and will actually deliver. If
    /// those two ever disagree, the app is lying to the user about whether they will be reminded.
    struct PendingReminder: Identifiable, Sendable {
        let id: String
        let title: String
        let body: String
        let fireDate: Date?
        let isTest: Bool
    }

    /// Test reminders use their own prefix so `refreshWindow`'s "remove everything of ours" sweep
    /// — which matches on `step.` — cannot delete one before it fires.
    private static let testIdentifier = "diagnostic.test"

    func pendingReminders() async -> [PendingReminder] {
        await center.pendingNotificationRequests()
            .map { request in
                let fireDate: Date? = switch request.trigger {
                case let calendarTrigger as UNCalendarNotificationTrigger:
                    calendarTrigger.nextTriggerDate()
                case let intervalTrigger as UNTimeIntervalNotificationTrigger:
                    intervalTrigger.nextTriggerDate()
                default:
                    nil
                }
                return PendingReminder(
                    id: request.identifier,
                    title: request.content.title,
                    body: request.content.body,
                    fireDate: fireDate,
                    isTest: request.identifier == Self.testIdentifier
                )
            }
            .sorted { ($0.fireDate ?? .distantFuture) < ($1.fireDate ?? .distantFuture) }
    }

    /// Schedules one real reminder a few seconds out, so "do notifications work on this iPhone"
    /// can be answered by looking at the lock screen instead of by reading code.
    ///
    /// Deliberately a real `UNNotificationRequest` through the real center with the real category
    /// — a test that takes a different path proves nothing about the path that matters.
    @discardableResult
    func sendTestReminder(in seconds: TimeInterval = 15) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Forerun"
        content.body = "Reminders are working. This is the only one Forerun will ever send you "
            + "that isn't about a real event."
        content.sound = .default
        content.categoryIdentifier = Category.step
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: Self.testIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    // MARK: Cancellation

    func cancel(_ step: PrepStep) {
        center.removePendingNotificationRequests(withIdentifiers: [step.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [step.notificationIdentifier])
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        // Delivered banners too. "Delete all data" leaving Forerun notifications sitting in
        // Notification Center is not "everything removed."
        center.removeAllDeliveredNotifications()
        pendingCount = 0
        truncatedStepCount = 0
    }
}
