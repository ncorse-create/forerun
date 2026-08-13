# Forerun — mobile app design brief

## What it is

Your calendar knows *when* things happen. It has no idea what has to happen *before* them.

Forerun reads the calendar events you choose to track, works backwards from each one, and
builds a **prep ladder** — a small set of specifically-worded reminders at the right lead times.
Three weeks before a volunteer event: *ask your team leads who's in.* A week out: *chase whoever
hasn't answered.* Two days out: *send arrival times.* The day before: *message everyone else.*

It is not a to-do list, a habit tracker, or a productivity dashboard. It answers one question —
**"what do I owe people this week, and by when?"** — and then gets out of the way.

iPhone only. Everything runs on-device; there is no account, no sign-up, and no server.

## Who it's for

Someone who runs things involving other people — volunteer teams, student groups, a class they
teach, a talk they're giving. The failure mode this app exists to prevent is *telling the
participants about an event before you've confirmed the team*, and then being short-handed in
public.

## Product rules that constrain the design

These are settled and should shape the visual language rather than be designed around:

1. **No streaks, no badges, no completion percentages, no points.** A step is pending, done,
   snoozed, or skipped. Skipping costs nothing and must never look like failure.
2. **Never a red count badge on the app icon.** Ever.
3. **Hard cap: 5 reminders per event, 6 per day across everything.** Over-notification is what
   kills this category. The UI should make the caps feel like a promise, not a limitation.
4. **Not an inbox.** There is no "clear the list" ritual and no zero state to achieve. When
   there's nothing due, the app says so plainly.
5. **Leaders before participants, always.** Enforced in code. The UI should make this ordering
   legible — it is the app's core opinion.
6. **The ladder is deterministic.** On-device AI writes the *sentence*; it never decides when
   something fires. Nothing should be labeled "AI" in the interface.
7. **Empty states are one sentence, not an illustration.**

## The event kinds (playbooks)

Each tracked event is classified into one of six kinds. The kind picks the playbook, which
determines the offsets, the step count, and who each step is about.

| Kind | Shown as | Ladder |
|---|---|---|
| Volunteer team event | **Team event** | −21d, −14d, −7d, −3d to leaders; +1d follow-up |
| Teaching prep | **Teaching** | −10d, −7d, −4d, −2d, −1d, all self-directed |
| Deep work | **Deep work** | −7d, −3d, −1d self; +1d; the −3d step can create a calendar block |
| Student-facing | **Student event** | −10d, −5d, −2d to participants; −1d self |
| Admin deadline | **Deadline** | −7d, −2d, −1d self |
| Personal | **Personal** | −1d only |

A seventh state, **Unsorted**, appears when the app isn't confident. It shows a confirmation
chip on the plan: *"Looks like a team event — right?"*

**Audience colors carry meaning:** leaders/volunteers = amber, participants/students = clay,
self = graphite. This is the single most important piece of information design in the app.

## Screens

### Today (default tab)
Two sections. **Now** — steps due today, each one a sentence naming a specific action and a
specific person. **Ahead** — the next few tracked events with their dates. When Now is empty,
that's a success state and should read like one.

### Events
Every event from the tracked calendars, grouped by day. Tracked events carry an amber rail down
their left edge. Swipe to track/untrack. Toolbar has a calendar icon opening **Add in bulk**.

### Add in bulk
Month grids across a 60-day window. Days with events show a dot; amber means something that day
is already tracked. Tap a day to expand its events, tick the ones you want, apply once. It is
**two-way** — unticking a tracked event removes it. Per-day All/None.

### Plan (pushed from an event)
The heart of the app. A **vertical timeline with a hairline rail** — not a list of cards. Each
rung shows its relative time (−21d), its audience color, the sentence, and its state. Steps can
be reworded, re-timed, pinned, snoozed, marked done or skipped. A banner appears when the run-up
was compressed because the event is soon. Overflow menu: share as text, stop tracking.

### Event scratchpad (attached to the event)
Notes, links, and a photo of the whiteboard, reachable from the notification itself. This kills
the "send leads the schedule — wait, where's the schedule" problem.

### Settings
Which calendars to read, quiet hours, the caps, and **"Which steps you skip"** — a private
diagnostic, not a score. If you skip the −21d step every time, the offset is wrong and you
should be able to see that.

### Onboarding
Scrolls, with its action button pinned below. Must be finishable at the largest accessibility
type sizes.

## Visual language

Warm editorial, not productivity-app cold. Closer to a well-set book than to a dashboard.

| Token | Hex | Use |
|---|---|---|
| paper | `#FBF7F0` | app background |
| ink | `#241F1A` | primary text |
| amber | `#C77D33` | accent, tracked rail, leaders |
| clay | `#9B5C4A` | participants / students |
| graphite | `#5A5550` | self |
| muted | `#8A8078` | secondary text |
| hairline | `#E8E0D5` | rules, rails, dividers |

- **Type:** a serif (currently New York) for screen titles and event names; a neutral sans for
  body and notification copy. One weight step between levels, no more.
- **Layout:** generous vertical rhythm, 20pt horizontal margins, **no cards within cards.**
- **Motion:** state changes only. No decorative animation.
- Contrast note: amber on paper is ~3.1:1, so it is for controls and accents — never body copy.

## What the reminders sound like

> Ask your team leads who's available for Sunday. — *3 weeks out*

> Anyone who hasn't answered yet — follow up today. — *1 week out*

> Send arrival times to the team. — *2 days out*

Specific action, specific person, specific day. That specificity is the whole product.

---

# Where I want the design to make it more useful

The app is functionally complete. These are the places where I think **design**, not code, is
what's missing. Treat these as the actual brief.

1. **Today doesn't feel like a morning glance.** It's correct but flat. It should answer "what
   do I owe people today?" in one look, from the lock screen distance. Right now you have to
   read it.

2. **The Plan timeline doesn't dramatize the one opinion the app has** — that leaders come
   before participants. The colors carry it, but nothing makes you *feel* the ordering. This is
   the app's whole thesis and it's currently a subtle hue difference.

3. **There's no sense of the week as a shape.** Everything is either "today" or "a list of
   events." Something between them — a week view, a pressure curve, a sense of what's building
   — would make the app useful for planning rather than only for reacting.

4. **The caps are invisible.** "Never more than 6 a day" is a genuine promise and a real
   selling point, and the interface never says it except buried in Settings. It should be
   something you can feel.

5. **The skip-rate diagnostic is buried and dry.** It's the most interesting idea in the app —
   *your own data telling you the playbook is wrong for you* — and it currently looks like a
   settings row.

6. **Compressed plans need a better story.** When an event is too soon for the full ladder, the
   app squeezes it and shows a banner. That moment deserves a real design, because it's when
   the user is most stressed.

7. **The empty state is the most common state.** Most days there is nothing due. That screen
   should be the best-designed one in the app, not an afterthought — it's the reward for
   staying ahead.

## Constraints for whatever you design

- iPhone only, iOS 26, SwiftUI. Standard navigation patterns.
- No dark-mode-only or light-mode-only designs; both must work.
- Must survive the largest Dynamic Type sizes — no fixed heights on anything with text, no
  line-limit truncation on the sentences.
- Nothing may look like a streak, a score, a badge, or a progress bar toward 100%.
- No illustration-heavy empty states. A sentence.
- Don't introduce an "AI" label anywhere.
