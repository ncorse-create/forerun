import EventKit
import ForerunCore
import Foundation

/// Turns the buildWork "block the working hours" step into an actual calendar event.
///
/// This is the one place Forerun writes to a calendar, and it only ever does it because the user
/// tapped a button that says so. Its own `EKEventStore` and its own permission (`writeOnly` is
/// enough) keep the write path separate from the read path — the app cannot accidentally acquire
/// write access as a side effect of reading.
actor CalendarWriter {
    private let store = EKEventStore()

    /// The tag Forerun stamps into a written event's notes so it can recognise its own work and
    /// avoid creating a second block for the same step.
    static let signature = "— blocked by Forerun"

    nonisolated static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Write-only access is sufficient here and is the smaller ask, but a user who already
    /// granted full access should not be prompted again.
    func requestAccess() async -> Bool {
        switch Self.authorizationStatus {
        case .fullAccess, .writeOnly:
            return true
        default:
            return (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        }
    }

    struct Block: Sendable {
        var title: String
        var start: Date
        var end: Date
        var calendarID: String?
        var notes: String?
    }

    /// Creates the block and returns its identifier so it can be undone.
    ///
    /// Returns nil rather than throwing when there is no writable calendar — every subscribed
    /// calendar is read-only, and a user whose only calendars are subscriptions has nowhere for
    /// this to go.
    func createBlock(_ block: Block) async throws -> String? {
        guard await requestAccess() else { throw EventSourceError.denied }

        let calendar = resolveCalendar(id: block.calendarID)
        guard let calendar, calendar.allowsContentModifications else { return nil }

        let event = EKEvent(eventStore: store)
        event.title = block.title
        event.startDate = block.start
        event.endDate = block.end
        event.calendar = calendar
        event.notes = [block.notes, Self.signature].compactMap { $0 }.joined(separator: "\n\n")

        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    /// Undo. Only removes an event Forerun wrote — the signature check means a mis-stored
    /// identifier can never delete something of the user's.
    func removeBlock(identifier: String) async -> Bool {
        guard let event = store.event(withIdentifier: identifier) else { return false }
        guard event.notes?.contains(Self.signature) == true else { return false }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }

    func writableCalendars() -> [CalendarSummary] {
        store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { calendar in
                CalendarSummary(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source?.title ?? "",
                    colorFamily: EventKitSource.colorFamily(for: calendar),
                    colorHex: calendar.cgColor.flatMap(EventKitSource.hexString(from:)),
                    isSubscribed: calendar.type == .subscription,
                    isWritable: true
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    private func resolveCalendar(id: String?) -> EKCalendar? {
        if let id, let match = store.calendar(withIdentifier: id), match.allowsContentModifications {
            return match
        }
        if let defaultCalendar = store.defaultCalendarForNewEvents,
           defaultCalendar.allowsContentModifications {
            return defaultCalendar
        }
        return store.calendars(for: .event).first(where: \.allowsContentModifications)
    }
}

/// Works out what block a buildWork event actually wants.
enum WorkBlockPlanner {
    /// The rung that offers to create the block.
    static let stepID = "buildWork.d-3.self"

    /// A deep-work block defaults to the event's own span, or three hours when the event is
    /// all-day or zero-length — long enough to be worth defending, short enough to survive
    /// contact with a real day.
    static let defaultDuration: TimeInterval = 3 * 3_600

    @MainActor
    static func proposedBlock(for event: TrackedEvent) -> CalendarWriter.Block {
        let start: Date
        let end: Date

        if event.isAllDay {
            var calendar = Calendar.current
            calendar.timeZone = .current
            let day = calendar.startOfDay(for: event.startDate)
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            end = start.addingTimeInterval(defaultDuration)
        } else if let eventEnd = event.endDate, eventEnd > event.startDate {
            start = event.startDate
            end = eventEnd
        } else {
            start = event.startDate
            end = event.startDate.addingTimeInterval(defaultDuration)
        }

        return CalendarWriter.Block(
            title: event.title,
            start: start,
            end: end,
            calendarID: nil,
            notes: "Working time for \(event.title)."
        )
    }

    @MainActor
    static func isOfferable(_ step: PrepStep, event: TrackedEvent) -> Bool {
        event.kind == .buildWork && step.playbookStepID == stepID
    }
}
