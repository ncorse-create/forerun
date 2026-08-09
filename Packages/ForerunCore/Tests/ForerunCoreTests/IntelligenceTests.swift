import Foundation
import Testing
@testable import ForerunCore

private func request(
    title: String = "Sunday Morning Service",
    verb: String = "Send",
    template: String = "Send the ask to your team leads for Sunday Morning Service — who's in, who's out.",
    audience: Audience = .leaders,
    budget: Int = 100
) -> PhrasingRequest {
    PhrasingRequest(
        eventTitle: title,
        actionVerb: verb,
        templateCopy: template,
        audience: audience,
        relativeLabel: "21 days before",
        characterBudget: budget
    )
}

@Suite("Heuristic classification")
struct HeuristicClassificationTests {

    static let cases: [(title: String, expected: EventKind)] = [
        ("Sunday Morning Service — Kids Team", .volunteerTeamEvent),
        ("Serve Day at the food bank", .volunteerTeamEvent),
        ("Worship rehearsal", .volunteerTeamEvent),
        ("Preach — Romans 8", .teachingPrep),
        ("Midweek lesson prep", .teachingPrep),
        ("Sunday school", .teachingPrep),
        ("Forerun sprint — rules engine", .buildWork),
        ("Design session: Plan screen", .buildWork),
        ("Student Night — Fall Kickoff", .studentFacing),
        ("Youth camp", .studentFacing),
        ("Quarterly tax filing due", .adminDeadline),
        ("LLC annual report renewal", .adminDeadline),
        ("Dentist appointment", .personal),
        ("Anniversary dinner", .personal)
    ]

    @Test("Representative titles classify correctly", arguments: cases)
    func representativeTitlesClassify(sample: (title: String, expected: EventKind)) {
        let (kind, matched) = HeuristicProvider.classify(title: sample.title)
        #expect(kind == sample.expected, "\(sample.title) → \(kind.rawValue)")
        #expect(matched)
    }

    @Test("Heuristic accuracy over the sample clears the eighty percent bar")
    func heuristicAccuracyClearsTheBar() {
        let correct = Self.cases.filter { HeuristicProvider.classify(title: $0.title).kind == $0.expected }
        let accuracy = Double(correct.count) / Double(Self.cases.count)
        #expect(accuracy >= 0.8, "accuracy \(accuracy)")
    }

    @Test("A title with no keyword is unknown rather than guessed")
    func unmatchedTitlesAreUnknown() {
        let (kind, matched) = HeuristicProvider.classify(title: "Blocked")
        #expect(kind == .unknown)
        #expect(!matched)
    }

    @Test("Keyword matching is on whole words, so Tuesday is not a deadline")
    func matchingIsOnWordBoundaries() {
        // "due" inside "Tuesday" would make every Tuesday event an admin deadline.
        #expect(HeuristicProvider.classify(title: "Tuesday catch-up").kind != .adminDeadline)
        // "service" inside "serviceable" would make it a team event.
        #expect(HeuristicProvider.classify(title: "Serviceable parts audit").kind != .volunteerTeamEvent)
    }

    @Test("The title outranks the notes")
    func titleBeatsNotes() {
        let (kind, _) = HeuristicProvider.classify(
            title: "Dentist appointment",
            notes: "Ask the team about the volunteer roster"
        )
        #expect(kind == .personal)
    }

    @Test("Notes are consulted only when the title says nothing")
    func notesAreTheFallback() {
        let (kind, matched) = HeuristicProvider.classify(
            title: "Thursday",
            notes: "Volunteer roster and leaders huddle"
        )
        #expect(kind == .volunteerTeamEvent)
        #expect(matched)
    }
}

@Suite("Confidence gate")
struct ConfidenceGateTests {

    @Test("Agreement with a keyword match is confidently above the gate")
    func agreementIsConfident() {
        let result = ClassificationConfidence.combine(
            model: .volunteerTeamEvent, modelSelfReport: 1.0,
            heuristic: .volunteerTeamEvent, heuristicMatchedKeyword: true
        )
        #expect(result.kind == .volunteerTeamEvent)
        #expect(result.confidence >= TrackedEvent.confidenceGate)
    }

