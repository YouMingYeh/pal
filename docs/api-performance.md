# API performance review

The inbox now loads through one membership-checked SQL RPC rather than a separate latest-message and unread request for each room. Message history reuses in-page reply parents; group state signs member and group photos concurrently. Message acknowledgement no longer waits for response-routing reads or agent execution. Authentication and live membership checks remain authoritative.

## Hosted measurements

Measured on October 11, 2026 against `https://pal-jade.vercel.app`, from the development Mac, with the same isolated account before and after deployment. The fixture had four shared rooms with twenty text messages each, plus the owner’s private Pal room. Each endpoint had five sequential requests; “warm median” uses requests two through five. Times include network, authentication and response decoding. The first request is reported separately; it is not a verified platform cold start.

| Endpoint | Before warm median | After warm median | Change | Before first / after first |
|---|---:|---:|---:|---:|
| Inbox | 1,084 ms | 408 ms | 62% lower | 1,118 / 1,844 ms |
| Messages | 581 ms | 502 ms | 14% lower | 596 / 635 ms |
| Group state | 459 ms | 324 ms | 29% lower | 498 / 407 ms |
| Profile | 375 ms | 360 ms | 4% lower | 572 / 365 ms |
| Google connection status | 342 ms | 371 ms | 8% higher | 372 / 424 ms |

The inbox improved substantially on repeated reads, while its first request was slower. Google status showed no improvement. Four warm samples do not establish a percentile, cold-start guarantee or device frame rate; the baseline also included one 5,748 ms state outlier. These fixtures had no uploaded photos, voice messages or connected calendar, so they do not measure cold image signing, media transfer, provider APIs or large-group scaling. Raw reports were kept in `/tmp/pal-query-before.json` and `/tmp/pal-query-after.json`; they contain timings, not credentials.

## Endpoint coverage

| Path and method | Review and resulting behavior |
|---|---|
| `/api/groups` GET | One authenticated `pal_inbox` RPC ensures the owner’s missing private room, returns current memberships, latest visible message and exact unread counts. SQL excludes internal weekly requests. Group photo signing is parallel. Inbox DB HTTP reads changed from three plus two per room to one RPC, excluding authentication and optional storage signing. |
| `/api/groups` POST | Name-only or atomic name/photo creation retains client-id replay protection and cleanup. A committed result, rather than a partially uploaded room, opens the conversation. |
| `/api/groups/join` POST | One invitation RPC after authentication; signs the returned group photo. No global membership cache or invite bypass. |
| `/api/groups/:id/messages` GET | Current membership check; latest 200 messages. Parent quotes already in the page require no extra query; only missing parents use one bounded same-group query. Attachment lookup runs concurrently with missing-parent lookup. Quote snippets are capped at 500 characters; original message bodies remain intact. |
| `/api/groups/:id/messages` POST | Validates text, replies and structured mentions, then acknowledges the idempotent `send_message` transaction. Direct-room/reply routing checks and dispatch run after acknowledgement. Ordinary conversation retains the short batching window. |
| `/api/groups/:id/state` GET | Authentication plus `pal_group_state`, whose SQL checks current membership before returning any records. Member and group photo signing run concurrently. Plans, attendance, availability and activity remain authoritative; full shared state is not a cross-user response cache. |
| `/api/groups/:id/state` POST | Validated actions use the same guarded `pal_action` RPC as agent tools. Reply routing happens after acknowledgement; plan, RSVP, reminder and reaction permissions remain unchanged. |
| `/api/groups/:id/attachments` POST | File normalization and narrow replay lookup run concurrently. An exact retry reuses its blob; the authoritative RPC verifies identity and content. Response routing runs after acknowledgement. Private file signing retains fixed client dimensions and retry identity. |
| `/api/groups/:id/locations` POST, DELETE | Validated coordinate/accuracy or stop request calls one scoped RPC after membership validation. Private rooms reject sharing; current points expire after one hour. Device writes are foreground-only and throttled. |
| `/api/groups/:id/members/:memberId/summary` GET | Checks requester and target membership, then fetches at most forty messages and forty facts concurrently. Source-version keyed summaries coalesce identical in-flight generation for ten minutes, capped at 200 entries; failed generation is evicted. Every read checks membership before using generated content. |
| `/api/profile` GET, PATCH | Reads the current user’s narrow profile fields; only a missing profile invokes creation. Updates use the guarded save RPC, private photo cleanup and signed response. |
| `/api/profile/avatar` POST, DELETE | Bounds upload size, normalizes images/removes metadata, verifies owner paths and safely replaces the stored photo. Failed uploads do not replace a working avatar. |
| `/api/devices` POST, DELETE | Validated token/environment uses an authenticated registration/removal RPC. Native registration coalesces repeated requests in the signed-in session. No tokens are logged. |
| `/api/calendar/status` GET | Reads the member’s connection once. A disconnected response avoids a second lookup of the same connection. No Google event listing is needed. |
| `/api/calendar/connect` GET | Creates short-lived, owner-bound OAuth state. This is a fresh authorization operation, not a cacheable read. |
| `/api/calendar/callback` GET | Validates and consumes OAuth state, exchanges the code and prepares Pal’s own calendar. Follow-on event sync runs after the redirect; authorization codes and provider secrets stay out of logs. |
| `/api/calendar/disconnect` DELETE | Uses the existing connection record with conditional updates, revokes the token and clears credentials. It does not repeatedly look up the same connection. |
| `/api/places/search` GET | Authenticates and validates bounded search text/coordinate pairs before Apple Maps search. Provider latency remains outside the database optimization. |
| `/api/dispatch` POST | Secret-protected maintenance, leased job dispatch and integrations run after a 202 response. Agent claims are bounded to three jobs; calendar synchronization is bounded to ten claimed items. |
| `/api/health` GET | Static liveness response; no database or provider round trip. |

## Agent, cache and notification boundaries

Initial agent turns reuse verified group state and recent messages fetched concurrently. Whitelisted input is capped at 32 KB, with at most twenty recent messages and bounded nested records; omitted data is declared. Simple replies avoid immediately rereading the same snapshot. Cross-group context stays owner-DM-only, checks current memberships atomically, limits each page to five rooms and caps the result at 32 KB. Additional scoped reads remain available when required.

Server image caches store bounded expiring signed URLs by validated private object path, after the caller’s authorized record read. They never cache membership, sessions or whole authenticated responses. Native reads are account-bound and share overlapping requests; Realtime invalidates those authorized reads, with polling recovery. Reopening a cached room retains content while refresh runs; a cold launch still needs a network read. Private decoded image caching stays in memory and clears across account changes.

Only explicit selected-reply intent exposes typing, for at most twenty seconds on the current leased attempt. Quiet shared-link processing ends with one concise terminal result or failure reply. Pal can send separate short chat bubbles; one job creates one actionable push per recipient. Automatic RSVP invitations similarly coalesce by plan version and prefer the bubble mentioning that recipient. Genuine independent reminders and changes keep their own deliveries. Already-read queued ordinary pushes are cancelled; foreground banners and sounds are suppressed. APNs delivery still depends on provider/device availability and existing retry semantics.

Verification includes mounted route/query-shape tests, exact media replay and security checks, bounded-context tests, local SQL membership/lifecycle assertions and native cache/identity regressions. The current plan-invitation SQL test exercises nine members, two mention bubbles, one push per member, and a separate notification for the next plan version. This review does not claim an end-to-end latency target for social extraction, Google consent, native gestures or real GPS permission flows.
