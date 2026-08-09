import Foundation

public struct Classification: Sendable, Equatable {
    public var kind: EventKind
    /// Computed in Swift, never taken from a model. See `ClassificationConfidence`.
    public var confidence: Double
    /// The model's own self-report, kept for diagnostics only. It is poorly calibrated — Spike C
    /// measured it never dropping below 0.90, including on genuinely ambiguous titles — so it
    /// can damp the computed confidence but can never raise it past the gate on its own.
    public var modelSelfReport: Double?

    public init(kind: EventKind, confidence: Double, modelSelfReport: Double? = nil) {
        self.kind = kind
        self.confidence = confidence
        self.modelSelfReport = modelSelfReport
    }
}

/// The seam between the app and whatever writes its sentences.
///
/// Foundation Models is one conformance. A server-backed one could be swapped in later without
/// the engine noticing, because nothing downstream of this protocol can affect *when* or
/// *whether* a step fires — only what its sentence says.
public protocol IntelligenceProvider: Sendable {
    var isAvailable: Bool { get async }
    func classify(_ event: NormalizedEvent) async -> Classification
    /// Returns nil whenever the model is unavailable or its output failed validation. The caller
    /// falls back to `templateCopy` and loses nothing structural.
    func phrase(_ request: PhrasingRequest) async -> String?
}

/// Everything the phraser is allowed to know. Deliberately narrow: the model can only see the
/// event title, the step's own verb and template, and who the step is for. It never sees notes,
/// contact names, scratchpad material, or any other event.
public struct PhrasingRequest: Sendable, Equatable {
    public var eventTitle: String
    public var actionVerb: String
    public var templateCopy: String
    public var audience: Audience
    public var relativeLabel: String
    /// Notification bodies stay short; a message draft gets more room.
    public var characterBudget: Int

    public init(
        eventTitle: String,
        actionVerb: String,
        templateCopy: String,
        audience: Audience,
        relativeLabel: String,
        characterBudget: Int = 100
    ) {
        self.eventTitle = eventTitle
        self.actionVerb = actionVerb
        self.templateCopy = templateCopy
        self.audience = audience
        self.relativeLabel = relativeLabel
        self.characterBudget = characterBudget
    }
}

/// Confidence is computed here, in Swift, by cross-checking the two providers — not read off the
/// model.
///
/// Spike C found the model's self-reported confidence never dropped below 0.90 across ten cases,
/// including ambiguous ones, so a 0.7 gate on that number would fire approximately never and
/// every misclassification would be silent. Agreement between an LLM and a keyword matcher is a
/// far better signal than either one's opinion of itself, and it keeps locked decision 1 intact:
/// Swift decides whether the user gets asked.
public enum ClassificationConfidence {
    public static func combine(
        model: EventKind?,
        modelSelfReport: Double?,
        heuristic: EventKind,
        heuristicMatchedKeyword: Bool
    ) -> Classification {
        guard let model, model != .unknown else {
            // Model unavailable or abstaining. The heuristic carries it.
            let confidence = heuristicMatchedKeyword ? 0.80 : 0.30
            return Classification(kind: heuristic, confidence: confidence,
                                  modelSelfReport: modelSelfReport)
        }

        if model == heuristic {
            let base = heuristicMatchedKeyword ? 0.95 : 0.75
            // The self-report only ever damps. A confident model cannot talk its way past a gate.
            let damped = base * min(1.0, max(0.8, modelSelfReport ?? 1.0))
            return Classification(kind: model, confidence: damped, modelSelfReport: modelSelfReport)
        }

        // Disagreement. Take the model's answer — it is the better classifier — but drop below
        // the gate so the user is asked to confirm.
        return Classification(kind: model, confidence: 0.50, modelSelfReport: modelSelfReport)
    }
}
