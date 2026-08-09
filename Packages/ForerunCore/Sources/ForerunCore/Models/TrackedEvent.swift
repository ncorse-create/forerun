import Foundation
import SwiftData

/// An event the user asked Forerun to pay attention to.
///
/// Enum-typed fields are stored as their raw strings so that `#Predicate` can compare them
/// directly and so the on-disk representation is legible in the JSON export.
///
/// This does **not** make unknown values durable: every computed accessor coerces an
/// unrecognized raw to its fallback the first time anything writes through it, so a value from
/// a newer build is lost on the first save, not preserved. That is an accepted trade — the
/// fallbacks are chosen to fail in the safe direction (see `PrepStep.audience` and
/// `PrepStep.state`) — but it is not a forward-compatibility mechanism, and a genuine schema
/// change still needs a new `VersionedSchema` and a migration stage.
@Model
public final class TrackedEvent {
    @Attribute(.unique) public var id: UUID
    /// Unique per occurrence. See `NormalizedEvent.sourceID`.
    public var sourceID: String
    public var sourceTypeRaw: String
    public var title: String
    public var notes: String?
    public var startDate: Date
    public var endDate: Date?
    public var isAllDay: Bool
    public var location: String?
    public var calendarID: String
    public var calendarName: String
    public var colorHex: String?
    public var colorFamilyRaw: String
    /// TickTick only.
    public var priority: Int?
    public var hasRecurrenceRules: Bool

    public var kindRaw: String
    public var kindConfidence: Double
    public var kindWasConfirmedByUser: Bool

    public var trackedAt: Date
    public var lastSyncedAt: Date
    /// Set when the event vanished from its source. Kept rather than deleted so a plan the user
    /// edited is not silently destroyed by a calendar hiccup.
    public var disappearedAt: Date?
    /// Set when a TickTick task was matched to an Apple Calendar event for the same thing.
    public var isDuplicateOfSourceID: String?

    @Relationship(deleteRule: .cascade, inverse: \PrepPlan.event)
    public var plan: PrepPlan?

    @Relationship(deleteRule: .cascade, inverse: \ScratchpadItem.event)
    public var scratchpad: [ScratchpadItem]

    @Relationship(deleteRule: .cascade, inverse: \EventContact.event)
    public var contacts: [EventContact]

    public init(
        id: UUID = UUID(),
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
        hasRecurrenceRules: Bool = false,
        kind: EventKind = .unknown,
        kindConfidence: Double = 0,
        kindWasConfirmedByUser: Bool = false,
        trackedAt: Date = .now,
        lastSyncedAt: Date = .now
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceTypeRaw = sourceType.rawValue
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.colorHex = colorHex
        self.colorFamilyRaw = colorFamily.rawValue
        self.priority = priority
        self.hasRecurrenceRules = hasRecurrenceRules
        self.kindRaw = kind.rawValue
        self.kindConfidence = kindConfidence
        self.kindWasConfirmedByUser = kindWasConfirmedByUser
        self.trackedAt = trackedAt
        self.lastSyncedAt = lastSyncedAt
        self.disappearedAt = nil
        self.isDuplicateOfSourceID = nil
        self.scratchpad = []
        self.contacts = []
    }
}

public extension TrackedEvent {
    var sourceType: EventSourceType {
        get { EventSourceType(rawValue: sourceTypeRaw) ?? .eventkit }
        set { sourceTypeRaw = newValue.rawValue }
    }

    var colorFamily: ColorFamily {
        get { ColorFamily(rawValue: colorFamilyRaw) ?? .gray }
        set { colorFamilyRaw = newValue.rawValue }
    }

    var kind: EventKind {
        get { EventKind(rawValue: kindRaw) ?? .unknown }
        set { kindRaw = newValue.rawValue }
    }

    var isDuplicate: Bool { isDuplicateOfSourceID != nil }
    var hasDisappeared: Bool { disappearedAt != nil }

    /// The confidence below which the user is asked to confirm the kind.
    static let confidenceGate: Double = 0.7

    var needsKindConfirmation: Bool {
        !kindWasConfirmedByUser && (kind == .unknown || kindConfidence < Self.confidenceGate)
    }

    /// Everything the engine needs, as a value type. Keeps the engine free of SwiftData.
    var planInput: PlanInput {
        PlanInput(
            eventID: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            kind: kind
        )
    }

    /// Copies the mutable fields from a fresh sync. Deliberately does **not** touch `kind`,
    /// `kindWasConfirmedByUser`, or anything the user owns.
    ///
    /// Refuses a mismatched record outright. `sourceID` is the identity, and it is not among
    /// the fields copied, so a mis-wired call would otherwise write another event's title and
    /// date onto this row and leave no trace of having done it.
    func apply(_ event: NormalizedEvent, at date: Date = .now) {
        guard event.sourceID == sourceID else { return }
        title = event.title
        notes = event.notes
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        location = event.location
        calendarID = event.calendarID
        calendarName = event.calendarName
        colorHex = event.colorHex
        colorFamily = event.colorFamily
        priority = event.priority
        hasRecurrenceRules = event.hasRecurrenceRules
        lastSyncedAt = date
        disappearedAt = nil
    }
}
