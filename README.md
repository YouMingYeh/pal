# Pal

Native iOS group chat with Eve/OpenAI, Supabase, saved places, planning cards, reminders, and personal Google Calendar sync.

Open ios/Pal.xcodeproj and run the Pal scheme. The checked-in public configuration points to https://pal-jade.vercel.app. Sign in with Apple, create or join a group, then invite a second member using the shareable link or invite code. Kardomo developer team: 6GAAMYMS72. App: com.pal.spike. Share extension: com.pal.spike.Share.

## Flow

Share a restaurant reel or paste a URL. Its source card progresses through inspection and lets members choose a branch or add a place manually. Saved places appear on the group map. Discuss a time; Pal selectively remembers explicit preferences and dated availability and can create polls or a draft plan without an @ mention. A member confirms the plan, and each person RSVPs separately. A member completes any external booking and records its details.

Confirmed plans schedule future 24-hour and 2-hour attendance reminders. Changes reset affected RSVPs and replace superseded reminders and Google event copies. The server posts reminder messages and sends APNs independently of the app. Notification taps open the relevant group card.

Profile contains Google Calendar connection and notification controls. Google uses only the app-created-calendar scope, creates a separate Pal calendar, and receives confirmed plans for members who RSVP Yes. Disconnecting stops updates and revokes credentials; existing Google events remain snapshots. Group details contain editable preferences, availability, proactive suggestions, and personal group muting.

## Services

- Supabase owns membership, source/place/poll/plan records, idempotent actions, private integration credentials and queues. Row-level security isolates groups.
- Eve runs durable scoped OpenAI turns; every human message is eligible, bursts are coalesced, and an empty structured reply means silence. Agent tools cannot confirm, vote, RSVP, or book for a person.
- Supadata inspects public Instagram/TikTok video content asynchronously. Extraction retains evidence and source metadata. Apple Maps search resolves candidates; uncertain places remain unpinned until corrected. Video prices and claims are distinct from current verified information.
- Safe URL reading checks public DNS, redirects, IP pinning, response size and timeouts. Research prefers official menus and reservation pages; it does not invent table availability.
- Minutely Supabase Cron delivers reminders and recovers jobs. The authenticated dispatch worker processes video inspection, Google Calendar copies, and APNs delivery.

## Development and checks

Use Node 24 and npm ci. Configure the ignored root .env using .env.example, then npm run dev. Set PAL_BASE_URL to the actual backend origin. Provider keys and Google refresh tokens are server-side; the iOS app contains only public client configuration. Keep PAL_INTERNAL_SECRET stable because it encrypts integration credentials. Apple private keys use base64 PEM environment variables.

Run npm test, npm run typecheck, and npm run build. npm run smoke:v1 exercises the deployed v1 flow using ignored demo identities; it creates isolated groups and checks real Eve completion plus closed-client reminder delivery. The historical smoke script targets the original spike. Native build/tests and physical-device setup are in ios/README.md. Migrations and PostgreSQL assertions are in supabase/README.md.

Member location sharing, automatic bookings, two-way calendar sync, games, image generation, and a personal feed are deferred. Social providers may reject private or inaccessible videos; the original link and manual correction remain available.
