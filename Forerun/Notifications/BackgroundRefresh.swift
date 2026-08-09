import BackgroundTasks
import ForerunCore
import Foundation

/// Extends the rolling notification window while the app is closed.
///
/// This is the one thing that has to work when the user never opens Forerun: a ladder set up in
/// March has to keep producing notifications in May. The window is 14 days and the refresh is
/// requested every 6 hours, which leaves an enormous margin — iOS grants background time on its
/// own schedule, and missing several days in a row is normal and harmless.
@MainActor
enum BackgroundRefresh {
    static let identifier = NotificationScheduler.backgroundTaskIdentifier
    static let interval: TimeInterval = 6 * 3_600

    private static var handler: (@MainActor @Sendable () async -> Void)?

    /// Must be called before the app finishes launching. Registering later throws.
    static func register(onRefresh: @escaping @MainActor @Sendable () async -> Void) {
        handler = onRefresh
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await run(task)
            }
        }
    }

    private static func run(_ task: BGAppRefreshTask) async {
        // Always request the next one first. If the body throws or the system kills the task,
        // an un-rescheduled app never wakes again and the ladder silently stops.
        schedule()

        // The handler is installed before the work begins. Assigning it afterwards leaves a
        // gap in which an expiring task cannot cancel anything.
        let work = Task { @MainActor in
            // A one-tick yield lets the expiration handler be installed first without needing a
            // second task to own the cancellation.
            await Task.yield()
            await handler?()
        }
        task.expirationHandler = {
            work.cancel()
        }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission fails on a simulator and when the user has background refresh off.
            // Neither is recoverable and neither is worth surfacing: the app still refreshes on
            // every foreground, which is the common case.
        }
    }
}
