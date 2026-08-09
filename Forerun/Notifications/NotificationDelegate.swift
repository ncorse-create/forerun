import ForerunCore
import Foundation
import SwiftData
import UserNotifications

/// Handles taps and the three notification actions.
///
/// Resolving an action writes a `StepOutcome` as well as updating the step, because the outcome
/// is what the skip-rate diagnostic reads — and the whole point of that diagnostic is that a
/// step you dismissed from the lock screen counts the same as one you dismissed in the app.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// How long a snooze is. One day, not one hour — the ladder's rungs are days apart, so an
    /// hour would land the reminder in the same afternoon it was already ignored in.
    static let snoozeInterval: TimeInterval = 86_400

    var context: ModelContext?
    var settings: AppSettings?
    weak var scheduler: NotificationScheduler?
    /// Snooze is a scheduling decision, so it goes through the engine rather than through
    /// arithmetic here. See `PlanningCoordinator.snooze`.
    weak var planning: PlanningCoordinator?
    /// Called when a notification is tapped, so the app can push the right plan.
    var onDeepLink: (@MainActor (UUID) -> Void)?

    // MARK: Presentation

    /// Banner and list, no sound while the app is open. A sound for something the user is
    /// already looking at is noise.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    // MARK: Actions

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let identifier = response.actionIdentifier
        guard
            let stepString = info["stepID"] as? String,
            let stepID = UUID(uuidString: stepString),
            let eventString = info["eventID"] as? String,
            let eventID = UUID(uuidString: eventString)
        else { return }

        await handle(actionIdentifier: identifier, stepID: stepID, eventID: eventID)
    }

    func handle(actionIdentifier: String, stepID: UUID, eventID: UUID) async {
        guard let context else { return }

        var descriptor = FetchDescriptor<PrepStep>(predicate: #Predicate { $0.id == stepID })
        descriptor.fetchLimit = 1
        guard let step = try? context.fetch(descriptor).first else { return }

        switch actionIdentifier {
        case NotificationScheduler.Action.done:
            resolve(step, as: .done, fromNotification: true, context: context)
            // Clear the delivered banner too, the same as Skip does. Leaving a notification for
            // something already marked done sitting in Notification Center is the kind of small
            // inconsistency that makes an app feel unreliable.
            scheduler?.cancel(step)

        case NotificationScheduler.Action.skip:
            resolve(step, as: .skipped, fromNotification: true, context: context)
            scheduler?.cancel(step)

        case NotificationScheduler.Action.snooze:
            // Snoozing moves this one step and nothing else. It deliberately does not touch the
            // rest of the ladder — the other rungs were placed against the event, not against
            // this one. Placement goes through the engine so quiet hours, the daily budget and
            // the event's own start date all still apply.
            if await planning?.snooze(step) != true {
                // Nowhere legal left to put it. Skipping is the honest outcome: the step is
                // pending for something that has already happened or is about to.
                resolve(step, as: .skipped, fromNotification: true, context: context)
                scheduler?.cancel(step)
            }

        case UNNotificationDefaultActionIdentifier:
            onDeepLink?(eventID)
            // Tapping is not resolving. The step stays pending until the user says otherwise.
            if step.state == .pending { step.state = .fired }

        default:
            break
        }

        try? context.save()
        if let settings {
            await scheduler?.refreshWindow(context: context, settings: settings)
        }
    }

    /// Records the outcome alongside the state change. `StepOutcome` has no relationship to the
    /// event, so it survives the event being deleted — the diagnostic is about the playbook rung.
    func resolve(
        _ step: PrepStep,
        as state: StepState,
        fromNotification: Bool,
        context: ModelContext
    ) {
        guard !step.state.isResolved else { return }
        step.state = state

        // Custom steps have no playbook rung, so there is nothing about the *playbook* to learn
        // from them and they are not recorded.
        guard !step.isCustom else { return }
        let kind = step.plan?.event?.kind ?? .unknown
        context.insert(StepOutcome(
            playbookStepID: step.playbookStepID,
            kind: kind,
            audience: step.audience,
            offsetSeconds: step.offsetSeconds,
            state: state,
            fromNotification: fromNotification
        ))
    }
}
