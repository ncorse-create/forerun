# ADR 002 — TickTick ships, secret embedded and treated as public, credentials not committed

- **Status:** Accepted
- **Date:** 2026-08-09
- **Blocker resolved:** PF-2
- **Depends on:** `docs/spikes/ticktick-api.md`

## Context

Spike A established that the TickTick Open API requires a `client_secret` at token exchange and
documents no PKCE. It also established something the plan asked about and got a harder answer
to than expected: **the Open API has no calendar or event surface whatsoever.** Tasks,
projects, focus records and habits are the whole API. Calendars subscribed into TickTick are a
client-side display feature and cannot be read.

That second fact reframes the sprint. Sprint 9 was scoped as "native TickTick sync." What is
actually available is **native TickTick *task* sync**, and only for undone tasks. A user whose
TickTick usage is calendar-shaped gets nothing from OAuth that they do not already get for free
by subscribing their TickTick calendar into Apple Calendar, where it arrives as an
`EKCalendar` with `type == .subscription` and a user-assigned colour — which is precisely the
path Sprint 2 already reads.

## Decision

**Build Sprint 9, using Option A: embed the client secret and treat it as public from day one.**
No proxy. The sprint ships, but with three constraints that keep it honest.

1. **The secret is public and is designed for.** `strings` on a decrypted IPA recovers it and a
   proxied capture yields it in one run. Obfuscation buys minutes. The security posture assumes
   it is already published.
2. **Credentials are not in the repository.** `TickTickCredentials.swift` is gitignored and
   absent from a fresh clone. `TickTickSource.isConfigured` returns `false` when it is missing,
   and **the entire TickTick surface — the Settings row, the red rule, the connect flow —
   is hidden, not disabled.** A build with no credentials is a complete, shippable,
   EventKit-only app with no dead UI in it. This is what lets the sprint be built and reviewed
   before an app registration exists.
3. **The callback is an https Universal Link on iOS 17.4+.**
   `ASWebAuthenticationSession.Callback.https(host:path:)` intercepts the redirect before any
   network request is made, so the authorization code is delivered by an unforgeable Universal
   Link and never reaches a server — including ours. A custom scheme (`forerun://oauth`) is the
   fallback for older systems only. This removes the code-interception attack that PKCE exists
   to prevent, and it sidesteps the one question Spike A could not settle: whether TickTick's
   registration form accepts a custom scheme at all.

## Why not a token-exchange proxy

It breaks the no-cloud promise, and it makes the security worse rather than better.

The proxy would handle — and could trivially retain — every user's access token. That token is
full-scope (`tasks:read tasks:write`), has **no refresh token to rotate**, and lives roughly six
months. A breach of that proxy is a compromise of every user's entire task database for half a
year. A leaked client secret, by contrast, grants an attacker access to **no user data at all**:
redeeming a token still requires a real user to approve a consent screen *and* the code to be
delivered to the registered redirect URI.

The proxy also does not fix the underlying weakness. It cannot add PKCE — only TickTick's
server can. It does not stop client impersonation. It converts a low-severity, no-data-exposure
risk into a high-severity, all-data-exposure one, in exchange for hiding a value that RFC 8252
already tells us to treat as public.

## Residual risks, accepted and named

| Risk | Accepted because |
|---|---|
| **Client impersonation** — a third party stands up a consent screen carrying Forerun's registered name. | Unfixable without PKCE support on TickTick's side. Not made better by a proxy. |
| **Shared-fate suspension** — a banned or throttled `client_id` breaks every install at once, and the secret cannot be rotated without a new build. | Real. Mitigated only by keeping polling conservative. Documented so it is not a surprise. |
| **All-day `dueDate` semantics UNKNOWN** | Anchor resolution for all-day TickTick tasks falls back to `preferredDeliveryHour` on the date component in the task's own `timeZone`, which is correct under every candidate interpretation. |
| **Custom-scheme registration UNKNOWN** | Made moot by the https Universal Link callback. |

## Owed before the TickTick surface can ship

Not blockers for the build — blockers for turning it on.

1. Register the app at `developer.ticktick.com/manage`; capture `client_id` and `client_secret`
   into `Forerun/Sources/TickTickCredentials.swift` (gitignored).
2. In the same sitting, run the 30-minute empirical test: attempt `/oauth/token` **with**
   `code_challenge`/`code_verifier` and **no** `client_secret`. If it succeeds, the unverified
   `ticktick-cli` claim is real, there is a proper public-client flow, and the embedded secret
   can be deleted outright. If it 401s, this ADR stands unchanged.
3. Register the https redirect URI and host an `apple-app-site-association` file for it. A
   static host is sufficient and correct — it serves a file, runs no logic, and never sees the
   code.
4. Confirm all-day `dueDate` semantics against a real all-day task.

## Consequences

- Sprint 9 is buildable and reviewable now, and inert until step 1 above happens.
- The privacy policy and nutrition label must describe the TickTick connection accurately
  **only if the shipped build has credentials**. A credential-free 1.0 is "Data Not Collected"
  across the board with no OAuth disclosure needed.
- The deduplication logic (TickTick task vs. Apple Calendar event, same normalized title within
  ±15 minutes) remains essential, because subscribing the TickTick calendar into Apple Calendar
  is the *recommended* setup and a connected user will otherwise see everything twice.
