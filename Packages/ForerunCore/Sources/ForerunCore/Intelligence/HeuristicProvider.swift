import Foundation

/// Keyword classification and template copy. No model, no network, no framework.
///
/// This is not a degraded mode — it produces the same ladder at the same times, with the
/// playbook's own sentences instead of tailored ones. It has to be good enough to ship alone,
/// because on a device with no Apple Intelligence it *is* the app.
public struct HeuristicProvider: IntelligenceProvider {

    public init() {}

    public var isAvailable: Bool {
        get async { true }
    }

    /// Ordered most-specific first. A title containing both "team" and "meeting" is a team
    /// event; a title containing both "sermon" and "prep" is teaching. Order settles those.
    static let keywords: [(kind: EventKind, terms: [String])] = [
        (.teachingPrep, ["sermon", "preach", "teach", "teaching", "lesson", "message",
                         "devotional", "homily", "talk", "sunday school", "bible study"]),
        (.volunteerTeamEvent, ["team", "volunteer", "serve", "leaders", "leader", "huddle",
                               "crew", "roster", "setup", "tear down", "greeters", "ushers",
                               "worship", "rehearsal", "practice", "service"]),
        (.studentFacing, ["student", "students", "youth", "kids", "children", "teen", "camp",
                          "retreat", "lock-in", "kickoff", "hangout", "small group"]),
        (.buildWork, ["sprint", "build", "design", "ship", "deep work", "code", "coding",
                      "dev", "writing", "focus", "draft", "prototype", "review session"]),
        (.adminDeadline, ["deadline", "due", "renewal", "renew", "filing", "file", "submit",
                          "submission", "taxes", "tax", "invoice", "report", "registration",
                          "expires", "expiry"]),
        (.personal, ["dentist", "doctor", "appointment", "haircut", "birthday", "anniversary",
                     "vacation", "flight", "dinner", "lunch with", "date night", "checkup"])
    ]

    /// Matches on word boundaries so "service" does not fire on "serviceable" and "due" does not
    /// fire on "Tuesday" — which it would with a naive `contains`, on every Tuesday event.
    static func matches(_ term: String, in tokens: Set<String>, haystack: String) -> Bool {
        if term.contains(" ") { return haystack.contains(term) }
        return tokens.contains(term)
    }

    static func tokens(of text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let separated = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.subtracting(.nonBaseCharacters).contains(scalar)
                ? Character(scalar) : " "
        }
        return Set(String(separated).split(separator: " ").map(String.init))
    }

    /// Returns the kind and whether a keyword actually matched — the caller needs the second
    /// value, because "defaulted to unknown" and "matched a keyword" carry very different
    /// confidence.
    public static func classify(title: String, notes: String? = nil) -> (kind: EventKind, matched: Bool) {
        let haystack = [title, notes ?? ""].joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
        let titleTokens = tokens(of: title)
        let allTokens = titleTokens.union(tokens(of: notes ?? ""))

        // The title is the strong signal. Notes are consulted only if the title says nothing,
        // because a note mentioning "the team" on a dentist appointment should not turn it into
        // a volunteer event.
        for (kind, terms) in keywords {
            if terms.contains(where: { matches($0, in: titleTokens, haystack: haystack) }) {
                return (kind, true)
            }
        }
        for (kind, terms) in keywords {
            if terms.contains(where: { matches($0, in: allTokens, haystack: haystack) }) {
                return (kind, true)
            }
        }
        return (.unknown, false)
    }

    public func classify(_ event: NormalizedEvent) async -> Classification {
        let (kind, matched) = Self.classify(title: event.title, notes: event.notes)
        return ClassificationConfidence.combine(
            model: nil,
            modelSelfReport: nil,
            heuristic: kind,
            heuristicMatchedKeyword: matched
        )
    }

    /// No model, so no generated sentence. The caller uses `templateCopy`, which is always
    /// present and always shippable.
    public func phrase(_ request: PhrasingRequest) async -> String? {
        nil
    }
}

/// Forces the unavailable path for tests and for the "what does this look like with no Apple
/// Intelligence" check.
public struct UnavailableIntelligenceProvider: IntelligenceProvider {
    public init() {}
    public var isAvailable: Bool { get async { false } }
    public func classify(_ event: NormalizedEvent) async -> Classification {
        await HeuristicProvider().classify(event)
    }
    public func phrase(_ request: PhrasingRequest) async -> String? { nil }
}