    @Test("Disagreement falls below the gate so the user is asked")
    func disagreementAsksTheUser() {
        let result = ClassificationConfidence.combine(
            model: .buildWork, modelSelfReport: 1.0,
            heuristic: .volunteerTeamEvent, heuristicMatchedKeyword: true
        )
        #expect(result.kind == .buildWork)
        #expect(result.confidence < TrackedEvent.confidenceGate)
    }

    @Test("A model claiming total certainty cannot talk its way past a disagreement")
    func selfReportCannotOverrideDisagreement() {
        for report in [0.0, 0.5, 0.9, 1.0] {
            let result = ClassificationConfidence.combine(
                model: .personal, modelSelfReport: report,
                heuristic: .teachingPrep, heuristicMatchedKeyword: true
            )
            #expect(result.confidence < TrackedEvent.confidenceGate)
        }
    }

    @Test("With no model, a keyword match is trusted and a bare guess is not")
    func heuristicOnlyConfidenceSplits() {
        let matched = ClassificationConfidence.combine(
            model: nil, modelSelfReport: nil,
            heuristic: .teachingPrep, heuristicMatchedKeyword: true
        )
        let unmatched = ClassificationConfidence.combine(
            model: nil, modelSelfReport: nil,
            heuristic: .unknown, heuristicMatchedKeyword: false
        )
        #expect(matched.confidence >= TrackedEvent.confidenceGate)
        #expect(unmatched.confidence < TrackedEvent.confidenceGate)
    }

    @Test("The self-report can only ever damp the computed confidence, never raise it")
    func selfReportOnlyDamps() {
        let high = ClassificationConfidence.combine(
            model: .buildWork, modelSelfReport: 1.0,
            heuristic: .buildWork, heuristicMatchedKeyword: true
        )
        let low = ClassificationConfidence.combine(
            model: .buildWork, modelSelfReport: 0.0,
            heuristic: .buildWork, heuristicMatchedKeyword: true
        )
        #expect(low.confidence <= high.confidence)
        #expect(high.confidence <= 0.95)
    }
}

@Suite("Phrasing validator")
struct PhrasingValidatorTests {

    @Test("A good rewrite is accepted")
    func goodRewriteIsAccepted() {
        let validation = PhrasingValidator.validate(
            "Text your team leads and find out who's in for Sunday Morning Service.",
            against: request()
        )
        #expect(validation.isAccepted)
    }

    @Test("An invented name is rejected")
    func inventedNamesAreRejected() {
        let validation = PhrasingValidator.validate(
            "Text Sarah and Mike about the schedule.",
            against: request()
        )
        #expect(validation.rejection == .inventedProperNoun)
    }

    @Test("An invented count is rejected")
    func inventedNumbersAreRejected() {
        let validation = PhrasingValidator.validate(
            "Send your 4 team leads the schedule.",
            against: request()
        )
        #expect(validation.rejection == .inventedNumber)
    }

    @Test("A number the template already contains is allowed through")
    func sourceNumbersAreAllowed() {
        let template = "Head out for Sunday Morning Service. Leave 15 minutes earlier than you think."
        let validation = PhrasingValidator.validate(
            "Leave 15 minutes early and head out for Sunday Morning Service",
            against: request(verb: "Go", template: template, audience: .me)
        )
        #expect(validation.isAccepted, "rejected: \(String(describing: validation.rejection))")
    }

    @Test("An invented time is rejected because it is an invented number")
    func inventedTimesAreRejected() {
        let validation = PhrasingValidator.validate(
            "Send your leads the schedule before 5pm.",
            against: request()
        )
        #expect(validation.rejection == .inventedNumber)
    }

    @Test("Something longer than the budget is rejected")
    func tooLongIsRejected() {
        let long = String(repeating: "send the schedule ", count: 12)
        #expect(PhrasingValidator.validate(long, against: request()).rejection == .tooLong)
    }

