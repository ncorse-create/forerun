# Forerun

Your calendar knows *when* things happen. It has no idea what has to happen *before* them.

Forerun reads the calendar events you choose to track, works backwards from each one, and builds
a **prep ladder** — a small number of specifically-worded reminders at the right lead times.
Three weeks before a volunteer event: *ask your team leads who's in.* A week out: *chase whoever
hasn't answered.* The day before: *message everyone else.*

Leaders and volunteers are always contacted before participants and students. That ordering is
enforced in code, not offered as a preference — telling students about an event before the team
is confirmed is how you end up short-handed in public.

iPhone only, iOS 26+. Everything runs on-device: no account, no sign-up, no server. The only
network code in the project is an optional, off-by-default TickTick source.

## Start here

| If you want to | Read |
|---|---|
| **Design for this app** | [`docs/design-brief.md`](docs/design-brief.md) — screens, visual language, and the open design problems |
| Understand the rules | [`CLAUDE.md`](CLAUDE.md) — 8 locked decisions, 10 engine invariants, design tokens |
| See why things are the way they are | [`docs/decisions/`](docs/decisions) and [`docs/spikes/`](docs/spikes) |
| Ship it | [`docs/store/submission.md`](docs/store/submission.md) |

## Layout

```
Packages/ForerunCore   models, playbooks, the planning engine — pure Foundation, no SwiftData
Forerun/Sources        EventKit + TickTick sources, sync, calendar write-back
Forerun/Intelligence   on-device Foundation Models provider (writes sentences, never dates)
Forerun/Notifications  scheduler, delegate, background refresh
Forerun/Views          Today, Upcoming, Events, Plan, Settings, bulk add, onboarding
Forerun/DesignSystem   palette (light + dark), type ramp, containers, timeline rail
```

The engine lives in a local Swift package with no UI and no SwiftData dependency, so the whole
planning ladder is testable **without a simulator**.

## Build

```bash
xcodegen generate      # the .xcodeproj is gitignored — regenerate on a fresh clone,
                       # and again after adding or moving any file
./scripts/test-core.sh # engine tests on macOS, no simulator
./scripts/build.sh     # compile check, generic iOS destination
```

## The one rule

> If a decision affects **when** something fires or **whether** it fires, it lives in Swift.
> If it affects **what the sentence says**, it can live in the model.

The ladder is deterministic. On-device AI only writes the wording, and if it's unavailable the
app falls back to template copy and loses nothing structural.
