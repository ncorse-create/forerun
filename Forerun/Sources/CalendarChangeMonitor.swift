import EventKit
import ForerunCore
import Foundation

/// Watches for calendar edits made outside Forerun.
///
/// `.EKEventStoreChanged` is coarse — it says "something changed" and never what — and it can
/// arrive in bursts while the Calendar app writes a batch. So it is debounced and the response
/// is always a full windowed re-fetch rather than an attempted delta.
@MainActor
final class CalendarChangeMonitor {
    static let debounce: Duration = .seconds(2)

    private var observationTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?

    deinit {
        observationTask?.cancel()
        pendingTask?.cancel()
    }

    func start(onChange: @escaping @MainActor @Sendable () async -> Void) {
        stop()
        observationTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(named: .EKEventStoreChanged)
            for await _ in notifications {
                guard let self, !Task.isCancelled else { return }
                self.scheduleDebounced(onChange)
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func scheduleDebounced(_ onChange: @escaping @MainActor @Sendable () async -> Void) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await onChange()
        }
    }
}

/// Recomputes fire dates when the user crosses a timezone (invariant 10).
///
/// Offsets are stored as intervals, so the fix is always "rebuild the fire dates in the current
/// calendar," never "shift the stored times."
@MainActor
final class TimeZoneChangeMonitor {
    private var observationTask: Task<Void, Never>?

    deinit { observationTask?.cancel() }

    func start(onChange: @escaping @MainActor @Sendable () async -> Void) {
        stop()
        observationTask = Task {
            let notifications = NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange)
            for await _ in notifications {
                guard !Task.isCancelled else { return }
                await onChange()
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }
}