    @Test("Two sentences are rejected, because the second one is where facts appear")
    func multipleSentencesAreRejected() {
        let validation = PhrasingValidator.validate(
            "Send the schedule. Everyone has confirmed already.",
            against: request()
        )
        #expect(validation.rejection == .multipleSentences)
    }

    @Test("A sentence with no verb from the step's set is rejected")
    func missingVerbIsRejected() {
        let validation = PhrasingValidator.validate(
            "Your team leads for the run-up",
            against: request()
        )
        #expect(validation.rejection == .noAllowedVerb)
    }

    @Test("A synonym of the step's verb is accepted")
    func verbSynonymsAreAccepted() {
        for candidate in ["Text your leads the plan", "Message your leads the plan",
                          "Email your leads the plan", "Share the plan with your leads"] {
            let validation = PhrasingValidator.validate(candidate, against: request())
            #expect(validation.isAccepted, "\(candidate) → \(String(describing: validation.rejection))")
        }
    }

    @Test("An unsubstituted placeholder is rejected rather than shown to the user")
    func placeholdersAreRejected() {
        #expect(PhrasingValidator.validate("Send the ask for {title}", against: request())
            .rejection == .containsPlaceholder)
    }

    @Test("Empty output is rejected")
    func emptyIsRejected() {
        #expect(PhrasingValidator.validate("   ", against: request()).rejection == .empty)
    }

    @Test("Returning the template unchanged is compliance, not a rejection")
    func templateVerbatimIsAccepted() {
        // The prompt explicitly tells the model to return the template when it cannot improve
        // on it. Several templates are two sentences, and rejecting them was throwing away
        // exactly the behaviour the prompt asked for.
        let twoSentence = "Chase unconfirmed leads for Serve Day. Note the gaps."
        let validation = PhrasingValidator.validate(
            twoSentence,
            against: request(title: "Serve Day", verb: "Confirm", template: twoSentence)
        )
        #expect(validation.accepted == twoSentence)
    }

    @Test("A rewrite may keep the template's sentence count but not exceed it")
    func sentenceCountIsBoundedByTheTemplate() {
        let twoSentence = "Chase unconfirmed leads for Serve Day. Note the gaps."
        let sameShape = PhrasingValidator.validate(
            "Chase the leads who haven't replied about Serve Day. Write down the gaps.",
            against: request(title: "Serve Day", verb: "Confirm", template: twoSentence)
        )
        #expect(sameShape.isAccepted, "rejected: \(String(describing: sameShape.rejection))")

        let threeSentences = PhrasingValidator.validate(
            "Chase the leads. Note the gaps. Everyone has confirmed.",
            against: request(title: "Serve Day", verb: "Confirm", template: twoSentence)
        )
        #expect(threeSentences.rejection == .multipleSentences)

        // A one-sentence template still holds the line at one.
        let oneSentence = PhrasingValidator.validate(
            "Send the plan. Everyone replied already.",
            against: request(template: "Send the plan to your leads.")
        )
        #expect(oneSentence.rejection == .multipleSentences)
    }

    @Test("Audience words are not mistaken for invented names")
    func audienceWordsAreAllowed() {
        for audience in Audience.allCases {
            let validation = PhrasingValidator.validate(
                "Send the schedule to the \(audience.displayName)",
                against: request()
            )
            #expect(validation.isAccepted,
                    "\(audience.displayName) → \(String(describing: validation.rejection))")
        }
    }

    @Test("A real fabrication observed from the model is still caught")
    func observedFabricationIsCaught() {
        // Verbatim output from the on-device model during the Sprint 6 fabrication probe. The
        // event said nothing about a date; the model supplied one.
        let validation = PhrasingValidator.validate(
            "Get ready for Youth Night on 10/19!",
            against: request(
                title: "Youth Night",
                verb: "Send",
                template: "Message students about Youth Night — time, place, what to expect.",
                audience: .participants
            )
        )
        #expect(validation.rejection == .inventedNumber)
    }

    @Test("Words from the event title are allowed even though they are capitalized")
    func titleWordsAreAllowed() {
        let validation = PhrasingValidator.validate(
            "Send your leads the Sunday Morning Service schedule",
            against: request()
        )
        #expect(validation.isAccepted)
    }

    @Test("Weekday and month names are allowed without being in the title")
    func calendarWordsAreAllowed() {
        let validation = PhrasingValidator.validate(
            "Send your leads the plan before Friday",
            against: request(title: "Team huddle", template: "Send the plan to your leads.")
        )
        #expect(validation.isAccepted, "rejected: \(String(describing: validation.rejection))")
    }

    @Test("A longer budget for a message draft allows more than a notification body")
    func messageDraftsGetMoreRoom() {
        let body = "Send your team leads the schedule for Sunday Morning Service and ask them to "
            + "reply with who is in and who is out so the gaps can be covered early"
        let notification = PhrasingValidator.validate(body, against: request())
        let draft = PhrasingValidator.validate(body, against: request(budget: 300))
        #expect(notification.rejection == .tooLong)
        #expect(draft.isAccepted, "rejected: \(String(describing: draft.rejection))")
    }
}

