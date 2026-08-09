import EventKit
import ForerunCore
import Foundation

/// A calendar the user can choose to track, flattened for the settings UI.
struct CalendarSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
    let colorFamily: ColorFamily
    let colorHex: String?
    let isSubscribed: Bool
    let isWritable: Bool
}

/// Reads Apple Calendar. Read-only for ingestion — the one write path in the app is the
/// buildWork block-out in `CalendarWriter`, which uses its own store and its own permission.
///
/// An actor because `EKEventStore` is not `Sendable` and must not be shared across tasks, and
/// because the store has to be long-lived: a store created per fetch stops posting
/// `.EKEventStoreChanged`, so change detection would silently die.
actor EventKitSource: EventSource {
    private let store = EKEventStore()
    private var selectedCalendarIDs: Set<String> = []

    nonisolated var displayName: String { "Apple Calendar" }

    // MARK: Authorization

    /// iOS 17+ splits calendar access, and `.writeOnly` is a state a real user can land in.
    /// Checking only for `.denied` would let a write-only app fall through to "authorized" and
    /// then read nothing, forever, with no error to show.
    nonisolated static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var isAuthorized: Bool {
        Self.authorizationStatus == .fullAccess
    }

    nonisolated static var authorizationError: EventSourceError? {
        switch authorizationStatus {
        case .fullAccess: nil
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .writeOnlyAccess
        @unknown default: .denied
        }
    }

    /// Contextual, per locked decision 6 — only ever called from "Connect Apple Calendar."
    func requestAccess() async throws -> Bool {
        if Self.authorizationStatus == .fullAccess { return true }
        return try await store.requestFullAccessToEvents()
    }

    // MARK: Calendars

    func setSelectedCalendarIDs(_ ids: Set<String>) {
        selectedCalendarIDs = ids
    }

    func availableCalendars() -> [CalendarSummary] {
        guard Self.authorizationStatus == .fullAccess else { return [] }
        return store.calendars(for: .event)
            .map { calendar in
                let hex = calendar.cgColor.flatMap(Self.hexString(from:))
                return CalendarSummary(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source?.title ?? "",
                    colorFamily: Self.colorFamily(for: calendar),
                    colorHex: hex,
                    isSubscribed: calendar.type == .subscription,
                    isWritable: calendar.allowsContentModifications
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    /// Calendars the block-out step may write into. Subscribed calendars are read-only, which
    /// is exactly why this filter exists.
    func writableCalendars() -> [CalendarSummary] {
        availableCalendars().filter(\.isWritable)
    }

    // MARK: Fetch

    func fetchEvents(from start: Date, to end: Date) async throws -> [NormalizedEvent] {
        if let error = Self.authorizationError { throw error }

        let all = store.calendars(for: .event)
        let calendars = selectedCalendarIDs.isEmpty
            ? all
            : all.filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap(Self.normalize(_:))
    }

    // MARK: Normalizing

    /// `eventIdentifier` is shared by every occurrence of a recurring series, so it cannot be
    /// the identity on its own — a semester of Sunday services would collapse into one row and
    /// each sync would overwrite the previous occurrence's plan. The occurrence start
    /// disambiguates them (Spike B).
    static func compositeSourceID(identifier: String, start: Date) -> String {
        "\(identifier)|\(start.timeIntervalSinceReferenceDate)"
    }

    private static func normalize(_ event: EKEvent) -> NormalizedEvent? {
        // A nil identifier cannot be matched on the next sync. Synthesizing one would produce a
        // fresh duplicate every time, so the event is skipped instead.
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else { return nil }
        guard let start = event.startDate else { return nil }
        guard let calendar = event.calendar else { return nil }

        return NormalizedEvent(
            sourceID: compositeSourceID(identifier: identifier, start: start),
            sourceType: .eventkit,
            title: event.title ?? "Untitled",
            notes: event.notes,
            startDate: start,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            calendarID: calendar.calendarIdentifier,
            calendarName: calendar.title,
            colorHex: calendar.cgColor.flatMap(hexString(from:)),
            colorFamily: colorFamily(for: calendar),
            priority: nil,
            hasRecurrenceRules: event.hasRecurrenceRules
        )
    }

    // MARK: Colour

    /// A calendar colour can carry a non-RGB colour space, and reading `components` off it
    /// directly gives a garbage hue. Converting to sRGB first is not optional.
    static func colorFamily(for calendar: EKCalendar) -> ColorFamily {
        guard let rgb = sRGBComponents(of: calendar.cgColor) else { return .gray }
        return ColorFamily.from(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    static func sRGBComponents(of color: CGColor?) -> (r: Double, g: Double, b: Double)? {
        guard let color,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3
        else { return nil }
        return (Double(components[0]), Double(components[1]), Double(components[2]))
    }

    static func hexString(from color: CGColor) -> String? {
        guard let rgb = sRGBComponents(of: color) else { return nil }
        let clamp = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(rgb.r), clamp(rgb.g), clamp(rgb.b))
    }
}
