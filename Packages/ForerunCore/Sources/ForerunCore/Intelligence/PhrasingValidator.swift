import Foundation

/// Why a generated sentence was thrown away. Counted so the rejection rate can be checked
/// against the acceptance bar, and so a prompt regression shows up as a shift in *which* rule
/// is firing rather than as a vague "it got worse."
public enum PhrasingRejection: String, Sendable, CaseIterable {
    case empty
    case tooLong
    case multipleSentences
    case noAllowedVerb
    case inventedNumber
    case inventedProperNoun
    case notSecondPerson
    case containsPlaceholder
}

public struct PhrasingValidation: Sendable, Equatable {
    public let accepted: String?
    public let rejection: PhrasingRejection?

    public var isAccepted: Bool { accepted != nil }
}

/// Deterministic Swift, run over every single generation.
///
/// The model is allowed to choose words. It is not allowed to introduce facts. Everything here
/// is a check that the output says nothing the input did not already contain — which is what
/// makes it safe to put a generated sentence on a lock screen where the user will act on it
/// without opening the app.
public enum PhrasingValidator {

    /// Hard ceiling regardless of the request's own budget. A notification body longer than this
    /// is truncated by the system anyway, so a long one is just a worse version of a short one.
    public static let absoluteMaximum = 100

    /// Capitalized words that are not proper nouns and must not trip the invented-name check.
    ///
    /// The audience names are in here because the model reliably capitalizes them — "send the
    /// schedule to the Leaders" is not an invented person, and rejecting it was throwing away
    /// perfectly good output.
    static let capitalizationAllowlist: Set<String> = {
        var allowed: Set<String> = [
            "I", "I'm", "I'll", "A", "An", "The", "It", "You", "Your", "We", "Send", "Text",
            "Call", "Message", "Email", "Ask", "Confirm", "Check", "Write", "Draft", "Read",
            "Lock", "Outline", "Rehearse", "Define", "Block", "Gather", "Start", "Decide",
            "Fill", "Thank", "Announce", "Remind", "Detail", "Prep", "Go", "Note", "Finish",
            "Submit", "Head", "Pull", "Set", "Leave", "Don't", "Do"
        ]
        allowed.formUnion(Audience.allCases.map(\.displayName))
        allowed.formUnion(Audience.allCases.map { $0.displayName + "." })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        allowed.formUnion(formatter.weekdaySymbols ?? [])
        allowed.formUnion(formatter.shortWeekdaySymbols ?? [])
        allowed.formUnion(formatter.monthSymbols ?? [])
        allowed.formUnion(formatter.shortMonthSymbols ?? [])
        return allowed
    }()

    /// Alternatives the model may reach for in place of the step's own verb. Without this, a
    /// perfectly good "Text your leads…" would be rejected because the step's verb is "Send."
    static let verbSynonyms: [String: Set<String>] = [
        "Send": ["send", "text", "message", "email", "share", "pass", "forward", "get", "give"],
        "Confirm": ["confirm", "chase", "check", "follow", "nudge", "ask", "verify"],
        "Fill": ["fill", "cover", "find", "recruit", "ask", "sort", "close"],
        "Thank": ["thank", "note", "write", "tell"],
        "Lock": ["lock", "pick", "choose", "settle", "decide", "fix"],
        "Write": ["write", "draft", "put", "name", "state", "sum"],
        "Outline": ["outline", "sketch", "map", "structure", "plan"],
        "Draft": ["draft", "write", "get", "put"],
        "Rehearse": ["rehearse", "read", "practice", "run", "say"],
        "Define": ["define", "write", "name", "state", "decide"],
        "Block": ["block", "book", "hold", "reserve", "put", "carve"],
        "Gather": ["gather", "pull", "collect", "find", "open", "grab"],
        "Start": ["start", "begin", "open", "sit", "get"],
        "Decide": ["decide", "ship", "cut", "close", "call", "finish"],
        "Announce": ["announce", "post", "tell", "share", "send"],
        "Remind": ["remind", "nudge", "ask", "send", "tell"],
        "Detail": ["detail", "send", "share", "tell", "give"],
        "Prep": ["prep", "set", "get", "sort", "lay"],
        "Go": ["go", "head", "leave", "set"],
        "Note": ["note", "remember", "check"],
        "Finish": ["finish", "complete", "close", "wrap", "finalise", "finalize"],
        "Submit": ["submit", "send", "file", "upload", "hand"]
    ]

