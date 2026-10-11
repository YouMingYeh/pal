# Pal iOS spike

Open `Pal.xcodeproj`, select an iPhone simulator, and run the Pal scheme. No third-party iOS dependencies are needed. The application targets iOS 17 and later.

Create the ignored `Config.local.xcconfig` with the public configuration for your deployment. Xcode configuration files treat two slashes as a comment, so URLs use the empty build-variable separator shown here:

```
SUPABASE_URL = https:/$()/PROJECT.supabase.co
SUPABASE_PUBLISHABLE_KEY = PUBLISHABLE_KEY
PAL_API_URL = https:/$()/BACKEND.vercel.app
```

Use `http:/$()/localhost:3000` for a backend running on the same Mac as the simulator. A physical iPhone needs the deployed HTTPS URL. Never put OpenAI or Supabase service-role keys in this file or in the app.

Create or sign in to two accounts, create a group on one device, and join using its invite code on the other. Send messages normally, or mention `@Pal` to start a task. Email confirmation follows the Supabase project's setting. Sessions are persisted in Keychain and refreshed before expiry.

Chat refreshes every two seconds while foregrounded. The server owns reminder execution, so closing the app does not cancel a reminder; reopening the chat retrieves its delivered message. Remote push notifications require APNs setup and are outside this shell.

Regenerate after changing `project.yml` with `xcodegen generate`. Check with:

```
xcodebuild test -project Pal.xcodeproj -scheme Pal -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.5' CODE_SIGNING_ALLOWED=NO
```
