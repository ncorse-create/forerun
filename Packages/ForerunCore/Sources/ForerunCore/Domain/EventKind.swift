import Foundation

/// What kind of run-up an event needs. This is the only thing the classifier decides, and it
/// selects a playbook — it never decides timing, count, or ordering.
public enum EventKind: String, Codable, CaseIterable, Sendable {
    /// Sunday service, youth night, serve day — anything with a team behind it.
    case volunteerTeamEvent
    /// Sermon, lesson, talk.
    case teachingPrep
    /// App sprint, design session, deep work block.
    case buildWork
    /// Students or participants are the audience and there is no team layer.
    case studentFacing
    /// Submission, renewal, filing.
    case adminDeadline
    /// Appointments, family, anything with no prep surface.
    case personal
    /// Not classified. Gets no plan until the user says what it is.
    case unknown

    public var displayName: String {
        switch self {
        case .volunteerTeamEvent: "Team event"
        case .teachingPrep: "Teaching"
        case .buildWork: "Deep work"
        case .studentFacing: "Student event"
        case .adminDeadline: "Deadline"
        case .personal: "Personal"
        case .unknown: "Unsorted"
        }
    }

    /// The sentence shown on the confirmation chip when confidence is below the gate.
    public var confirmationPrompt: String {
        switch self {
        case .volunteerTeamEvent: "Looks like a team event — right?"
        case .teachingPrep: "Looks like something you're teaching — right?"
        case .buildWork: "Looks like deep work — right?"
        case .studentFacing: "Looks like a student event — right?"
        case .adminDeadline: "Looks like a deadline — right?"
        case .personal: "Looks personal — right?"
        case .unknown: "What kind of event is this?"
        }
    }

    /// Kinds a user can pick from. `unknown` is a state, not a choice.
    public static var selectable: [EventKind] {
        allCases.filter { $0 != .unknown }
    }
}
