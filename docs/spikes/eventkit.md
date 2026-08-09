# Spike B — EventKit

- **Run:** 2026-08-09
- **Probe:** `scripts/eventkit-probe.swift` (read-only, macOS, run with `swift scripts/eventkit-probe.swift`)
- **In-app proof:** Settings → About → Diagnostics reports every runtime row below on device.

## Probe outcome on this machine

```
granted: false  status: 4      # EKAuthorizationStatus.writeOnly
DENIED — grant Calendar access to your terminal in System Settings > Privacy
```

The command-line tool holds **write-only** calendar access and macOS will not escalate it to
full access from a `swift` script invocation, so the calendar inventory could not be enumerated
here. This is a TCC property of the terminal, not a finding about EventKit. Two consequences,
both handled:

1. The runtime rows below are marked **owed on device** and are answered by the in-app
   Diagnostics screen, which runs the identical logic inside the signed app where the
   entitlement and purpose string are present.
2. It surfaced a real API fact worth writing down: **`writeOnly` is a distinct status from
   `denied`, and it is a status a real user can land in.** iOS 17+ splits calendar access, and
   an app that only checks `status == .denied` will fall through to "authorized" while every
   read returns nothing. `EventKitSource.isAuthorized` therefore tests
   `status == .fullAccess` explicitly and treats `.writeOnly` as unauthorized-for-reading with
   its own error sentence, separate from denied.

## Findings

### Authorization — CONFIRMED from API contract

- `EKEventStore.requestFullAccessToEvents(completion:)` / the `async` form is the iOS 17+ call.
  `requestAccess(to:)` is deprecated and must not be used.
- `NSCalendarsFullAccessUsageDescription` is the required purpose string. The old
  `NSCalendarsUsageDescription` is not sufficient on iOS 17+ and its absence is a launch crash,
  not a denial. Both the full-access and write-only strings are declared in `project.yml`.
- Statuses to handle: `.notDetermined`, `.restricted`, `.denied`, `.fullAccess`, `.writeOnly`.
  Only `.fullAccess` permits the read this app is built on.
- Contextual request (locked decision 6): the call is made from the "Connect Apple Calendar"
  button in onboarding/Settings, never at launch.

### Calendar colors — CONFIRMED (API), family bucketing owed on device

- `EKCalendar.cgColor` is `CGColor?` and is optional in the header. The classifier treats `nil`
  as `.gray` rather than force-unwrapping.
- The color must be converted into sRGB before reading components — a calendar color can carry
  a non-RGB color space and reading `components` directly gives garbage hue. `ColorFamily`
  does the conversion explicitly.
- Hue buckets used (degrees): red `345–360 ∪ 0–15`, orange `16–45`, yellow `46–65`,
  green `66–165`, blue `166–255`, purple `256–290`, pink `291–344`; saturation `< 0.15` → gray.
  Unit-tested in `ColorFamilyTests` against the eight Apple Calendar system colors plus five
  custom hexes, using a pure-Swift HSB conversion so the test needs no UIKit and no device.

### Subscribed `.ics` calendars — owed on device

`EKCalendar.type == .subscription` is the case to look for, and subscribed calendars appear in
`calendars(for: .event)` alongside local and CalDAV ones. Two properties the app depends on and
that Diagnostics reports:

- a subscribed calendar carries a **user-assigned** color, not the publisher's, because the
  color is set in the subscriber's Calendar app;
- `allowsContentModifications == false` on subscriptions, which is why calendar write-back
  (Sprint 14) must filter the destination-calendar picker to writable calendars only.

**A TickTick-published calendar subscribed into Apple Calendar is expected to land here as
`.subscription`.** That path is the recommended setup and is what makes the native TickTick
integration optional rather than load-bearing.

### Recurring events — CONFIRMED, and it drives the schema

`EKEvent.eventIdentifier` is **shared by every occurrence of a recurring series**. Fetching a
weekly meeting over a 60-day window returns ~8 `EKEvent` objects that all report the same
identifier. Using it alone as `sourceID` would collapse a semester of Sunday services into one
row and each sync would overwrite the previous occurrence's plan.

`NormalizedEvent.sourceID` is therefore a composite:

```
"\(eventIdentifier)|\(startDate.timeIntervalSinceReferenceDate)"
```

`hasRecurrenceRules` is recorded so the UI can label an occurrence as part of a series, and so
a future "recurring event templates" feature (v1.1) has the hook it needs.

`eventIdentifier` is also documented as optional. Events with a `nil` identifier are skipped
rather than synthesized, because a synthesized id would not survive the next sync and would
produce a duplicate.

### Change notification — CONFIRMED from API contract

`.EKEventStoreChanged` is posted on an arbitrary queue and is coarse — it says "something
changed," never what. The app debounces 2s and re-runs the windowed fetch rather than
attempting a delta. `EKEventStore` instances must be long-lived to keep receiving the
notification; a store created per fetch stops posting.

### Fetch window

`predicateForEvents(withStart:end:calendars:)`, now → +60 days, restricted to the user's
selected calendars. Passing `nil` for calendars reads everything and is only used by
Diagnostics.

## Owed on device (answered by Settings → About → Diagnostics)

| Question | Where answered |
|---|---|
| Does full-access read return events? | Diagnostics: event count for the next 60 days |
| Does `cgColor` return a usable color for every calendar? | Diagnostics: per-calendar color family table, flags `NIL_CGCOLOR` |
| Do subscribed `.ics` calendars appear with a user-assigned color? | Diagnostics: `TYPE` column shows `subscribed` |
| Does a TickTick-published calendar subscribed into Apple Calendar show up? | Diagnostics: look for it in the same table |
| Do recurring occurrences share one identifier? | Diagnostics: "recurring series sharing one identifier" line |

## Verdict

No blocker. The one design change forced by this spike is the composite `sourceID` for
recurring occurrences, which is baked into `SchemaV1` rather than retrofitted. The `writeOnly`
status is handled as a first-class case.