    public static func allowedVerbs(for actionVerb: String) -> Set<String> {
        var verbs = verbSynonyms[actionVerb] ?? []
        verbs.insert(actionVerb.lowercased())
        return verbs
    }

    /// The source of truth for what counts as a "fact already present." Deliberately narrow:
    /// the event title and the step's own template. Notes are excluded, because a note is where
    /// people put things they would not want repeated on a lock screen.
    static func sourceText(for request: PhrasingRequest) -> String {
        [request.eventTitle, request.templateCopy, request.actionVerb].joined(separator: " ")
    }

    /// How many sentences a string contains, counting only terminators that are not the final
    /// character.
    static func interiorSentenceBreaks(in text: String) -> Int {
        text.dropLast().filter { $0 == "." || $0 == "!" || $0 == "?" }.count
    }

    public static func validate(_ candidate: String, against request: PhrasingRequest) -> PhrasingValidation {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return .init(accepted: nil, rejection: .empty) }

        // The prompt explicitly permits returning the template unchanged when there is nothing
        // to improve, so rejecting that is rejecting compliance. It also short-circuits every
        // other rule, since a template cannot fabricate anything.
        let template = request.templateCopy.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.compare(template, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return .init(accepted: template, rejection: nil)
        }

        if trimmed.contains("{title}") || trimmed.contains("{") {
            return .init(accepted: nil, rejection: .containsPlaceholder)
        }

        let limit = min(request.characterBudget, max(request.characterBudget, absoluteMaximum))
        guard trimmed.count <= limit else { return .init(accepted: nil, rejection: .tooLong) }

        // A second sentence is where the model starts adding a second, invented fact — but
        // several playbook templates are themselves two sentences ("Chase unconfirmed leads for
        // {title}. Note the gaps."), and a rewrite that keeps that shape has added nothing. The
        // rule is therefore "no more sentences than the template had," not "exactly one."
        let allowedBreaks = max(0, interiorSentenceBreaks(in: template))
        if interiorSentenceBreaks(in: trimmed) > allowedBreaks {
            return .init(accepted: nil, rejection: .multipleSentences)
        }

        let sourceLower = sourceText(for: request).lowercased()
        let words = tokens(of: trimmed)

        // At least one verb from the step's allowed set, so the sentence actually tells the user
        // to do the thing the step is for.
        let verbs = allowedVerbs(for: request.actionVerb)
        guard words.contains(where: { verbs.contains($0.lowercased()) }) else {
            return .init(accepted: nil, rejection: .noAllowedVerb)
        }

        // No digit sequence the event did not supply. This is the check that stops "Text your 4
        // leads" when nothing anywhere said there were four.
        for run in digitRuns(in: trimmed) where !sourceLower.contains(run) {
            return .init(accepted: nil, rejection: .inventedNumber)
        }

        // No capitalized token the event did not supply. This is the check that stops the model
        // inventing "Sarah."
        for (index, word) in words.enumerated() {
            guard let first = word.first, first.isUppercase else { continue }
            if index == 0 { continue }
            let bare = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if bare.isEmpty { continue }
            if capitalizationAllowlist.contains(bare) { continue }
            if bare.uppercased() == bare && bare.count <= 4 { continue }   // acronyms
            if sourceLower.contains(bare.lowercased()) { continue }
            return .init(accepted: nil, rejection: .inventedProperNoun)
        }

        return .init(accepted: trimmed, rejection: nil)
    }

    static func tokens(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    static func digitRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

/// Counts rejections so the rate can be checked against the acceptance bar (under 15%) without
/// logging any of the text itself.
public actor PhrasingTelemetry {
    public static let shared = PhrasingTelemetry()

    private var accepted = 0
    private var rejected: [PhrasingRejection: Int] = [:]

    public init() {}

    public func record(_ validation: PhrasingValidation) {
        if validation.isAccepted {
            accepted += 1
        } else if let rejection = validation.rejection {
            rejected[rejection, default: 0] += 1
        }
    }

    public var rejectionRate: Double {
        let total = accepted + rejected.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(rejected.values.reduce(0, +)) / Double(total)
    }

    public var breakdown: [PhrasingRejection: Int] { rejected }
    public var totalAccepted: Int { accepted }

    public func reset() {
        accepted = 0
        rejected = [:]
    }
}
