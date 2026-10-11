# Controlled Demo room

Open **Demo · Chat** for everyday conversation or **Demo · Dinner** for the planning story. Both use scripted cast and short scripted Pal replies for predictable timing. Other rooms use the real Eve/OpenAI agent. The dinner story persists actual guarded preferences, plan and RSVP records; no restaurant is booked by a script.

The normal composer fills the next suggested message when ready. Press Send to control the pace, then the cast replies one by one. There is no stage overlay or rehearsal status. Typed drafts are never overwritten. You can still type normal follow-ups; edited text uses the real agent and does not advance the scripted story. The six scenes gather preferences, retrieve saved venues, draft Delfina dinner, move it to eight, confirm the plan and collect each member's own RSVP. The mock replies are deliberately short and contextual; demonstrate the real agent in an ordinary room if needed.

The saved venue and inspected social sources retain their real provider evidence and uncertainty. Menu, budget and reservation availability need actual verification. A confirmed group plan does not mean a restaurant booking. A member completes the reservation on its official page.

Use **Start over** in the room toolbar to rehearse again. Confirmation clears only this registered room's runtime messages and plans, retaining its seed ideas and members. Stale scene retries are rejected and exact transport retries reuse their original message. An interrupted cast sequence resumes through server maintenance. If Pal needs clarification, answer it normally before continuing.

Automatic push notifications and Google Calendar copies are disabled for this rehearsal room, preventing mock RSVP notifications or calendar clutter. Those integrations remain enabled for real rooms. Native Add to Calendar is a manual operation; use it only if you want a real copy.

Setup: `node --env-file=.env --import tsx scripts/setup-demo-variants.ts --apply` prepares the two registered rooms without resetting existing Dinner. The original `node --env-file=.env --import tsx scripts/setup-demo-room.ts` previews the guarded cleanup; `--apply` backs up and removes only verified fixture-only rooms before preparing the dedicated Demo. Never use the old broad demo reset for this workflow.

Acceptance: `node --env-file=.env --import tsx scripts/smoke-demo-room.ts https://pal-jade.vercel.app plan` (or `chat`) creates an isolated temporary presenter and room, runs the bounded mock handler with real guarded plan/RSVP operations, verifies replay/draft/change/confirmation/RSVP/reset, then removes only its own fixture. Failure evidence is saved privately under `.secrets/` without credentials. Supabase SQL regressions are in `supabase/tests/demo_room.sql`.

The founder requested a clean test database after this setup. A separate guarded one-time cleanup backed up and deleted the nine other captured rooms,186 messages and four plans; their two Pal Google copies were removed through the calendar worker. Accounts, profiles, notification devices, calendar connections, media objects and the original Demo were preserved. Empty private Pal rooms may be recreated by the normal inbox flow.
