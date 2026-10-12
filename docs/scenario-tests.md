# Scenario regression checks

Run `npm test` and `npm run typecheck` without loading live credentials. Unit tests replace provider transport and verify validation, source attribution, failure recovery and integration retries. They do not prove real restaurant availability, model quality, APNs delivery or calendar consent.

| User flow | Automated coverage |
| --- | --- |
| Open chats; enter a long conversation at the newest message | `FetchTests`, `MessageCacheTests`, `fast_inbox.sql`; mounted UIKit offsets, initial rendering and empty/loading distinction |
| Send, retry, quote and mention friends | `ConversationTests`, `RealtimeTests`, `conversation_outputs.sql`; stable identities, full text, same-group references and atomic multi-message replies |
| Pal joins selectively and types only when replying | `reply_activity.sql`, `smoke-reply-activity.ts`; silent resolved exchanges, untagged planning and real suggested-answer questions |
| Share a social link and retrieve its processed idea | `silent_sources.sql`, `research-social.test.ts`, `social-worker.test.ts`; silent inspection, ambiguity, original evidence, completion retry and deduplication |
| Remember diet, budget and dated availability | `core-v1-member-memory.test.ts`, `collected_availability.sql`; actual speakers, expiring facts and explicit unknown responses |
| Plan dinner, confirm, RSVP, move it and cancel | `friend_group_journey.sql`, `confirmed_plan_rsvp.sql`, `member_responses.sql`; one invitation per version, no implicit attendance and retired old reminders |
| Receive reminders after clients close | `friend_group_journey.sql`, `push_bursts.sql`, `integrations.test.ts`; durable delivery, one outbox item per recipient and safe deep links |
| Sync attending plans into Google Calendar | `v1.sql`, `integrations.test.ts`; stable event IDs, version/lease guards, cancellation and reconnect races using provider fixtures |
| Read across groups privately in Pal DM | `direct_chat.sql`, `core-v1-across-groups.test.ts`, `smoke-direct.ts`; current membership, isolated private context and no shared-room writes |
| Search current public information in group or DM | `smoke-web-search.ts`; actual OpenAI sources, short answers with official clickable links, two distinct source-message replies in one turn and idempotent delivery |
| Edit avatars; use location only where shared | `AvatarTests`, `MediaTests`, `LocationSharingTests`, `avatars.sql`, `locations.sql`; ownership, cache identity, permissions and location expiry |
| Calendar, appearance and animated mascot | `CalendarViewTests`, `ThemeTests`, `MascotTests`; month navigation, local dates, Dynamic Type and reduced-motion behavior |
| Rehearse both controlled rooms, restart, retry | `DemoTests`, `demo-replies.test.ts`, `demo_room.sql`, `smoke-demo-room.ts`; six exchanges each, exact replay, rejected edits/cast injection, stale-generation rejection and clean restart |

## Database checks

Apply the application migrations to a **dedicated empty test database** before running these assertions. Every current SQL suite rolls its fixtures back. Run all files in `supabase/tests/` except `spike.sql`, which describes the superseded mention-only queue. For the complete friend-group journey:

```sh
psql "$PAL_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/friend_group_journey.sql
```

The journey replaces model text generation with two structured replies, while using actual SQL actions, batching, source-speaker checks, question replies, invitation triggers, RSVP invalidation and reminder delivery. Its named cafe is a fixture, not a checked restaurant or reservation. Local PostgreSQL testing uses minimal Auth/Storage schema fixtures; hosted Cron and provider services require separate verification.

## Native checks

Run on an iOS Simulator so XCTest does not overwrite a real iPhone login:

```sh
xcodebuild test -project ios/Pal.xcodeproj -scheme Pal -destination 'platform=iOS Simulator,name=iPhone 15 Pro' -derivedDataPath ios/build CODE_SIGN_IDENTITY=-
```

The five opt-in native tests require an existing signed-in review account or private live fixture credentials. Interactive system UI, real Apple/Google consent, physical keyboard gestures, Share Sheet, camera/microphone permissions and APNs still need device checks.

## Hosted checks

These existing scripts create temporary identities and rooms, and remove only their fixtures in `finally`. They leave the founder's accounts, cleared history, connections and two Demo rooms intact. Supply the deployment origin explicitly:

```sh
node --env-file=.env --import tsx scripts/smoke-demo-room.ts https://pal-jade.vercel.app chat
node --env-file=.env --import tsx scripts/smoke-demo-room.ts https://pal-jade.vercel.app plan
node --env-file=.env --import tsx scripts/smoke-realtime-raw.ts https://pal-jade.vercel.app
node --env-file=.env --import tsx scripts/smoke-reply-activity.ts https://pal-jade.vercel.app
node --env-file=.env --import tsx scripts/smoke-conversation-actions.ts https://pal-jade.vercel.app
node --env-file=.env --import tsx scripts/smoke-direct.ts https://pal-jade.vercel.app
node --env-file=.env --import tsx scripts/smoke-web-search.ts https://pal-jade.vercel.app
```

The two rehearsals use mock dialogue with real persisted plan/RSVP state. The other agent scripts run real Eve/OpenAI. Report these separately; a passing rehearsal does not prove autonomous planning. Realtime timings measure one send-to-event sample, not scrolling FPS or model latency.

The search smoke calls the real search helper and the deployed agent separately. Eve does not expose provider-executed native searches as ordinary tool-action events, so the agent checks verify official linked findings rather than assert an unavailable native tool trace. Live model assertions can vary across model/provider changes.
