# Forerun — submission checklist and store copy

Everything here is written. The items marked **owed** need a person, a device, or an account —
they cannot be finished from a build machine.

## PF-3 — privacy policy

The page is written at `web/privacy.html`.

**Owed:** publish it and confirm it returns 200 before the first TestFlight build.

```bash
# From the repo root, in whatever static host you use:
#   persue.app/forerun/privacy  →  web/privacy.html
curl -sI https://persue.app/forerun/privacy | head -1     # must be 200, not 301 → 404
```

This is the Busy Branches lesson: a 2.1 rejection for a privacy URL that did not resolve. Fetch
it for real, from outside your own machine, before submitting.

## Privacy nutrition label

**Data Not Collected** across the board. Every category answers "No."

There is no analytics SDK, no crash reporter, no advertising identifier, and no server. Verify
before each submission:

```bash
grep -rniE 'firebase|amplitude|mixpanel|sentry|appsflyer|adjust|facebook|googleanalytics' \
  --include='*.swift' --include='*.yml' . | grep -v '^./docs'
```

**If a build ships with TickTick credentials**, the label still says Data Not Collected — the
token lives in the device Keychain and the connection is device-to-TickTick — but the policy text
must describe the connection, which it already does. A credential-free build needs no TickTick
disclosure at all.

## Purpose strings

All four are specific rather than generic, which is what reviewers actually reject over. They live
in `project.yml` and are the single source of truth.

| Key | String |
|---|---|
| `NSCalendarsFullAccessUsageDescription` | Forerun reads the events on the calendars you pick so it can plan the run-up to each one. Your events stay on this iPhone. |
| `NSCalendarsWriteOnlyAccessUsageDescription` | Forerun can block the working hours for a deep-work event on your calendar when you ask it to. |
| `NSContactsUsageDescription` | Forerun uses the people you pick to pre-fill a message to your team leads. It stores only their name and a reference, never their full contact card. |
| `NSCameraUsageDescription` | Forerun attaches a photo of the whiteboard to the event so the material is there when the reminder fires. Photos stay on this iPhone. |

Note there is deliberately **no** `NSRemindersUsageDescription` and no photo-library string: the
contact picker runs out of process, and the camera is the only image source. `PhotoCaptureSheet`
is camera-only (`sourceType = .camera`, no fallback) and the Photo menu item is hidden entirely
when no camera is available — an earlier version fell back to `.photoLibrary`, which was a second
image source with no purpose string behind it.

## Accessibility

Done in code:

- VoiceOver labels, values and hints on every interactive element — event rows, step rows, the
  kind chip, contact and material rows, and both custom action chips.
- `.accessibilityActions` on step rows, so Done / Skip / Snooze are reachable without swiping.
- No `lineLimit` anywhere, no fixed heights on any text-bearing row, and `fixedSize(vertical:)`
  on every wrapping label — content grows rather than clipping.
- Onboarding scrolls with its action button pinned below, which is what makes it finishable at
  accessibility sizes.
- Motion is state-change only; there is no decorative animation to respect Reduce Motion for.
- Contrast against paper `#FBF7F0`: ink `#241F1A` is ~14.9:1, muted `#8A8078` is ~3.6:1 and is
  used only for secondary text at or above the body size, amber `#C77D33` on paper is ~3.1:1 and
  is used for controls and accents, never for body copy.

**Owed on device:** a VoiceOver pass and an AX5 Dynamic Type pass on all four screens. The
contrast figures above are computed, not measured on hardware.

## App Store description

**Name:** Forerun
**Subtitle:** Plan the run-up, not the day

---

Your calendar already knows when things happen. It has no idea what has to happen first.

Forerun reads the events you pick and works backwards. Three weeks out, it tells you to ask your
team leads who's in. A week out, to chase whoever hasn't answered. Two days out, to send arrival
times. The day before, to message everyone else. Each reminder names a specific action and a
specific person, because that is what makes a reminder work.

It contacts your leaders before your participants — always, automatically — because telling
students about an event before you've confirmed the team is how you end up short-handed in public.

A handful of reminders. Never more than a few a day, ever, no matter how much you're running.
No streaks, no badges, no count on the app icon, no list to clear. When there's nothing to do,
Forerun says so and gets out of the way.

**Six playbooks**, for a volunteer team event, a talk you're preparing, deep work, a student
event, a deadline, and everything personal that needs no run-up at all.

**It moves when your calendar moves.** Change the time and the whole ladder re-times itself.
Anything you rewrote stays rewritten.

**Everything you need, attached.** Notes, links, a photo of the whiteboard — on the event, so
they're in front of you when the reminder arrives.

**Nothing leaves your iPhone.** No account. No sign-up. No servers. Reminders are scheduled by
your own device, and the wording is written on it too.

---

The word "AI" appears nowhere above the fold, on purpose — and the wording feature is described by
what it does rather than by what runs it.

## Screenshots — owed

Five, at 6.9" and 6.5". Take them on a device with a real, populated calendar; a screenshot of an
empty app sells nothing.

1. **Today** — two or three steps in Now, two events under Ahead.
2. **Events** — a week grouped by day, several tracked rows showing the amber rail.
3. **Plan** — a full volunteer ladder, leader steps above the participant step, one step
   visibly edited.
4. **Plan, compressed** — a short-notice event with the "This is a tight run-up" banner.
5. **Settings** — the reminders section, showing the caps.

## TestFlight week — owed

Run real events through it for a full week before submitting. The plan asks for one specific
measurement, and it is worth taking seriously:

> Track your own skip rate. If you're skipping more than a third, the playbook offsets are wrong,
> not the concept.

Settings → Which steps you skip reports exactly this. It exists for that week.

## Build

```bash
xcodegen generate           # first on a fresh clone — the .xcodeproj is gitignored
./scripts/build.sh          # compile check, generic iOS destination, no simulator
./scripts/test-core.sh      # engine tests on macOS, no simulator
```

`xcodegen generate` comes first, and again after adding or moving any file.

Archive with manual signing. Cloud signing cannot issue the distribution certificate from an ASC
API key.

## Still owed before 1.0

- [ ] Privacy policy live and returning 200
- [ ] App Store Connect record created (an ASC API key cannot create one)
- [ ] Screenshots at both sizes
- [ ] A week of TestFlight with real events
- [ ] VoiceOver and AX5 passes on device
- [ ] Decide whether the privacy policy's TickTick section ships in a credential-free 1.0 — it
      currently describes a surface a reviewer would not be able to find
- [ ] Decide whether 1.0 ships with TickTick credentials at all — a credential-free 1.0 is
      complete, hides the surface entirely, and needs no OAuth disclosure
