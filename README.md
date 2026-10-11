# Pal

Native iOS group chat with Eve/OpenAI, Supabase, saved places, reminders, and personal Google Calendar sync.

Open ios/Pal.xcodeproj and run the Pal scheme. The checked-in public configuration points to https://pal-jade.vercel.app. Sign in with Apple, create a group with a name and optional photo, then invite a second member using its QR code or shareable link. Pasted invite links and codes remain available. Kardomo developer team: 6GAAMYMS72. App: com.pal.spike. Share extension: com.pal.spike.Share.

## Flow

Pal appears first in the chat list as your private conversation. Ask about recent messages, places or plans across your current groups without an @ mention. Its cross-group tool reads bounded, source-dated context only; shared conversations cannot use it, and private replies do not change or post into another group. The app opens with the cloud mascot and a brief native fade, skipped with Reduce Motion.

Share a restaurant reel or paste a URL. Pal inspects accessible content and saves verified places to the group map, asking about uncertain branches. Chat uses text, short paragraphs and inline emphasis; polls and message cards are omitted. Pal can greet, join relevant banter and help arrange an outing without an @ mention, while leaving room for members. It remembers explicit preferences and dated availability quietly. Plans remain drafts until a member confirms them, and attendance stays separate. A member completes any external booking.

Confirmed plans schedule future 24-hour and 2-hour attendance reminders. Changes reset affected RSVPs and replace superseded reminders and Google event copies. The server posts reminder messages and sends APNs independently of the app. Notification taps open the relevant group card.

The composer's plus button offers Photos, Camera and Audio. Draft attachments can be removed before sending; failed sends preserve their original client identity and file for retry. Accepted responses merge into the message cache before the outbox clears, retaining one bubble identity. Returning to a chat shows cached messages immediately. The inbox warms uncached histories with at most two concurrent requests; an unread history never displays the empty-chat message. Authenticated Supabase Realtime changes invalidate authorized API reads for messages and planning state, with polling as recovery. Uploaded photos are decoded, resized and stripped of camera metadata. Photos and voice messages stay in private storage, with temporary links available only to authenticated group members.

Profile and group avatars open a Camera/Photo Library menu. Profile has an editable name, Google Calendar connection and notification controls. Google uses only the app-created-calendar scope, creates a separate Pal calendar, and receives confirmed plans for members who RSVP Yes. Disconnecting stops updates and revokes credentials; existing Google events remain snapshots. Attending members can also review and save a manual copy through Apple's native Calendar editor. Group details contain members and invitations. Memory, poll creation and agent behavior controls stay out of the demo interface.

Pal's cloud avatar uses the supplied mascot expressions. Each reply retains its server-validated emotion; missing or unknown expressions fall back to the smug face. Visible replies animate from shared frames rendered by the supplied SVG engine, including reopened history. Offscreen/background views and Reduce Motion stay still. Reading messages quietly produces no processing indicator. Accent controls use mascot orange while navigation and toolbar controls stay monochrome.

## Services

- Supabase owns membership, source/place/poll/plan records, idempotent actions, private integration credentials and queues. Row-level security isolates groups.
- Eve runs durable scoped OpenAI turns; every human message is eligible, bursts are coalesced, and an empty structured reply means silence. Group conversations and source-grounded preferences persist in Supabase across jobs. Pal reads recent discussion to follow context and tone; clear responses can record the speaker's own attendance or explicit confirmation of a current draft. Confirmation checks the actual source message, speaker, group, plan version and live job lease. Pal cannot independently confirm, cancel or book a plan for a person.
- Supadata inspects public Instagram/TikTok video content asynchronously. Extraction retains evidence and source metadata. Apple Maps search resolves candidates; uncertain places remain unpinned until corrected. Video prices and claims are distinct from current verified information.
- Safe URL reading checks public DNS, redirects, IP pinning, response size and timeouts. Research prefers official menus and reservation pages; it does not invent table availability.
- Minutely Supabase Cron delivers reminders and recovers jobs. The authenticated dispatch worker processes video inspection, Google Calendar copies, and APNs delivery.

## Development and checks

Use Node 24 and npm ci. Configure the ignored root .env using .env.example, then npm run dev. Set PAL_BASE_URL to the actual backend origin. Provider keys and Google refresh tokens are server-side; the iOS app contains only public client configuration. Keep PAL_INTERNAL_SECRET stable because it encrypts integration credentials. Apple private keys use base64 PEM environment variables.

Run npm test, npm run typecheck, and npm run build. npm run smoke:v1 exercises the deployed v1 flow using ignored demo identities; it creates isolated groups and checks real Eve completion plus closed-client reminder delivery. The historical smoke script targets the original spike. Native build/tests and physical-device setup are in ios/README.md. Migrations and PostgreSQL assertions are in supabase/README.md.

The hackathon account contains three fictional scenarios: Friday dinner, Weekend crew and Lunch break, plus a private Pal summary. Mock character portraits come from Pravatar (https://pravatar.cc/); dialogue is fictional and plans are drafts. The seed resolves actual Apple Maps venues but does not claim current menu prices, table availability or reservations. `scripts/reset-demo.ts` requires the reviewed private manifest and exact authorized account; its private backup and completion receipt remain outside Git. Do not run it for ordinary setup.

On 2026-10-11, the deployed flow inspected the supplied Instagram reel, extracted Tur and five dishes with timestamp evidence, and resolved Tur at 1 W Portal Ave through Apple Maps. A physical iPhone received a server reminder after Pal was terminated; the user confirmed its tap opened the reminder card. Real Google consent and a member's Yes RSVP created exactly one event in their separate Pal calendar. Google's test-mode warning and token lifetime apply until production verification. The full user-story walkthrough and remaining manual checks are in docs/user-flow-review.md.

Member location sharing, automatic bookings, two-way calendar sync, games, image generation, and a personal feed are deferred. Social providers may reject private or inaccessible videos; the original link and manual correction remain available.
