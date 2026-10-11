# Pal: five-minute demo and product flow

This is the proposed experience, grounded in the current build. The expanded story is being discussed before further implementation. Fictional dialogue and staged participants are demo data; provider results must remain factual.

## Decisions agreed with the founder

- Real restaurant research and official reservation pages; a person completes the booking and records the result. No invented live tables or automated reservation claims.
- Conversation first. Pal may ask a short question or open a small choice/Yes–No poll when a decision helps. Inspiration, a question response, and attendance are distinct.
- Private Pal reads and summarizes other current groups. It never sends messages or changes their plans on the user's behalf. A source link opens the original group/invitation for the user's own action.
- Shared links are inspected in the background and become processed Hangout Ideas, with extracted facts, real previews when available, original sources and uncertainty. They are not merely bookmarks.
- Preserve a short, witty, useful voice. Tease procrastination, not a budget, restriction or emotional difficulty.

## One story

A friend group has already shared places and discussed preferences. Pal brings that context back, helps settle one dinner, and leaves each person with a clear next action. The result is one real shared plan, rather than another conversation somebody must manage.

### 0:00–0:35 — Show the coordination problem

Open a group containing explicitly staged conversation and previously inspected real links. Do not spend stage time signing in or creating the group.

Presenter:
> “The ideas are already here. What usually happens next is one person rereading the chat, finding the links, asking everyone when they’re free, and chasing replies. Pal takes on that coordination work.”

Show differing availability, a vegetarian preference and a budget in ordinary messages. Do not invent a minutes-saved statistic or unread-message count.

### 0:35–1:15 — Pal steps in without a command

A member writes:
> “We should actually get dinner together Friday.”

Pal responds naturally, with its own animated expression, then asks one missing question. Use the real generated wording; examples are direction, not guaranteed model output:
> “The restaurant collection is ready for its first field trip.”
> “Friday after seven, or would Saturday be easier?”

Show suggested responses and one member typing a custom answer. Keep conversation going while the agent works; the current live checks took approximately 12–16 seconds for useful multi-step turns. Do not describe generation as instantaneous.

This proves selective participation in a new planning idea. Weekly unsolicited suggestions are a separate behavior and are not proven by this live exchange.

### 1:15–2:00 — Recover and use shared ideas

Tap Hangout or the toolbar collection. Show a processed venue, useful extracted details, a real source preview if available, and the original link. Show an uncertain branch honestly if that is the selected fixture.

A member asks:
> “Which of these works for our budget and Amy’s vegetarian options?”

Pal uses explicit shared preferences and stated availability. Opted-in foreground locations may support a nearby search; missing or stale locations stay unknown. Do not claim live travel times or menu facts that were not actually checked.

Presenter:
> “Pal brings back what we shared before and applies what we’ve said now. Nobody has to dig through a month of links.”

### 2:00–2:55 — Settle the decision and handle a change

Use conversation and the current suggested-answer question to settle one venue. A future true poll can show each member’s latest choice; do not present the current question shortcuts as an implemented vote tally.

Open the actual verified booking page before presenting reservation-dependent choices. A human checks the table; if no table is available or the venue is walk-in only, use the genuine result and a saved alternative.

One member writes:
> “I might not make seven thirty. Could we do eight?”

Pal proposes a revised time and asks for confirmation. Availability is not attendance, and silence is not agreement. Avoid a live edit of an already confirmed plan unless the renewed-RSVP path is part of the rehearsal.

### 2:55–3:50 — Show a completed arrangement

Show a draft with the actual venue and future time. A person confirms the plan. Pal tags the members and asks for RSVP; each person controls their own Yes, Maybe or No.

The compact chat card shows where, when and RSVP. Tap it for attendance and reservation details. Confirming a plan does not mean a table has been booked.

If the presenter actually completed a reservation, record that real confirmation. Otherwise say that the shared plan is confirmed and the reservation remains to be completed. Never enter a fabricated confirmation number as a real booking.

Pal can say after the plan operation succeeds:
> “‘We should go sometime’ finally has a date.”

Show the separate Google Pal calendar only for an attending, connected member after actual sync. Apple Calendar opens a native review-and-save editor for a manual copy. Do not label a preview as a completed sync.

### 3:50–4:30 — Personal help, with a clear boundary

Tap Pal’s avatar to open the private conversation. Ask:
> “What do I need to do across my groups?”