@Suite("The unavailable path")
struct UnavailableProviderTests {

    @Test("With no model at all, classification still works and phrasing returns nothing")
    func unavailableProviderStillClassifies() async {
        let provider = UnavailableIntelligenceProvider()
        #expect(await provider.isAvailable == false)

        let event = NormalizedEvent(
            sourceID: "1", sourceType: .eventkit, title: "Sunday Morning Service — Kids Team",
            startDate: .now, calendarID: "c", calendarName: "Ministry"
        )
        let result = await provider.classify(event)
        #expect(result.kind == .volunteerTeamEvent)
        #expect(await provider.phrase(request()) == nil)
    }

    @Test("A full ladder is produced with template copy and nothing structural is lost")
    func fullLadderSurvivesWithoutAModel() async {
        let provider = UnavailableIntelligenceProvider()
        // A fixed zone and a mid-morning event, so the count is a property of the playbook
        // rather than of whatever hour the test machine happens to be in — a midnight event
        // legitimately loses steps to quiet hours, which is a different test.
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(
            timeZone: zone, year: 2026, month: 5, day: 6, hour: 10
        )) ?? Date(timeIntervalSinceReferenceDate: 800_000_000)

        let event = NormalizedEvent(
            sourceID: "1", sourceType: .eventkit, title: "Sunday Morning Service",
            startDate: start.addingTimeInterval(30 * 86_400),
            calendarID: "c", calendarName: "Ministry"
        )
        let classification = await provider.classify(event)
        let draft = PrepPlanBuilder.build(
            input: PlanInput(title: event.title, startDate: event.startDate, kind: classification.kind),
            settings: EngineSettings(maxStepsPerEvent: 8),
            context: SchedulingContext(now: start, timeZone: zone)
        )
        #expect(draft.steps.count == 8)
        #expect(draft.steps.allSatisfy { !$0.templateCopy.isEmpty })
        #expect(draft.steps.allSatisfy { !$0.templateCopy.contains("{title}") })
        #expect(draft.steps.allSatisfy { $0.templateCopy.contains("Sunday Morning Service")
            || $0.audience == .me || $0.playbookStepID.hasSuffix(".leaders") })
    }

    @Test("A midnight event legitimately loses steps to quiet hours, and still has a ladder")
    func midnightEventStillGetsAPlan() async {
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(
            timeZone: zone, year: 2026, month: 5, day: 6, hour: 0, minute: 30
        )) ?? Date(timeIntervalSinceReferenceDate: 800_000_000)

        let draft = PrepPlanBuilder.build(
            input: PlanInput(title: "Midnight Prayer", startDate: now.addingTimeInterval(30 * 86_400),
                             kind: .volunteerTeamEvent),
            settings: EngineSettings(maxStepsPerEvent: 8),
            context: SchedulingContext(now: now, timeZone: zone)
        )
        #expect(draft.steps.count >= 5)
        let settings = EngineSettings.default
        for step in draft.steps {
            #expect(!PrepPlanBuilder.isInQuietHours(step.fireDate, settings: settings, calendar: calendar))
        }
    }
}
