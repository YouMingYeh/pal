# Pal v1 flow review

The app opens in Chats. Group content lives in the conversation, Map and Calendar; account connections live in Profile. Cards own decisions, while Pal's short messages add context or personality.

This review covers the approved stories and their recovery paths. Live checks use real accounts/providers; SQL and native tests cover deterministic behavior. It does not imply every gesture was manually exercised on every iOS version.

| Story | Flow and friction removed | Verification |
|---|---|---|
| Sign in and identity | Apple sign-in; a focused editor with a large photo picker, editable name and one Save action. Avatar files stay private and are shared through temporary links with group members. | Physical sign-in/group join; real hosted image upload, metadata removal, member reads, access denial and removal cleanup. |
| Create, invite and join | Name and optional group photo, then Create. Invite with a QR code or link; joining resumes after sign-in. Pasted invites remain a fallback. | Hosted atomic creation/photo/idempotency and access checks; native QR decoding and physical scanning are separate checks. |
| Find a chat | Centered Pal title, profile and new-chat controls; name, latest message and unread count, without row dividers. | Hosted two-member smoke and SQL; native render. |
| Conversation | Adaptive monochrome outgoing/incoming bubbles; grouped sender labels and date/time separators; no timestamp on each bubble. Individual glass controls float above a soft scroll edge. | Native render/tests. |
| Reply and react | Native long-press reaction palette, Reply and Copy. Text URLs are tappable. | Native render and hosted reply/reaction assertions. |
| Failed delivery | No sending indicator. Preserve text, reply, attachment and client identity; failed messages remain retryable. | Hosted text/media idempotency and native outbox tests. |
| Photos and audio | Plus opens Photos, Camera or Audio; review/remove a draft before sending. Private signed media is shared with group members. | Hosted actual JPEG and Apple AAC uploads/downloads, byte-preserving retry, invalid-file rejection and outsider access denial. Hardware camera/microphone checks remain manual. |
| Share a reel | Share extension selects a group and submits through the authenticated message API; pasting uses the same ingestion. | Extension builds/session tests; pasted real reel live. System share gesture remains a manual check. |
| Inspect a place | One source card progresses through inspection, retaining evidence and source link; confirmation resolves a branch. | Real supplied reel: Tur, five dishes and timestamp evidence; Apple Maps match. |
| Unclear/inaccessible source | Choose a candidate or find/add the place manually. Preserve the original link on provider failure. | Schema/security tests and correction flow review. Private-video provider behavior varies. |
| Multiple places | Save individual candidates or all resolved candidates. | Native multi-candidate rendering and validated extraction records. |
| Collection and duplicates | Search saved places or push Map onto the chat navigation stack. One place keeps source contributors. | Hosted dedup, SQL and native state/render. |
| Preferences and context | Pal quietly reads group history and remembers explicit statements about the speaker. Members correct it through chat; no memory editor. | Real Eve preference turn and SQL source/speaker/ownership assertions. |
| Availability | Dated statements expire. Select slots, suggest another time or explicitly choose None work; unanswered stays unknown. | SQL empty-response/nudge tests and native response model tests. |
| Choose a place | Editable votes and Either works; voting never implies attendance. | Hosted poll lifecycle and SQL. |
| Confirm and RSVP | Review a draft; any member confirms; each member separately chooses Yes/Maybe/No. | Hosted lifecycle and actual member Yes RSVP. |
| Reserve | Research verifies a booking link; a member opens it and records a completed booking. Drafts do not imply booked tables. | Real official booking-page verification plus scoped-tool tests. No reservation submitted. |
| Group calendar | Push Calendar, choose a date, review agenda/upcoming/past plans; native back and swipe-back. | Native calendar render/model tests; gesture remains a device check. |
| Google Calendar | Connect once; create a separate Pal calendar; sync only confirmed plans where that member said Yes. | Real consent, exactly one live Google event, and an edited plan updating the same copy despite retries. |
| Apple Calendar | Open Apple's native editor, review and save a manual copy. Pal does not read personal events. | Native editor/date/receipt checks; physical save requires a member action. |
| Follow-ups | Responded members are excluded; remaining reminders stop once resolved. Quiet hours apply to nonurgent pushes. | SQL recipient/deadline assertions. |
| Attendance reminders | Server schedules future 24h/2h reminders for Yes attendees; pushes open the relevant record. | SQL lifecycle plus a physical closed-app reminder/tap check. |
| Changes and cancellation | Update the existing card. Material time changes clear RSVPs and replace reminders/calendar copies. | Hosted reschedule/cancel assertions; Google provider retry/edit/cancel tests. |
| Direct reminder | Ask Pal in chat; scheduling persists on the server. Existing reminder cards retain change/cancel actions. | Native mutation tests and hosted server reminder. |
| Notification control | Explicit Enable requests iOS permission. Background registration failures appear quietly in Profile and do not interrupt navigation. | Physical permission, device registration and APNs delivery; repeated-failure recovery needs the updated native build. |
| Group details | Members and invitations only; agent settings and manual memory/poll creation are hidden. | Native flow review; existing backend guards remain in place. |
| Accessibility | Native text/controls, meaningful action labels, Dynamic Type layouts, light/dark mode and Reduce Transparency fallback. | Native accessible dark rendering and builds. VoiceOver narration and iOS 26 glass on hardware remain manual checks. |

Deferred features remain location sharing, automatic booking, two-way calendar sync, games, image generation and a personal feed. Google's test-mode OAuth warning is expected; its refresh credentials can expire after seven days. The installed Debug app uses sandbox APNs; TestFlight needs production APNs credentials.
