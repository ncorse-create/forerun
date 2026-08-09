# Spike A — TickTick Open API

- **Blocker:** PF-2
- **Run:** 2026-08-09, documentation research only. No app registered, no code written.
- **Authoritative source:** `https://developer.ticktick.com/docs/openapi.md` — the raw markdown.
  The human page at `/docs#/openapi` is a React shell that loads this file in an iframe;
  `GET /docs` returns 404 and `/api` returns 403. **Re-fetch this URL, never a GitHub mirror.**

## Summary — the five facts that decide the sprint

1. **A `client_secret` is mandatory.** One grant (`authorization_code`), credentials via HTTP
   Basic at `https://ticktick.com/oauth/token`. **PKCE appears nowhere in the docs** — no
   `code_challenge`, no `code_verifier`, no public-client flow.
2. **There is no calendar surface at all.** The words "calendar" and "event" occur zero times
   in the docs. Tasks, projects, focus records, habits — that is the entire API. Calendars
   subscribed *into* TickTick are a client-side display feature and are **not reachable**.
3. **Task carries everything the red rule needs**: `priority` (0/1/3/5 — 2 and 4 unused),
   `tags`, `dueDate`/`startDate`, `content`, `desc`, `isAllDay`, `timeZone`.
4. **Project carries `color`** as a hex string (`"#F18181"`), and it is **optional** — it is
   present in the project-list example and absent from the project sub-object inside
   `/data`, so the model must treat it as nullable.
5. **There is no refresh token.** Observed `expires_in` ≈ 171 days. A 401 means re-run the
   entire authorization flow, roughly twice a year.

Every mirror and every third-party "API guide" is stale — they predate `tags`, `kind`, and the
`move`/`completed`/`filter` endpoints. The widely-repeated "100 req/min rate limit" is a
fabrication; the page it is attributed to says explicitly that no limits are published.

## Findings

### OAuth

| Question | Answer |
|---|---|
| PKCE supported? | **Undocumented — treat as no.** Zero hits for PKCE terms across the full 67KB doc. |
| `client_secret` mandatory? | **Yes.** "you will need to register your application and obtain a client ID and client secret." |
| Token endpoint auth | Documented as **HTTP Basic** (`client_id`:`client_secret` in the header). Form-body credentials also work in practice (`ticktick-py`, Arcade's `client_secret_post`), but Basic is what is documented — use Basic. |
| Scopes | Exactly two: `tasks:read`, `tasks:write`. **Space**-separated. Must be sent again on the **token** request, not just authorize. |
| Grant types | `authorization_code` only. |
| Expiry / refresh | `expires_in` returned (~171 days observed). **No `refresh_token`.** |
| Hosts | OAuth on `ticktick.com`, API on `api.ticktick.com`. Split hosts — easy to get wrong. |

Two apparent PKCE data points do not survive checking. `tsutsuhiro/ticktick-mcp-server`
advertises "OAuth 2.1 with PKCE" but its own setup requires a keys file containing
`client_secret` — PKCE layered over a confidential-client exchange, not a replacement.
`TickTeam/ticktick-cli` is summarized as "requires no client secret" but the claim could not be
verified from primary text. **UNKNOWN, and worth one empirical test before shipping.**

### Endpoints used by Forerun

```
GET  /open/v1/project                    → [Project]
GET  /open/v1/project/{projectId}/data   → { project, tasks, columns }
```

`ProjectData.tasks` is **undone tasks only** — completed tasks require
`POST /open/v1/task/completed` or `POST /open/v1/task/filter` with `status: [2]`. Forerun is
read-only and only cares about upcoming work, so undone-only is exactly right and no extra
call is needed.

### Task fields

| Field | Type | Note |
|---|---|---|
| `id`, `projectId`, `title` | string | |
| `priority` | int | None `0`, Low `1`, Medium `3`, High `5`. **2 and 4 are never used.** |
| `tags` | [string] | |
| `dueDate`, `startDate`, `completedTime` | string | `yyyy-MM-dd'T'HH:mm:ssZ`, offset **without a colon** (`+0000`) |
| `timeZone` | string | IANA name, e.g. `America/Los_Angeles` |
| `isAllDay` | bool | |
| `content`, `desc` | string | |
| `status` | int | Normal `0`, Completed `2` |
| `repeatFlag` | string | `RRULE:…` |
| `items` | [ChecklistItem] | **ChecklistItem completed is `1`, not `2`.** Different from Task. |

**Date parsing is a trap.** The offset has no colon, and live examples from the newer endpoints
also carry fractional seconds (`2026-03-04T23:58:20.000+0000`). `ISO8601DateFormatter` with
default options fails on both. The parser must try `.withInternetDateTime` *and*
`.withFractionalSeconds`, with a `DateFormatter` fallback on `yyyy-MM-dd'T'HH:mm:ssZ`.

**UNKNOWN:** how `isAllDay: true` interacts with `dueDate` — midnight UTC, midnight in
`timeZone`, or exclusive end. Determine empirically before trusting an all-day TickTick task's
anchor date.

### Rate limits

**Undocumented.** No `X-RateLimit-*` headers, no 429 in the documented responses. Assume limits
exist, throttle to 3 concurrent, cache the project list 24h, back off on 429/5xx.

### Redirect URI

**UNKNOWN for custom schemes** — this is the one design-relevant fact no public source settles.
Working public examples all use loopback http (`http://localhost:8000/callback`), and
ticktick-py's guide notes the URL "does not have to be an actually live URL," which suggests
permissive validation. No source confirms or denies `forerun://oauth`.

## Impact and decision

See `docs/decisions/002-ticktick.md`. Short version: **Option A — embed the client secret and
treat it as public** — with an `ASWebAuthenticationSession` https Universal Link callback on
iOS 17.4+, which removes the code-interception attack that PKCE would otherwise cover, and
sidesteps the unresolved custom-scheme question.

A token-exchange proxy was rejected: it would break the no-cloud promise while making things
*worse*, because the proxy would handle a full-scope, non-rotatable, six-month token for every
user. A leaked client secret grants an attacker access to no user data on its own; a breached
proxy grants access to every user's entire task database for half a year.

## Sources

- [TickTick Open API — official raw docs](https://developer.ticktick.com/docs/openapi.md)
- [TickTick Developer Center](https://developer.ticktick.com/manage)
- [ticktick-py OAuth docs — no refresh token](https://lazeroffmichael.github.io/ticktick-py/usage/oauth2/)
- [ticktick-py on PyPI — redirect URL guidance, ~6-month token](https://pypi.org/project/ticktick-py/)
- [jacepark12/ticktick-mcp — HTTP Basic exchange](https://github.com/jacepark12/ticktick-mcp)
- [Arcade — TickTick auth provider](https://docs.arcade.dev/en/references/auth-providers/ticktick)
- [DeepWiki — tsutsuhiro PKCE flow, layered over client_secret](https://deepwiki.com/tsutsuhiro/ticktick-mcp-server/3.1-oauth-2.1-pkce-flow)
- [Rollout — states no official rate limits are published](https://rollout.com/integration-guides/tick-tick/api-essentials)
- [TickTick Help — calendar subscriptions are client-side](https://help.ticktick.com/articles/7055781614550253568)
