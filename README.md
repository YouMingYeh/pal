# Pal

Native iOS group chat with an Eve/OpenAI agent and reminders persisted in Supabase.

Open `ios/Pal.xcodeproj`, select an iPhone simulator, and run. The app already contains the public client configuration for `https://pal-jade.vercel.app`. Sign in with Apple, create a group, and share its invite code with the second user. The project uses Kardomo's developer team (`6GAAMYMS72`); the Apple capability and Supabase Apple provider are enabled for `com.pal.spike`.

Demo: discuss who will bring snacks and a laptop, then send `@Pal summarize our plan and remind us to bring the charger in two minutes`. Pal reads the actual group messages and saves a reminder. Close the app; Supabase Cron posts the reminder to the group independently. Reopen the chat to see it. Delivery runs once per minute; this spike does not send APNs notifications.

The live integration check passed with two authenticated users, duplicate-message protection, outsider isolation, a real Eve/OpenAI tool call, and exactly one reminder delivered after all clients signed out and the local backend stopped. A second task submitted directly to Supabase was recovered by server Cron after the clients signed out. Native integration uses test accounts; the actual Apple account sign-in still requires a device check. Local demo account credentials are stored only in ignored `.env.demo.local`.

For local backend development, use Node 24, run `npm ci`, configure an ignored root `.env` using `.env.example`, and run `npm run dev`. Set `PAL_BASE_URL=http://127.0.0.1:3000` locally. Server keys never belong in the iOS app or Git.

Checks: `npm run typecheck`, `npm test`, `npm run build`, and `npm run smoke` (requires configured services; creates isolated demo accounts and waits for real Cron delivery). Native simulator tests and configuration are described in `ios/README.md`; migrations and database assertions are in `supabase/README.md`.

The agent exposes only group-message reading and reminder creation. Maps, browser automation, calendar sync, games, and push notifications remain outside this infra spike.
