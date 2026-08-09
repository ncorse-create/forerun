import ForerunCore
import Foundation
import FoundationModels

/// The classification result, as a typed enum rather than free text.
///
/// `@Generable` on an enum means guided generation hands back a real Swift case — there is no
/// string matching on model output anywhere in this app, so a creative spelling cannot become a
/// silently wrong playbook.
@Generable
enum GeneratedEventKind: String, CaseIterable, Sendable {
    case volunteerTeamEvent
    case teachingPrep
    case buildWork
    case studentFacing
    case adminDeadline
    case personal

    var eventKind: EventKind {
        EventKind(rawValue: rawValue) ?? .unknown
    }
}

@Generable
struct GeneratedClassification: Sendable {
    @Guide(description: "The single best category for this calendar event.")
    var kind: GeneratedEventKind
    @Guide(description: "How certain you are, from 0.0 to 1.0.")
    var confidence: Double
}

/// Apple's on-device model. One conformance of `IntelligenceProvider` among several — the engine
/// cannot tell which one is in use, and nothing here can change a fire date.
///
/// Everything runs on device. There is no network call in this file and no way to add one
/// without it being obvious.
struct FoundationModelsProvider: IntelligenceProvider {

    var isAvailable: Bool {
        get async {
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        }
    }

    /// Why the model is not available, when it is not. Only `appleIntelligenceNotEnabled` is
    /// worth a sentence to the user — the other reasons are not actionable and mentioning them
    /// would just advertise a feature they cannot have.
    static var unavailabilityMessage: String? {
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else {
            return nil
        }
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Forerun can write these reminders in your own words if you turn on Apple "
                + "Intelligence in Settings. Everything else works either way."
        case .deviceNotEligible, .modelNotReady:
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: Classification

    private static let classificationInstructions = """
    You classify calendar events for a prep-planning app. Given one event, choose exactly one \
    category. Use only the words in the event; never invent details.

    volunteerTeamEvent — an event run by a team of volunteers or leaders who must be scheduled \
    and confirmed ahead of time.
    teachingPrep — the user must prepare and deliver a talk, sermon, lesson, or message.
    buildWork — focused solo making: writing software, design, a sprint, a deep-work block.
    studentFacing — students or participants are the audience and there is no volunteer team \
    layer.
    adminDeadline — a submission, renewal, filing, or paperwork deadline.
    personal — appointments and family time with no meaningful prep surface.
    """

    func classify(_ event: NormalizedEvent) async -> Classification {
        let (heuristicKind, matched) = HeuristicProvider.classify(title: event.title, notes: event.notes)

        guard await isAvailable else {
            return ClassificationConfidence.combine(
                model: nil, modelSelfReport: nil,
                heuristic: heuristicKind, heuristicMatchedKeyword: matched
            )
        }

        // A fresh session per call. A long-lived one accumulates transcript and eventually
        // exceeds the context window, and there is nothing here worth carrying between events.
        let session = LanguageModelSession(instructions: Self.classificationInstructions)
        do {
            let response = try await session.respond(
                to: "Event title: \(event.title)",
                generating: GeneratedClassification.self
            )
            return ClassificationConfidence.combine(
                model: response.content.kind.eventKind,
                modelSelfReport: response.content.confidence,
                heuristic: heuristicKind,
                heuristicMatchedKeyword: matched
            )
        } catch {
            return ClassificationConfidence.combine(
                model: nil, modelSelfReport: nil,
                heuristic: heuristicKind, heuristicMatchedKeyword: matched
            )
        }
    }

    // MARK: Phrasing

    /// Every constraint here exists because of a specific failure. Second person and imperative
    /// because a reminder that describes rather than instructs gets ignored. One sentence
    /// because two is where a second, invented fact appears. A named action and a named
    /// recipient because implementation-intention research is the strongest evidence in the
    /// whole playbook library — "text your four team leads the Sunday schedule" outperforms
    /// "don't forget about the team," and that difference is the single highest-value constraint
    /// on this prompt.
    private static func phrasingInstructions(budget: Int) -> String {
        """
        You rewrite a prep reminder so it sounds like the user wrote it themselves.

        Rules, all mandatory:
        - Second person, imperative mood. Tell them to do it.
        - Exactly one sentence, under \(budget) characters.
        - Name a concrete action and, when the step is aimed at other people, a concrete \
        recipient.
        - Use ONLY facts that appear in the supplied event and template. Do not invent names, \
        times, locations, counts, or any number that is not already there.
        - Do not add a greeting, a sign-off, an emoji, or a second sentence.
        - If you cannot improve on the template, return the template unchanged.
        """
    }

    func phrase(_ request: PhrasingRequest) async -> String? {
        guard await isAvailable else { return nil }

        let prompt = """
        Event: \(request.eventTitle)
        This step is aimed at: \(request.audience.displayName)
        It fires \(request.relativeLabel) the event.
        Template to improve: \(request.templateCopy)
        """

        let session = LanguageModelSession(
            instructions: Self.phrasingInstructions(budget: request.characterBudget)
        )
        do {
            let response = try await session.respond(to: prompt)
            let validation = PhrasingValidator.validate(response.content, against: request)
            await PhrasingTelemetry.shared.record(validation)
            // On any rejection the caller silently falls back to `templateCopy`. The user never
            // sees a validation failure, because a template sentence is a perfectly good
            // sentence — it is just not tailored.
            return validation.accepted
        } catch {
            return nil
        }
    }
}

/// Picks the provider. One line to swap.
enum ProviderResolver {
    static func make() async -> any IntelligenceProvider {
        let foundationModels = FoundationModelsProvider()
        if await foundationModels.isAvailable {
            return foundationModels
        }
        return HeuristicProvider()
    }
}
