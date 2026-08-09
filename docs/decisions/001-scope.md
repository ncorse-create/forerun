# ADR 001 — Forerun is a standalone app

- **Status:** Accepted
- **Date:** 2026-08-09
- **Blocker resolved:** PF-1 (scope collision with Tidings / Leadly)

## Decision

Forerun ships as a **standalone app**. It is not a mode inside Tidings and not a feature inside
Leadly. The three apps are separated by the question each one answers, and none of them can
answer another's question without becoming a different product:

- **Tidings** answers *"what do I say to the group this week?"* — it is a composer. Its unit of
  work is a single outgoing message assembled from a lesson plus this week's events, and its
  loop terminates at the moment you hit Send in the message sheet.
- **Leadly** answers *"who is helping at this event and what are they doing?"* — it is a roster.
  Its unit of work is a person assigned to a role at an event.
- **Forerun** answers *"what has to happen before this, and when do I start?"* — it is a clock.
  Its unit of work is a dated prep step, and it is the only one of the three whose primary
  surface is a notification rather than a screen.

A merged app would have to hold a composer, a roster, and a scheduler in one information
architecture. That is a suite, not an app, and it would make each of the three worse: Tidings
would gain a settings screen about quiet hours, Leadly would gain notification budgeting, and
Forerun would lose the restraint that is its entire thesis (locked decision 5 — "not a to-do
list"). The overlap is real but it is *data* overlap, not *job* overlap, and data overlap is
solved by a bridge, not by a merge.

## Boundary rules

These are enforceable, not aspirational. If a feature request violates one, it belongs in a
different app.

1. **Forerun never composes a recurring broadcast.** It hands off to
   `MFMessageComposeViewController` for one specific step at one specific moment with a
   specific recipient list. If a feature starts to look like "the weekly announcement," it is
   Tidings.
2. **Forerun never stores a role assignment.** It stores contact identifiers per event so a
   leader step can open a compose sheet. If a feature starts to look like "Sarah is on
   check-in," it is Leadly.
3. **Tidings and Leadly never schedule a lead-time ladder.** A single "send it now" reminder is
   fine in either. A dated sequence with audience ordering is Forerun's.

## Consequences

- Three App Store listings, three review cycles, three privacy policies. Accepted.
- The shared-plan / hand-a-ladder-to-a-co-leader feature stays deferred to v1.1, and that is
  where a Tidings bridge would live if one is ever built. It is explicitly *not* v1 scope.
- Contact identifiers are duplicated between Forerun and Leadly rather than shared. This is
  correct for a no-cloud, no-App-Group-across-apps design, and it keeps each app's privacy
  label honest and independent.

## Rejected alternatives

- **Front door to Tidings.** Rejected: it makes Forerun's value contingent on installing a
  second app, and Forerun's core loop (notification → tap → prep step) never needs a composer.
- **Feature inside Leadly.** Rejected: Leadly's model is event → roles → people. Forerun's is
  event → dated steps → audience. Grafting a scheduler onto a roster means every Leadly user
  pays the notification-budget complexity cost whether or not they want a ladder.
