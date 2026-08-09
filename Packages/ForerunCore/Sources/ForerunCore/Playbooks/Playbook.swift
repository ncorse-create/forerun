import Foundation

/// One rung of a playbook, before it knows anything about a date.
public struct PlaybookStep: Sendable, Equatable, Hashable, Identifiable {
    /// Stable across app versions. Regeneration matches user edits on this, and the skip-rate
    /// diagnostic aggregates on it, so **renaming one discards its history**. Treat these as
    /// permanent.
    public let id: String
    /// Negative is before the event. Positive is a follow-up.
    public let offset: TimeInterval
    public let audience: Audience
    public let verb: String
    /// `{title}` is the only substitution. Deliberately — a template that can reference more
    /// than the title starts inventing facts, which is exactly what the validator exists to stop.
    public let template: String
    /// Survives the per-event cap.
    public let isCore: Bool

    public init(
        id: String,
        offset: TimeInterval,
        audience: Audience,
        verb: String,
        template: String,
        isCore: Bool
    ) {
        self.id = id
        self.offset = offset
        self.audience = audience
        self.verb = verb
        self.template = template
        self.isCore = isCore
    }

    public func copy(for title: String) -> String {
        template.replacingOccurrences(of: "{title}", with: title)
    }
}

public struct Playbook: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: EventKind
    public let steps: [PlaybookStep]
    /// Shown once on the Plan screen. Honest about which lead times are research-backed and
    /// which are practitioner convention — the app never calls the second kind "proven."
    public let provenance: String

    public init(id: String, kind: EventKind, steps: [PlaybookStep], provenance: String) {
        self.id = id
        self.kind = kind
        self.steps = steps
        self.provenance = provenance
    }

    /// One line describing the shape of the ladder, for the kind picker: "5 steps, from 10 days
    /// out." Generated rather than written so it cannot drift from the table above it.
    public var stepSummary: String {
        guard !steps.isEmpty else { return "No run-up" }
        let count = steps.count
        let lead = maximumLeadTime
        let plural = count == 1 ? "step" : "steps"
        guard lead > 0 else { return "\(count) \(plural)" }
        let days = Int((lead / 86_400).rounded())
        if days >= 1 {
            return "\(count) \(plural), from \(days) day\(days == 1 ? "" : "s") out"
        }
        let hours = Int((lead / 3_600).rounded())
        return "\(count) \(plural), from \(hours) hour\(hours == 1 ? "" : "s") out"
    }

    /// The earliest lead time this playbook wants, as a positive interval.
    public var maximumLeadTime: TimeInterval {
        let leads = steps.map(\.offset).filter { $0 < 0 }.map(abs)
        return leads.max() ?? 0
    }
}

/// Days and hours as intervals, so the playbook tables read the way the plan document does.
private func days(_ count: Double) -> TimeInterval { count * 86_400 }
private func hours(_ count: Double) -> TimeInterval { count * 3_600 }

public enum PlaybookLibrary {
    public static func playbook(for kind: EventKind) -> Playbook {
        switch kind {
        case .volunteerTeamEvent: volunteerTeamEvent
        case .teachingPrep: teachingPrep
        case .buildWork: buildWork
        case .studentFacing: studentFacing
        case .adminDeadline: adminDeadline
        case .personal: personal
        case .unknown: unknownPlaceholder
        }
    }

    public static var all: [Playbook] {
        EventKind.selectable.map(playbook(for:))
    }

    /// Sunday service, youth night, serve day — anything with a team behind it.
    public static let volunteerTeamEvent = Playbook(
        id: "volunteerTeamEvent",
        kind: .volunteerTeamEvent,
        steps: [
            PlaybookStep(id: "volunteerTeamEvent.d-21.leaders", offset: -days(21), audience: .leaders, verb: "Send",
                         template: "Send the ask to your team leads for {title} — who's in, who's out.", isCore: true),
            PlaybookStep(id: "volunteerTeamEvent.d-14.leaders", offset: -days(14), audience: .leaders, verb: "Send",
                         template: "Send leads the schedule and role expectations for {title}.", isCore: true),
            PlaybookStep(id: "volunteerTeamEvent.d-7.leaders", offset: -days(7), audience: .leaders, verb: "Confirm",
                         template: "Chase unconfirmed leads for {title}. Note the gaps.", isCore: true),
            PlaybookStep(id: "volunteerTeamEvent.d-3.leaders", offset: -days(3), audience: .leaders, verb: "Fill",
                         template: "Fill or cover the open roles for {title}.", isCore: false),
            PlaybookStep(id: "volunteerTeamEvent.h-48.leaders", offset: -hours(48), audience: .leaders, verb: "Send",
                         template: "Send final details to your leads: arrival time, location, what to bring.", isCore: true),
            PlaybookStep(id: "volunteerTeamEvent.h-24.participants", offset: -hours(24), audience: .participants, verb: "Send",
                         template: "Message students about {title} — time, place, what to expect.", isCore: true),
            PlaybookStep(id: "volunteerTeamEvent.h-2.self", offset: -hours(2), audience: .me, verb: "Prep",
                         template: "Head out for {title}. Leave 15 minutes earlier than you think.", isCore: false),
            PlaybookStep(id: "volunteerTeamEvent.d1.leaders", offset: days(1), audience: .leaders, verb: "Thank",
                         template: "Thank your leads and note one thing to change next time.", isCore: false)
        ],
        provenance: "The 2–3 week window for a scheduling ask, 48–72 hours for confirmation and "
            + "same-week for details is recommended practice among people who run volunteer "
            + "teams — not a research finding. The ladder itself is spaced deliberately, which "
            + "is well supported."
    )

