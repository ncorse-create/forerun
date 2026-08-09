import Foundation

/// Where an event came from.
public enum EventSourceType: String, Codable, CaseIterable, Sendable {
    case eventkit
    case ticktick

    public var displayName: String {
        switch self {
        case .eventkit: "Apple Calendar"
        case .ticktick: "TickTick"
        }
    }
}

/// The shape every source produces. Sources differ wildly; everything downstream of this type
/// sees one thing.
public struct NormalizedEvent: Sendable, Equatable, Identifiable, Hashable {
    /// Stable across syncs and unique per *occurrence*. For EventKit this is a composite of the
    /// event identifier and the occurrence start, because every occurrence of a recurring
    /// series reports the same `eventIdentifier` (Spike B).
    public var sourceID: String
    public var sourceType: EventSourceType
    public var title: String
    public var notes: String?
    public var startDate: Date
    public var endDate: Date?
    public var isAllDay: Bool
    public var location: String?
    /// The owning calendar (EventKit) or project (TickTick).
    public var calendarID: String
    public var calendarName: String
    public var colorHex: String?
    public var colorFamily: ColorFamily
    /// TickTick only: None 0, Low 1, Medium 3, High 5. Nil for EventKit.
    public var priority: Int?
    public var hasRecurrenceRules: Bool

    public var id: String { sourceID }

    public init(
        sourceID: String,
        sourceType: EventSourceType,
        title: String,
        notes: String? = nil,
        startDate: Date,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        calendarID: String,
        calendarName: String,
        colorHex: String? = nil,
        colorFamily: ColorFamily = .gray,
        priority: Int? = nil,
        hasRecurrenceRules: Bool = false
    ) {
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.colorHex = colorHex
        self.colorFamily = colorFamily
        self.priority = priority
        self.hasRecurrenceRules = hasRecurrenceRules
    }

    /// Title reduced to a comparison key: case-folded, punctuation-stripped, whitespace
    /// collapsed. Used for TickTick↔EventKit deduplication, where the same thing arrives with
    /// "Sunday Service" from one source and "sunday service." from the other.
    public var normalizedTitle: String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }

    /// True when these two plausibly describe the same real-world thing. Used only for
    /// deduplication across sources, never within one source.
    public func isProbableDuplicate(of other: NormalizedEvent, within tolerance: TimeInterval = 15 * 60) -> Bool {
        guard sourceType != other.sourceType else { return false }
        guard normalizedTitle == other.normalizedTitle, !normalizedTitle.isEmpty else { return false }
        return abs(startDate.timeIntervalSince(other.startDate)) <= tolerance
    }
}

/// Read-only ingestion. Sources never write and never own scheduling.
public protocol EventSource: Sendable {
    var displayName: String { get }
    var isAuthorized: Bool { get async }
    func fetchEvents(from: Date, to: Date) async throws -> [NormalizedEvent]
}

/// Errors a source can surface that the UI must turn into a real sentence with a real recovery.
public enum EventSourceError: Error, Equatable, Sendable {
    /// The user has never been asked.
    case notDetermined
    /// The user said no.
    case denied
    /// MDM or parental controls. There is no recovery the user can perform in-app.
    case restricted
    /// iOS 17+ split calendar access. Write-only reads nothing, and is *not* the same as denied.
    case writeOnlyAccess
    /// TickTick's access token expired and there is no refresh token (Spike A).
    case reauthenticationRequired
    case network(String)
    case decoding(String)
}