Show the real group-scoped summary and an unresolved action if one exists. Explain that summaries cover the returned context and can fetch more; never claim 1,284 messages were read unless a real exhaustive read establishes that number.

Presenter:
> “In private, Pal helps me catch up and find what needs me. My private conversation stays private. I go back to the original invitation to reply.”

Proactive per-person private RSVP outreach and direct source navigation are next-stage work, not established by a normal private summary. A closed-app server reminder and notification opening the correct group have previously been verified; a fresh notification test is optional after rehearsal.

### 4:30–5:00 — Explain execution and next evidence

Presenter:
> “This is a native iOS app. Supabase keeps the shared conversation and state synchronized. Eve and OpenAI run the agent and its tools. Inspection and reminder jobs continue on the server when the app closes.”

> “We’re starting with small friend groups that already share places and organize regular meetups. Next we’ll test whether more of those ideas turn into confirmed plans, and measure the coordination time and messages people actually save.”

Use real measurements collected with consent: time to a confirmed plan, unresolved responses, organizer actions, corrections, and unnecessary nudges. No retention, market size or time-saving numbers are established yet.

## State and interaction rules

| State | What the member sees | What Pal may do | Confirmation needed |
|---|---|---|---|
| Shared idea being inspected | Original message; processing status only inside Ideas | Inspect silently and preserve the source | None to read a shared public link |
| Processed idea | Meaningful venue/activity, source preview/details; uncertainty if needed | Explain the result and recommend relevant options | Correct unclear locations before claiming resolution |
| Discussion | Short messages, optional question suggestions | Remember explicit preferences; ask one missing question | No inferred RSVP or agreement |
| Choice, proposed future feature | Small contextual single-choice or Yes–No poll; latest own answer editable | Collect actual responses and nudge missing members within a defined deadline | Never close or decide by treating silence as consent |
| Draft plan | Venue and time; confirmation action | Prepare a concrete proposal, keep unresolved details visible | A member confirms the plan |
| Confirmed plan | Compact invitation and own RSVP; full details on tap | Tag members, record own explicit responses, schedule valid reminders | Each person controls their attendance |
| Reservation | Official booking destination and genuine status | Research accessible options and suggest a fallback | A person completes the booking and records its actual result |
| Changed plan | Clear before/after details | Propose a change, stop superseded reminders after approval | Material changes need confirmation and renewed RSVPs |
| Private catch-up | Relevant actions and original sources | Read current memberships and summarize; personal reminders only in their defined scope | Other-group actions happen in the original group, by the user |

## What is implemented, tested or still proposed

- Implemented: native group/Pal chats, source extraction with retained metadata/evidence, processed Ideas collection, preferences and dated availability, plan/RSVP cards, independent emotion animations, quoted suggested replies, private cross-group reads, selected-group foreground location sharing, Google calendar flow, manual Apple calendar editor, server reminders and APNs.
- Verified earlier on the connected phone: Apple login, Google connection/event lifecycle, closed-app reminder and correct tap destination. Current automated verification covers scoped mutations, quiet link completion, auto-RSVP messages, push coalescing, cache/outbox identity, and new question/Ideas/navigation behavior.
- Current live agent acceptance: resolved friend exchange stays silent, untagged dinner discussion receives a real reply, generated suggestions persist and send a quoted human answer, and the deployed HTTP dispatcher completes.
- Proposed next: a true general-purpose response poll with current member choices; restrained per-person proactive private reminders; direct original-message/invitation navigation from private catch-up; a polished availability-first recommendation flow. These need flow agreement and implementation, not just revised narration.
- Provider-dependent: accessible Instagram/TikTok inspection, arbitrary X page access, live reservation availability, source images, and browser booking. No universal scraping or live-table guarantee.
- Not claimed: automated booking, Pal sending to other groups from DM, personal calendar availability reads, exhaustive unlimited history, recorded attendance/visit counts, automatic Apple calendar updates, or quantified time saved.

## Rehearsal

Pick one group and one real inspected venue in advance; use the actual names and facts. Check source access, current future dates/timezone, reservation destination, the acting member’s calendar consent and notification permission. Keep an accessible alternative venue. Label the fictional conversation and participants. Rehearse a full plan confirmation and own RSVP once; a failed integration should retain the plan and offer a truthful recovery. Keep the two-minute booking/decision segment within its time box instead of making the audience wait through every extraction or model step.