    /// Sermon, lesson, talk.
    public static let teachingPrep = Playbook(
        id: "teachingPrep",
        kind: .teachingPrep,
        steps: [
            PlaybookStep(id: "teachingPrep.d-10.self", offset: -days(10), audience: .me, verb: "Lock",
                         template: "Lock the text for {title}.", isCore: true),
            PlaybookStep(id: "teachingPrep.d-7.self", offset: -days(7), audience: .me, verb: "Write",
                         template: "Write the main idea for {title} in one sentence.", isCore: true),
            PlaybookStep(id: "teachingPrep.d-4.self", offset: -days(4), audience: .me, verb: "Outline",
                         template: "Outline {title} — three moves, one landing.", isCore: true),
            PlaybookStep(id: "teachingPrep.d-2.self", offset: -days(2), audience: .me, verb: "Draft",
                         template: "Full draft of {title} down on paper.", isCore: true),
            PlaybookStep(id: "teachingPrep.d-1.self", offset: -days(1), audience: .me, verb: "Rehearse",
                         template: "Read {title} out loud once, start to finish.", isCore: true)
        ],
        provenance: "Spacing the work across several days rather than massing it the night "
            + "before is well supported by research on distributed practice."
    )

    /// App sprint, design session, deep work block.
    public static let buildWork = Playbook(
        id: "buildWork",
        kind: .buildWork,
        steps: [
            PlaybookStep(id: "buildWork.d-7.self", offset: -days(7), audience: .me, verb: "Define",
                         template: "Write what \"done\" means for {title} in one sentence.", isCore: true),
            PlaybookStep(id: "buildWork.d-3.self", offset: -days(3), audience: .me, verb: "Block",
                         template: "Block the working hours for {title} on your calendar.", isCore: true),
            PlaybookStep(id: "buildWork.d-1.self", offset: -days(1), audience: .me, verb: "Gather",
                         template: "Pull the files, links, and assets {title} needs.", isCore: true),
            PlaybookStep(id: "buildWork.h-1.self", offset: -hours(1), audience: .me, verb: "Start",
                         template: "Start {title}. Phone face down.", isCore: true),
            PlaybookStep(id: "buildWork.d1.self", offset: days(1), audience: .me, verb: "Decide",
                         template: "Ship it or cut it. Don't leave {title} half-open.", isCore: true)
        ],
        provenance: "Naming what \"done\" means before you start, and deciding afterwards rather "
            + "than drifting, both come from practice rather than a study."
    )

    /// Students or participants are the audience and there is no team layer.
    public static let studentFacing = Playbook(
        id: "studentFacing",
        kind: .studentFacing,
        steps: [
            PlaybookStep(id: "studentFacing.d-10.participants", offset: -days(10), audience: .participants, verb: "Announce",
                         template: "Announce {title} — date, time, and why it's worth coming to.", isCore: true),
            PlaybookStep(id: "studentFacing.d-5.participants", offset: -days(5), audience: .participants, verb: "Remind",
                         template: "Remind everyone about {title} and ask who's bringing a friend.", isCore: true),
            PlaybookStep(id: "studentFacing.d-2.participants", offset: -days(2), audience: .participants, verb: "Detail",
                         template: "Send the details for {title}: where to meet, what to bring, when it ends.", isCore: true),
            PlaybookStep(id: "studentFacing.d-1.self", offset: -days(1), audience: .me, verb: "Prep",
                         template: "Set up whatever {title} needs — space, supplies, playlist.", isCore: true),
            PlaybookStep(id: "studentFacing.h-2.self", offset: -hours(2), audience: .me, verb: "Go",
                         template: "Head out for {title}. Leave 15 minutes earlier than you think.", isCore: false)
        ],
        provenance: "Three spaced touches beat one big announcement — that part is well "
            + "supported. The specific 10/5/2-day spacing is a starting point, not a finding."
    )

    /// Submission, renewal, filing.
    public static let adminDeadline = Playbook(
        id: "adminDeadline",
        kind: .adminDeadline,
        steps: [
            PlaybookStep(id: "adminDeadline.d-7.self", offset: -days(7), audience: .me, verb: "Start",
                         template: "Open {title} and find out what it actually needs.", isCore: true),
            PlaybookStep(id: "adminDeadline.d-2.self", offset: -days(2), audience: .me, verb: "Draft",
                         template: "Get {title} to a rough draft — gaps are fine.", isCore: true),
            PlaybookStep(id: "adminDeadline.d-1.self", offset: -days(1), audience: .me, verb: "Finish",
                         template: "Finish {title} and read it once more.", isCore: true),
            PlaybookStep(id: "adminDeadline.h-4.self", offset: -hours(4), audience: .me, verb: "Submit",
                         template: "Submit {title}.", isCore: true)
        ],
        provenance: "Starting earlier than feels necessary is the well-supported part — people "
            + "systematically underestimate how long this kind of task takes."
    )

    /// Appointments, family, anything with no prep surface. One step. Do not build a ladder for
    /// a dentist appointment.
    public static let personal = Playbook(
        id: "personal",
        kind: .personal,
        steps: [
            PlaybookStep(id: "personal.d-1.self", offset: -days(1), audience: .me, verb: "Note",
                         template: "{title} is tomorrow.", isCore: true)
        ],
        provenance: "One reminder. There is nothing to prepare."
    )

    /// An unclassified event gets no ladder at all until the user says what it is. Guessing here
    /// would put a 21-day volunteer ladder on a dentist appointment.
    public static let unknownPlaceholder = Playbook(
        id: "unknown",
        kind: .unknown,
        steps: [],
        provenance: "Forerun doesn't know what this is yet."
    )
}
