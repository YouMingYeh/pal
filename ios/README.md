# Pal iOS

Open `Pal.xcodeproj`, select an iPhone simulator, and run the Pal scheme. No third-party iOS dependencies are needed. The application targets iOS 17 and later.

The checked-in `Config.xcconfig` already points to the live Supabase project and `https://pal-jade.vercel.app`. Use the ignored `Config.local.xcconfig` only to override these public values for another deployment. Xcode configuration files treat two slashes as a comment, so URLs use the empty build-variable separator shown here:

```
SUPABASE_URL = https:/$()/PROJECT.supabase.co
SUPABASE_PUBLISHABLE_KEY = PUBLISHABLE_KEY
PAL_API_URL = https:/$()/BACKEND.vercel.app
```

Use `http:/$()/localhost:3000` for a backend running on the same Mac as the simulator. A physical iPhone needs the deployed HTTPS URL. Never put OpenAI or Supabase service-role keys in this file or in the app.

Sign in with Apple, create a group on one device, and join using its invite code on the other. Send messages normally, or mention `@Pal` to start a task. Sessions are persisted in Keychain and refreshed before expiry.

The project uses Kardomo Inc. team `6GAAMYMS72`. The Apple portal capability for `com.pal.spike` and the Supabase Apple provider with this allowed client ID are enabled. A real Apple account completing the token exchange remains unverified. The app sends Apple a SHA-256 nonce and exchanges its identity token plus original nonce with Supabase. The native flow does not need a web OAuth client secret. [Supabase setup](https://supabase.com/docs/guides/auth/social-login/auth-apple) and [Apple entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.applesignin).

The user interface exposes only Sign in with Apple. Email/password authentication remains an internal helper for the opt-in live fixture test, with credentials supplied through an ignored test-run configuration. An existing simulator demo session remains usable while a real Apple account sign-in is checked.

Chat refreshes every two seconds while foregrounded. The server owns reminder execution, so closing the app does not cancel a reminder; reopening the chat retrieves its delivered message. The native app registers APNs tokens after permission is granted, and routes notification taps to a group and its card. Real notification delivery still requires server APNs credentials and device provisioning.

Regenerate after changing `project.yml` with `xcodegen generate`. Check with:

```
xcodebuild test -project Pal.xcodeproj -scheme Pal -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.5' CODE_SIGN_IDENTITY=-
```


The app includes profiles, unread counts, replies, reactions, a persistent message outbox, group polls and memories, a month/day calendar, plan RSVP and reservation status, reminder editing, and a MapKit view of saved places. Place search uses the authenticated backend and saves verified Apple Maps IDs; shared-link cards retain video evidence and offer branch selection. Group-member location tracking is not included.

The embedded Share extension accepts text and web links from the iOS share sheet, lets the signed-in user choose a real group, and closes only after the server accepts the message. The app and extension share the session through `$(AppIdentifierPrefix)com.pal.spike.shared`. The app retains its original Keychain entitlement to migrate existing sessions, without deleting the old session on a failed migration. Enable App Groups (`group.com.pal.spike`), Keychain Sharing, Push Notifications, and Associated Domains for the app, and App Groups plus Keychain Sharing for `com.pal.spike.Share`, then refresh provisioning profiles. Root deployment owns this portal setup.

Invite URLs open `pal://join?code=…` or the associated `https://pal-jade.vercel.app/join?code=…`; an invite received while signed out is retained until sign-in succeeds. Google Calendar connects through the server OAuth URL in `ASWebAuthenticationSession`; disconnect stops updates and preserves existing calendar snapshots.

Ad-hoc simulator builds and app-hosted tests cover model decoding, Apple nonce checks, session expiry, outbox identity, and opt-in live group reads. Physical-device Apple sign-in, APNs delivery, Google authorization, and the system-hosted Share extension require their external services and are not implied by a successful simulator build.
