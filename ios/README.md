# Pal iOS

Open `Pal.xcodeproj`, select an iPhone simulator, and run the Pal scheme. Xcode resolves Kingfisher 8.13.0 through Swift Package Manager. The application targets iOS 17 and later.

The checked-in `Config.xcconfig` already points to the live Supabase project and `https://pal-jade.vercel.app`. Use the ignored `Config.local.xcconfig` only to override these public values for another deployment. Xcode configuration files treat two slashes as a comment, so URLs use the empty build-variable separator shown here:

```
SUPABASE_URL = https:/$()/PROJECT.supabase.co
SUPABASE_PUBLISHABLE_KEY = PUBLISHABLE_KEY
PAL_API_URL = https:/$()/BACKEND.vercel.app
```

Use `http:/$()/localhost:3000` for a backend running on the same Mac as the simulator. A physical iPhone needs the deployed HTTPS URL. Never put OpenAI or Supabase service-role keys in this file or in the app.

Sign in with Apple, create a group on one device, and join using its invite code on the other. Send messages normally, or mention `@Pal` to start a task. Sessions are persisted in Keychain and refreshed before expiry.

The project uses Kardomo Inc. team `6GAAMYMS72`. The Apple portal capability for `com.pal.spike` and the Supabase Apple provider with this allowed client ID are enabled. A real Apple account completed the native token exchange on the connected physical iPhone. The app sends Apple a SHA-256 nonce and exchanges its identity token plus original nonce with Supabase. The native flow does not need a web OAuth client secret. [Supabase setup](https://supabase.com/docs/guides/auth/social-login/auth-apple) and [Apple entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.applesignin).

The user interface exposes only Sign in with Apple. Email/password authentication remains an internal helper for the opt-in live fixture test, with credentials supplied through an ignored test-run configuration. An existing simulator demo session remains usable while a real Apple account sign-in is checked.

Authenticated Realtime refreshes group messages and shared state while foregrounded, with two-second polling as recovery. The server owns reminder execution, so closing the app does not cancel a reminder; reopening the chat retrieves its delivered message. The native app registers APNs tokens after permission is granted, and routes notification taps to a group and its card. The connected iPhone received a real sandbox reminder while Pal was closed, and its notification opened the correct group.

Regenerate after changing `project.yml` with `xcodegen generate`. Check with:

```
xcodebuild test -project Pal.xcodeproj -scheme Pal -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.5' CODE_SIGN_IDENTITY=-
```


The app includes profiles, unread counts, replies, reactions, a persistent message outbox, a month/day calendar, plan RSVP and reservation status, reminder editing, and a MapKit view of saved places. Pal remembers explicit group context through server tools; manual memory and poll interfaces are hidden. Place search uses the authenticated backend and saves verified Apple Maps IDs; chat describes shared-link results in text while the persisted source retains evidence. Group-member location tracking is not included.

The embedded Share extension accepts text and web links from the iOS share sheet, lets the signed-in user choose a real group, and closes only after the server accepts the message. The app and extension share the session through `$(AppIdentifierPrefix)com.pal.spike.shared`. The app retains its original Keychain entitlement to migrate existing sessions, without deleting the old session on a failed migration. Enable App Groups (`group.com.pal.spike`), Keychain Sharing, Push Notifications, and Associated Domains for the app, and App Groups plus Keychain Sharing for `com.pal.spike.Share`, then refresh provisioning profiles. Root deployment owns this portal setup.

Invite URLs open `pal://join?code=…` or the associated `https://pal-jade.vercel.app/join?code=…`; an invite received while signed out is retained until sign-in succeeds. Google Calendar connects through the server OAuth URL in `ASWebAuthenticationSession`; disconnect stops updates and preserves existing calendar snapshots. Native Google authorization and the first own-RSVP event sync succeeded on the physical iPhone.

Add to Calendar opens Apple’s native event editor for a confirmed plan you RSVP Going to. It requests no calendar-read permission. Saving makes a manual Calendar copy; changes in Pal do not update or remove that copy. A local receipt records only the editor’s explicit Saved result, scoped to the signed-in user and plan version, to avoid offering repeated copies. A changed plan tells the user to update its existing Calendar copy. The event’s Pal URL returns to the group and plan after membership validation. Apple Calendar’s actual save is still awaiting physical-device verification.

Ad-hoc simulator builds and app-hosted tests cover model decoding, Apple nonce checks, session expiry, outbox identity, reminder ownership, notification permission gates, explicit unavailable poll responses, and opt-in live group reads. Google authorization and the system-hosted Share extension require their external services and are not implied by a successful simulator build.

Chat has a floating native Liquid Glass composer and soft scroll edges on iOS 26 or later, individual material controls on older systems, and an opaque accessible fallback when Reduce Transparency is enabled. Message timestamps appear only at day separators. Long press a bubble for a reaction palette, Reply, or Copy; Calendar and Map push onto the chat’s navigation stack with standard back navigation. Joining a pasted invite link or creating a group opens its chat immediately. Notification permission is requested through an explicit Enable notifications action, and notification preference changes persist immediately.

A physical Debug build is signed with the Kardomo team and installed on the connected iPhone. APNs uses the sandbox environment in Debug and production in Release. The app retries registration only with existing iOS authorization, deduplicates successful token registrations, and keeps any registration issue inline in Profile rather than interrupting navigation.

The composer supports one photo or AAC voice message, with a preview before sending and durable retry using the original bytes and client ID. Audio recordings stop at 59 seconds. Files remain private; authorized group members receive expiring signed URLs. Group creation can save a shared photo atomically, and joining supports QR scanning or a pasted invite. Profile and group avatar menus offer Camera or Photo Library.

Pal uses the supplied orange cloud expressions, with `fier` as the default. Manual group settings and memory/poll creation controls are omitted from the demo. Existing plans and places remain available in Calendar and Map.

The private Pal room appears first in Chats and reuses the chat composer without group invite, Map, or Calendar controls. The server owns the private room and its authorized context. A static cloud launch screen transitions with a brief native fade while normal loading proceeds; Reduce Motion skips that transition.

Chat is text-first, with persisted plan, options, and availability cards for shared decisions. Older place/reminder cards keep readable text fallbacks. Chat-list loading prefetches messages, member names, group state and photos for at most two groups at once; the empty-state label waits for a confirmed server response. Messages are cached across navigation and reconciled by their client UUID before durable drafts are removed. Authenticated Supabase Realtime invalidates the authorized API cache for messages and shared state; two-second chat and fifteen-second list refreshes remain a fallback. A fixed-height composer status lane shows “Pal is typing…” during the immediate own send and actual bounded accepted/running jobs, without shifting transcript bubbles. First post-ack state reads replace the optimistic status; failure, pause, completion or expiry end it.

Every visible Pal reply animates its stored emotion using shared native frames sampled from the supplied engine and its original emotion-specific body movements. Offscreen, background and Reduce Motion avatars are still. Twelve cached emotions use at most approximately 108 MiB of decoded frames; 64 unique 192-pixel frames remain sharper than the 162 pixels needed for the 36-point chat avatar on a 3× display. Native playback uses the same frames forward and backward at 16 fps, avoiding a hard pose reset. Static fallback assets are 512 pixels for larger launch and login avatars. Private Pal chat is pinned above groups, and launch uses the same static mascot with a short native entrance.

Conversation updates use account-bound shared reads and retained per-screen state. Errors keep cached content visible and offer retry; cold views distinguish loading from confirmed empty results. Avatar images use Kingfisher with a bounded account-scoped memory cache, signed-path cache keys, and separate downsampled sizes for avatars and chat photos. Private images are not cached to disk; changing accounts clears and rotates the memory cache. Photo frames keep their dimensions while loading. Type @ for member/Pal completion and use a message’s Reply menu for quotes. Pal may send up to three intentional replies with independent emotions. Plan cards expose shared attendance and RSVP after confirmation; options show saved places or activity ideas; availability combines explicit dated statements and members’ slot responses without treating silence as availability. The month calendar supports swiping and accessible previous/next controls.

Group quick actions ask Pal for Plans, Schedule or Hangout; private chat offers Summary and Plans across current memberships. Emoji controls reuse native Liquid Glass with the same older-system and Reduce Transparency fallbacks as the composer. Tapping a member opens a group-scoped AI summary with cited chat context, explicit schedule and upcoming attending plans. Cache-first views retain content during refresh; a cold launch still requires an authenticated network read. Brand and contrast variants live in PalTheme; screens use system semantic surfaces and text roles.
