import Foundation
import SwiftData

/// What a piece of scratchpad material is.
public enum ScratchpadKind: String, Codable, CaseIterable, Sendable {
    case note
    case link
    case photo

    public var displayName: String {
        switch self {
        case .note: "Note"
        case .link: "Link"
        case .photo: "Photo"
        }
    }
}

/// Material attached to an event so it is *there* when the notification fires.
///
/// The friction this removes: "send leads the schedule" arrives, and then you go hunting for
/// the schedule. Notes, links and a photo of the whiteboard live on the event, and the
/// notification's deep link lands on them.
@Model
public final class ScratchpadItem {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var createdAt: Date
    /// The note body, the link's title, or the photo's caption.
    public var text: String
    /// Absolute URL string for `.link`.
    public var urlString: String?
    /// External storage keeps the photo out of the row and out of memory until it is asked for.
    @Attribute(.externalStorage) public var imageData: Data?
    public var sortOrder: Int

    public var event: TrackedEvent?

    public init(
        id: UUID = UUID(),
        kind: ScratchpadKind,
        text: String = "",
        urlString: String? = nil,
        imageData: Data? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.text = text
        self.urlString = urlString
        self.imageData = imageData
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public extension ScratchpadItem {
    var kind: ScratchpadKind {
        get { ScratchpadKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }

    var url: URL? {
        guard let urlString else { return nil }
        return URL(string: urlString)
    }

    /// One line for the Plan screen's material row.
    var summary: String {
        switch kind {
        case .note:
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
            return firstLine.isEmpty ? "Empty note" : firstLine
        case .link:
            if !text.isEmpty { return text }
            return url?.host.map { $0.replacingOccurrences(of: "www.", with: "") } ?? "Link"
        case .photo:
            return text.isEmpty ? "Photo" : text
        }
    }
}

/// A person attached to an event so a leader step can open a pre-filled compose sheet.
///
/// Only the identifier and a display name are stored. Never the contact card, never a phone
/// number — the number is resolved at compose time from the identifier, so Forerun's database
/// holds nothing that would be sensitive if it leaked.
@Model
public final class EventContact {
    @Attribute(.unique) public var id: UUID
    /// `CNContact.identifier`.
    public var contactIdentifier: String
    public var displayName: String
    /// Which step audience this person belongs to.
    public var audienceRaw: String
    public var addedAt: Date

    public var event: TrackedEvent?

    public init(
        id: UUID = UUID(),
        contactIdentifier: String,
        displayName: String,
        audience: Audience = .leaders,
        addedAt: Date = .now
    ) {
        self.id = id
        self.contactIdentifier = contactIdentifier
        self.displayName = displayName
        self.audienceRaw = audience.rawValue
        self.addedAt = addedAt
    }
}

public extension EventContact {
    var audience: Audience {
        get { Audience(rawValue: audienceRaw) ?? .leaders }
        set { audienceRaw = newValue.rawValue }
    }
}
