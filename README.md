# Pal

Native iOS group chat with Eve/OpenAI, Supabase, saved places, planning cards, reminders, and personal Google Calendar sync.

Open ios/Pal.xcodeproj and run the Pal scheme. The checked-in public configuration points to https://pal-jade.vercel.app. Sign in with Apple, create a group with a name and optional photo, then invite a second member using its QR code or shareable link. Pasted invite links and codes remain available. Kardomo developer team: 6GAAMYMS72. App: com.pal.spike. Share extension: com.pal.spike.Share.

## Flow

Share a restaurant reel or paste a URL. Its source card progresses through inspection and lets members choose a branch or add a place manually. Saved places appear on the group map. Discuss a time; Pal selectively remembers explicit preferences and dated availability and can create polls or a draft plan without an @ mention. A member confirms the plan, and each person RSVPs separately. A member completes any external booking and records its details.

Confirmed plans schedule future 24-hour and 2-hour attendance reminders. Changes reset affected RSVPs and replace superseded reminders and Google event copies. The server posts reminder messages and sends APNs independently of the app. Notification taps open the relevant group card.

The composer's plus button offers Photos, Camera and Audio. Draft attachments can be removed before sending; failed sends preserve their original client identity and file for retry. Uploaded photos are decoded, resized and stripped of camera metadata. Photos and voice messages stay in private storage, with temporary links available only to authenticated group members.

Profile and group avatars open a Camera/Photo Library menu. Profile has an editable name, Google Calendar connection and notification controls. Google uses only the app-created-calendar scope, creates a separate Pal calendar, and receives confirmed plans for members who RSVP Yes. Disconnecting stops updates and revokes credentials; existing Google events remain snapshots. Attending members can also review and save a manual copy through Apple's native Calendar editor. Group details contain members and invitations. Memory, poll creation and agent behavior controls stay out of the demo interface.

Pal's cloud avatar uses the supplied mascot expressions. Each reply retains its server-validated emotion; missing or unknown expressions fall back to the smug face. Actual accepted/running jobs show the focused face, and a fresh reply briefly moves before settling. Historical replies stay still. Only one local player runs; offscreen/background views and Reduce Motion use static artwork. Accent controls use mascot orange while navigation and toolbar controls stay monochrome.

## Services

- Supabase owns membership, source/place/poll/plan records, idempotent actions, private integration credentials and queues. Row-level security isolates groups.
- Eve runs durable scoped OpenAI turns; every human message is eligible, bursts are coalesced, and an empty structured reply means silence. Group conversations and source-grounded preferences persist in Supabase across jobs. Pal reads recent discussion to follow context and tone; clear responses can update the speaker's own vote or RSVP. Agent tools cannot confirm, cancel or book a plan for a person.
- Supadata inspects public Instagram/TikTok video content asynchronously. Extraction retains evidence and source metadata. Apple Maps search resolves candidates; uncertain places remain unpinned until corrected. Video prices and claims are distinct from current verified information.
- Safe URL reading checks public DNS, redirects, IP pinning, response size and timeouts. Research prefers official menus and reservation pages; it does not invent table availability.
- Minutely Supabase Cron delivers reminders and recovers jobs. The authenticated dispatch worker processes video inspection, Google Calendar copies, and APNs delivery.

## Development and checks

Use Node 24 and npm ci. Configure the ignored root .env using .env.example, then npm run dev. Set PAL_BASE_URL to the actual backend origin. Provider keys and Google refresh tokens are server-side; the iOS app contains only public client configuration. Keep PAL_INTERNAL_SECRET stable because it encrypts integration credentials. Apple private keys use base64 PEM environment variables.

Run npm test, npm run typecheck, and npm run build. npm run smoke:v1 exercises the deployed v1 flow using ignored demo identities; it creates isolated groups and checks real Eve completion plus closed-client reminder delivery. The historical smoke script targets the original spike. Native build/tests and physical-device setup are in ios/README.md. Migrations and PostgreSQL assertions are in supabase/README.md.

On 2026-10-11, the deployed flow inspected the supplied Instagram reel, extracted Tur and five dishes with timestamp evidence, and resolved Tur at 1 W Portal Ave through Apple Maps. A physical iPhone received a server reminder after Pal was terminated; the user confirmed its tap opened the reminder card. Real Google consent and a member's Yes RSVP created exactly one event in their separate Pal calendar. Google's test-mode warning and token lifetime apply until production verification. The full user-story walkthrough and remaining manual checks are in docs/user-flow-review.md.

Member location sharing, automatic bookings, two-way calendar sync, games, image generation, and a personal feed are deferred. Social providers may reject private or inaccessible videos; the original link and manual correction remain available.
