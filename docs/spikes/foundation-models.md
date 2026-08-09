# Spike C — Foundation Models

- **Blocker:** PF-4 (Foundation Models availability on target devices)
- **Run:** 2026-08-09, macOS 26.x, Apple silicon, Swift 6.3.3 toolchain
- **Probe source:** `docs/spikes/probes/classify.swift` (copied from the throwaway run)

## Findings

### 1. Availability

```
SystemLanguageModel.default.availability → .available
supportedLanguages → 23
```

`.availability` is an enum with an `.unavailable(reason:)` case. The reasons that matter and
must each have a real error sentence in the app (Sprint 12 task 5):

| Reason | User-facing recovery |
|---|---|
| `deviceNotEligible` | Silent. Heuristics carry the app. Never mention the model. |
| `appleIntelligenceNotEnabled` | "Forerun can write these reminders in your own words if you turn on Apple Intelligence in Settings." Deep link to Settings. |
| `modelNotReady` | Silent, retry next generation. Model is downloading. |

**The app must never block on any of these.** Availability is checked at the provider boundary
only; nothing downstream of `IntelligenceProvider` knows the model exists.

### 2. Guided generation returns a typed enum

`@Generable enum` + `session.respond(to:generating:)` returns a real Swift enum case, not free
text that needs parsing. This is the mechanism Sprint 6 uses — no string matching on model
output for classification. Confirmed working with a six-case enum plus a `Double` field in the
same `@Generable` struct.

### 3. Classification accuracy: 10/10

Ten representative event titles from the target domain (ministry/volunteer, teaching, solo build
work, admin, personal). Instructions were a single system prompt describing each category in one
sentence; the user turn was the bare event title.

```
✓ Sunday Morning Service — Kids Team    → volunteerTeamEvent  conf 0.90  1.51s
✓ Serve Day at the food bank            → volunteerTeamEvent  conf 1.00  0.42s
✓ Preach — Romans 8                     → teachingPrep        conf 1.00  0.43s
✓ Midweek lesson prep                   → teachingPrep        conf 1.00  0.43s
✓ Forerun Sprint 4 — rules engine       → buildWork           conf 0.90  0.40s
✓ Design session: Plan screen           → buildWork           conf 1.00  0.41s
✓ Student Night — Fall Kickoff          → studentFacing       conf 0.90  0.45s
✓ Quarterly sales tax filing due        → adminDeadline       conf 1.00  0.42s
✓ LLC annual report renewal             → adminDeadline       conf 1.00  0.42s
✓ Dentist — cleaning                    → personal            conf 1.00  0.41s

ACCURACY: 10/10 = 100%   avg latency 0.53s   max 1.51s
```

**Caveat, stated plainly:** these are ten titles written to be representative of the developer's
calendar, not ten titles pulled out of it. The accuracy number is real but the sample is
friendly — every title contains a strong keyword. Titles like "Team Meeting", "Prep", or
"Blocked" are the hard cases and are not in this sample. Treat 100% as "the mechanism works,"
not as "classification is solved." The Sprint 6 acceptance bar of ≥80% should be re-measured
against a real calendar export during the TestFlight week.

### 4. Self-reported confidence is not usable as a gate — this changes the Sprint 6 design

The plan calls for a confirmation chip when confidence < 0.7. **The model's self-reported
confidence never went below 0.90 across ten cases, including cases where the title was
genuinely ambiguous.** A 0.7 threshold on this number would fire approximately never, so the
user would never be asked to confirm and every misclassification would be silent.

**Resolution (adopted for Sprint 6):** confidence is computed deterministically in Swift by
cross-checking the two providers, not taken from the model.

```
FM and heuristic agree, heuristic matched a keyword    → 0.95
FM and heuristic agree, heuristic defaulted to unknown → 0.75
FM and heuristic disagree                              → 0.50   ← chip appears
Heuristic only (model unavailable), keyword matched    → 0.80
Heuristic only, no keyword matched                     → 0.30   ← chip appears
```

The model's own confidence is multiplied in as a mild damper but can never on its own push a
disagreement above the gate. This keeps locked decision 1 intact — the model does not decide
whether the user gets asked, Swift does.

### 5. Latency budget

0.4–0.5s per classification on an M-series Mac with a warm session. Prior on-device experience
puts the same call in the low seconds on iPhone.

**Rules adopted:**
- One model call per event for classification, one per step for phrasing. Never in a loop over
  a whole calendar on the main actor.
- Classification runs at track time (user tapped one event), not during a sync sweep.
- Phrasing runs at plan-generation time and the result is persisted to
  `PrepStep.generatedCopy`. The notification path never calls the model — a notification must
  be schedulable with the model cold or absent.
- Sessions are created per call, not held. A long-lived session accumulates transcript and
  eventually exceeds the context window.

### 6. The unavailable path

Proven by construction rather than by disabling Apple Intelligence on this machine:
`ProviderResolver` returns `HeuristicProvider` whenever `isAvailable == false`, and
`HeuristicProvider` has no dependency on FoundationModels at all — it lives in `ForerunCore`,
which cannot import the framework. The Sprint 6 test suite forces the unavailable path with a
stub provider and asserts a complete, correct plan comes out with `templateCopy` on every step.

## Verdict

**PF-4 cleared.** Foundation Models is available and the guided-generation mechanism is the
right one. The heuristic fallback is not a degraded mode — it produces the same ladder at the
same times, with template sentences instead of tailored ones. The one design change forced by
this spike is that confidence is computed in Swift, not read off the model.
