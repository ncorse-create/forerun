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

        let interval = max(1, entry.effectiveFireDate.timeIntervalSince(now))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return UNNotificationRequest(
            identifier: entry.step.notificationIdentifier,
            content: content,
            trigger: trigger
        )
    }

    // MARK: Cancellation

    func cancel(_ step: PrepStep) {
        center.removePendingNotificationRequests(withIdentifiers: [step.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [step.notificationIdentifier])
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        pendingCount = 0
        truncatedStepCount = 0
    }
}
