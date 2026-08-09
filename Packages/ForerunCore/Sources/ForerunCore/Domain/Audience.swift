import Foundation

/// Who a prep step is aimed at.
///
/// `sortPriority` is the engine's ordering key and encodes locked decision 2: leaders and
/// volunteers are contacted before participants and students. Students and participants share
/// priority `2` deliberately — they are the same audience for ordering purposes and differ only
/// in what the copy calls them.
public enum Audience: String, Codable, CaseIterable, Sendable {
    case leaders
    case volunteers
    case participants
    case students
    /// The user themselves. Spelled `me` in Swift because `Audience.self` would collide with
    /// the metatype; the persisted raw value is still `"self"`.
    case me = "self"

    public var sortPriority: Int {
        switch self {
        case .leaders: 0
        case .volunteers: 1
        case .participants, .students: 2
        case .me: 3
        }
    }

    /// True for the audiences that locked decision 2 protects — these must fire first.
    public var isLeadership: Bool {
        self == .leaders || self == .volunteers
    }

    /// True for the audiences that get dropped first when compression would break the ordering.
    public var isAudienceSide: Bool {
        self == .participants || self == .students
    }

    public var displayName: String {
        switch self {
        case .leaders: "Leaders"
        case .volunteers: "Volunteers"
        case .participants: "Participants"
        case .students: "Students"
        case .me: "You"
        }
    }

    /// Design-system colour token. Leaders amber, the audience side clay, yourself graphite.
    public var colorToken: String {
        switch self {
        case .leaders, .volunteers: "amber"
        case .participants, .students: "clay"
        case .me: "graphite"
        }
    }

    /// Steps aimed at other people can hand off to a message composer. Steps aimed at yourself
    /// cannot, and must not grow a Message button.
    public var isContactable: Bool {
        self != .me
    }
}
