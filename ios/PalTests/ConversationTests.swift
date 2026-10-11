import XCTest
import SwiftUI
@testable import Pal

final class ConversationTests: XCTestCase {
    func testHangoutIdeasMergeDuplicatePlaceSourcesAndKeepUninspectedLinksAndActivities() {
        let placeID = UUID(), firstSourceID = UUID(), secondSourceID = UUID(), pendingID = UUID(), member = UUID()
        let place = GroupPlace(id: placeID, name: "Cafe", address: "Mission", provider: "apple", status: "resolved", candidates: [], contributors: [PlaceContributor(userID: member, sourceID: secondSourceID)])
        let first = GroupSource(id: firstSourceID, url: "https://www.instagram.com/reel/first", title: "Cafe reel", status: "resolved", placeID: placeID, metadata: ["thumbnail_url": .string("https://example.com/cafe.jpg")])
        let second = GroupSource(id: secondSourceID, url: "https://www.tiktok.com/@cafe/video/second", status: "resolved")
        let pending = GroupSource(id: pendingID, url: "https://www.instagram.com/reel/pending", status: "pending")
        var state = GroupState.empty
        state.places = [place]
        state.sources = [first, second, pending]
        state.polls = [GroupPoll(id: UUID(), kind: "place", question: "Weekend ideas", options: [PollOption(id: "saved", label: "Cafe", placeID: placeID), PollOption(id: "walk", label: "A beach walk"), PollOption(id: "duplicate", label: "a beach walk")], status: "open", votes: [])]
        let ideas = HangoutIdea.saved(in: state)
        XCTAssertEqual(ideas.count, 3)
        let cafe = ideas.first { $0.place?.id == placeID }
        XCTAssertEqual(cafe?.sources.map(\.id), [firstSourceID, secondSourceID], "One place retains both original links, including contributor-linked sources.")
        XCTAssertEqual(cafe?.thumbnail?.absoluteString, "https://example.com/cafe.jpg")
        XCTAssertTrue(ideas.contains { $0.sources.first?.id == pendingID }, "A pending link is still browsable before extraction completes.")
        XCTAssertEqual(ideas.filter { $0.sources.isEmpty && $0.place == nil }.map(\.title), ["A beach walk"])
        XCTAssertTrue(HangoutIdea.saved(in: .empty).isEmpty)
    }

    func testBareMentionListsAllOtherMembersAndTypingNarrowsTheSameList() throws {
        let owner = UUID(), amy = UUID(), ben = UUID(), ronny = UUID()
        let members = [GroupMember(userID: owner, displayName: "Me"), GroupMember(userID: amy, displayName: "Amy Chen"), GroupMember(userID: ben, displayName: "Ben"), GroupMember(userID: ronny, displayName: "Ronny Yen")]
        let bare = try XCTUnwrap(PalMentions.query(in: "Hey @"))
        XCTAssertEqual(PalMentions.candidates(in: members, query: bare, excluding: owner).map(\.userID), [amy, ben, ronny])
        XCTAssertEqual(PalMentions.candidates(in: members, query: "yEn", excluding: owner).map(\.userID), [ronny])
        XCTAssertTrue(PalMentions.candidates(in: [], query: bare, excluding: owner).isEmpty)
    }
    func testProcessedReelUsesExtractedVenueAndFoodInsteadOfRawURL() throws {
        let sourceJSON: [String: Any] = ["id": UUID().uuidString, "url": "https://www.instagram.com/reel/abc", "title": "You have to try this", "status": "needs_confirmation", "candidates": [["name": "Cafe Luna", "city": "San Francisco", "dishes": ["Mushroom toast"], "prices": ["$14"], "evidence": ["Cafe Luna appears on screen"]]]]
        let source = try JSONDecoder().decode(GroupSource.self, from: JSONSerialization.data(withJSONObject: sourceJSON))
        var state = GroupState.empty
        state.sources = [source]
        let idea = try XCTUnwrap(HangoutIdea.saved(in: state).first)
        XCTAssertEqual(idea.title, "Cafe Luna")
        XCTAssertEqual(idea.subtitle, "San Francisco · Mushroom toast")
        XCTAssertEqual(idea.sources.first?.url, "https://www.instagram.com/reel/abc", "The original remains provenance in the details.")
        XCTAssertEqual(idea.sources.first?.candidates?.first?.evidence, ["Cafe Luna appears on screen"])
    }

    func testMentionsCompleteNamesAndDiscardEditedTargets() {
        let amy = MessageMention(type: "user", userID: UUID())
        let pal = MessageMention(type: "pal")
        XCTAssertEqual(PalMentions.query(in: "Dinner with @Am"), "Am")
        XCTAssertEqual(PalMentions.inserting(name: "Amy Chen", into: "Dinner with @Am"), "Dinner with @Amy Chen ")
        XCTAssertNil(PalMentions.query(in: "@Amy Chen "), "Selecting a name closes the suggestion row.")
        XCTAssertNil(PalMentions.query(in: "amy@example.com"))
        XCTAssertNil(PalMentions.query(in: "@Amy\nnext line"))
        XCTAssertEqual(Set(PalMentions.retained([amy: "Amy Chen", pal: "Pal"], in: "@Amy Chen, @Pal what works?")), Set([amy, pal]))
        XCTAssertEqual(PalMentions.retained([amy: "Amy Chen"], in: "@Amy Chennington is someone else"), [])
        XCTAssertEqual(PalMentions.retained([amy: "Amy Chen"], in: "I deleted the mention"), [])
    }

    func testReplyAndMentionMetadataSurviveMessageDecoding() throws {
        let group = UUID(), target = UUID(), member = UUID()
        let json: [String: Any] = ["id": UUID().uuidString, "group_id": group.uuidString, "role": "pal", "body": "@Amy Friday it is.", "created_at": "2026-10-11T20:00:00Z", "reply_to_id": target.uuidString,
            "mentions": [["type": "user", "user_id": member.uuidString]],
            "reply": ["id": target.uuidString, "sender_id": member.uuidString, "role": "user", "body": "Friday works."]]
        let message = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(message.reply?.body, "Friday works.", "An old source outside the latest message window remains readable.")
        XCTAssertEqual(message.replyToID, target)
        XCTAssertEqual(message.mentions, [MessageMention(type: "user", userID: member)])
        let text = PalText.linked(message.body, mentions: message.mentions, members: [GroupMember(userID: member, displayName: "Amy")])
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    func testOldOutboxStillDecodesAndKeepsReplyIdentity() throws {
        let group = UUID(), user = UUID(), client = UUID(), reply = UUID()
        let value: [String: Any] = ["groupID": group.uuidString, "userID": user.uuidString, "clientID": client.uuidString, "body": "Yes", "replyToID": reply.uuidString, "failed": true]
        let item = try JSONDecoder().decode(OutgoingMessage.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(item.mentions)
        XCTAssertEqual(item.clientID, client)
        XCTAssertEqual(item.replyToID, reply)
    }

    func testRSVPUsesConfirmedFuturePlansAndSeparateResponses() {
        let now = Date(timeIntervalSince1970: 1000), member = UUID()
        var plan = GroupPlan(id: UUID(), title: "Dinner", startsAt: PalDate.iso(now.addingTimeInterval(3600)), status: "draft", attendees: [])
        XCTAssertFalse(plan.canRSVP(now: now))
        plan.status = "confirmed"
        XCTAssertTrue(plan.canRSVP(now: now))
        XCTAssertNil(plan.response(for: member), "Confirmation does not imply attendance.")
        plan.attendees = [PlanAttendee(userID: member, status: "maybe")]
        XCTAssertEqual(plan.response(for: member), "maybe")
        XCTAssertEqual(plan.attendanceSummary(memberCount: 3), "0 going · 1 maybe · 2 awaiting reply")
        XCTAssertFalse(plan.canRSVP(now: now.addingTimeInterval(3600)))
        plan.status = "cancelled"
        XCTAssertFalse(plan.canRSVP(now: now))
    }

    func testRSVPCardDoesNotDuplicatePlanDetailsIntoText() throws {
        let json: [String: Any] = ["id": UUID().uuidString, "group_id": UUID().uuidString, "role": "pal", "body": "Dinner has a date. Who’s in?", "created_at": "2026-10-11T20:00:00Z", "cards": [["type": "rsvp", "entity_id": UUID().uuidString]]]
        let message = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(message.cards.first?.type, "rsvp")
        XCTAssertEqual(message.plainBody(in: .empty), message.body)
        XCTAssertTrue(message.mentions.isEmpty)
    }
    func testRichCardsRenderRecordsWithoutDuplicatingTheirTitles() throws {
        let plan = GroupPlan(id: UUID(), title: "Friday dinner", status: "draft", attendees: [])
        let poll = GroupPoll(id: UUID(), kind: "place", question: "What sounds good?", options: [], status: "open", votes: [])
        var state = GroupState.empty; state.plans = [plan]; state.polls = [poll]
        for (type, entityID, title) in [("plan", plan.id, plan.title), ("rsvp", plan.id, plan.title), ("options", poll.id, poll.question), ("choice", poll.id, poll.question), ("availability", poll.id, poll.question)] {
            let json: [String: Any] = ["id": UUID().uuidString, "group_id": UUID().uuidString, "role": "pal", "body": title, "created_at": "2026-10-11T20:00:00Z", "cards": [["type": type, "entity_id": entityID.uuidString]]]
            let message = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(message.plainBody(in: state), "The native card already displays its title.")
            XCTAssertEqual(message.plainBody(in: .empty), title, "An unavailable record preserves the original readable message.")
        }
    }

    func testAvailabilityKeepsUnknownDifferentFromExplicitNone() {
        let amy = UUID(), ben = UUID(), unknown = UUID()
        var poll = GroupPoll(id: UUID(), kind: "time", question: "When?", options: [PollOption(id: "fri", label: "Friday after seven"), PollOption(id: "sat", label: "Saturday lunch")], status: "open", votes: [], responses: [PollResponse(userID: amy, optionIDs: ["fri", "sat"]), PollResponse(userID: ben, optionIDs: [])])
        XCTAssertEqual(poll.availability(for: amy), "Friday after seven · Saturday lunch")
        XCTAssertEqual(poll.availability(for: ben), "None of these times")
        XCTAssertNil(poll.availability(for: unknown))
        poll.responses = nil; poll.votes = [PollVote(userID: amy, optionID: "fri")]
        XCTAssertEqual(poll.availability(for: amy), "Friday after seven", "Legacy vote records remain readable.")
        XCTAssertNil(poll.availability(for: ben))
    }

    func testScheduleUsesOnlyCurrentSpeakerScopedAvailability() {
        let now = Date(timeIntervalSince1970: 1000), member = UUID()
        var memory = GroupMemory(id: UUID(), userID: member, kind: "availability", key: "Friday", value: "After seven", expiresAt: PalDate.iso(now.addingTimeInterval(60)))
        XCTAssertTrue(memory.isCurrentAvailability(for: member, now: now))
        XCTAssertFalse(memory.isCurrentAvailability(for: UUID(), now: now))
        XCTAssertFalse(memory.isCurrentAvailability(for: member, now: now.addingTimeInterval(60)))
        memory.expiresAt = nil
        XCTAssertFalse(memory.isCurrentAvailability(for: member, now: now))
        memory.kind = "preference"; memory.expiresAt = PalDate.iso(now.addingTimeInterval(60))
        XCTAssertFalse(memory.isCurrentAvailability(for: member, now: now))
        let plan = GroupPlan(id: UUID(), title: "Dinner", status: "confirmed", attendees: [PlanAttendee(userID: member, status: "declined")])
        XCTAssertEqual(plan.attendanceSummary(memberCount: 2), "0 going · 1 not going · 1 awaiting reply")
    }

    func testRSVPPromptReflectsTheMembersOwnResponse() {
        XCTAssertEqual(RSVPButtons.prompt(for: nil), "Are you coming?")
        XCTAssertEqual(RSVPButtons.prompt(for: "going"), "You’re going")
        XCTAssertEqual(RSVPButtons.prompt(for: "maybe"), "Maybe")
        XCTAssertEqual(RSVPButtons.prompt(for: "declined"), "You can’t go")
    }

    private func transcriptMessage(group: UUID, sender: UUID, id: UUID = UUID(), client: UUID? = nil, at: String, role: String = "user") throws -> ChatMessage {
        var json: [String: Any] = ["id": id.uuidString, "group_id": group.uuidString, "sender_id": sender.uuidString, "role": role, "body": "Hello", "created_at": at]
        if let client { json["client_id"] = client.uuidString }
        return try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testTranscriptKeepsOptimisticIdentityWhenAcknowledged() throws {
        let group = UUID(), sender = UUID(), client = UUID()
        let pending = OutgoingMessage(groupID: group, userID: sender, clientID: client, body: "Hello", failed: false, createdAt: "2026-10-11T20:00:00Z")
        let before = ChatTranscriptRow.prepare(messages: [], pending: [pending])
        let sent = try transcriptMessage(group: group, sender: sender, client: client, at: "2026-10-11T20:00:00Z")
        let after = ChatTranscriptRow.prepare(messages: [sent], pending: [pending])
        XCTAssertEqual(before.map(\.id), [client])
        XCTAssertEqual(after.map(\.id), [client], "An acknowledged outbox item occupies the same single row.")
        XCTAssertEqual(after.first?.item.message?.id, sent.id)
    }

    func testTranscriptSeparatorsAndSenderRunsUsePreparedDates() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let group = UUID(), sender = UUID()
        let values = try ["2026-10-11T20:00:00Z", "2026-10-11T20:02:00Z", "2026-10-11T20:06:00Z", "2026-10-12T00:00:00Z"].map { try transcriptMessage(group: group, sender: sender, at: $0) }
        let rows = ChatTranscriptRow.prepare(messages: Array(values.reversed()), pending: [], calendar: calendar)
        XCTAssertEqual(rows.map(\.id), values.map(\.timelineID))
        XCTAssertEqual(rows.map(\.startsDay), [true, false, false, true])
        XCTAssertEqual(rows.map(\.showSender), [true, false, true, true])
        XCTAssertTrue(rows.allSatisfy { $0.date != nil })
    }

    func testTranscriptRetainsLegacyOutboxWithoutCreatingAnInvalidDateSeparator() throws {
        let group = UUID(), sender = UUID()
        let sent = try transcriptMessage(group: group, sender: sender, at: "2026-10-11T20:00:00Z")
        let pending = OutgoingMessage(groupID: group, userID: sender, clientID: UUID(), body: "Retry", failed: true)
        let rows = ChatTranscriptRow.prepare(messages: [sent], pending: [pending])
        XCTAssertEqual(rows.last?.id, pending.id)
        XCTAssertNil(rows.last?.date)
        XCTAssertFalse(rows.last?.startsDay ?? true)
    }

    func testTranscriptCacheInvalidatesSameIDEditsAndRetryState() throws {
        let group = UUID(), sender = UUID(), id = UUID()
        let first = try transcriptMessage(group: group, sender: sender, id: id, at: "2026-10-11T20:00:00Z")
        let edited = try transcriptMessage(group: group, sender: sender, id: id, at: "2026-10-11T20:00:01Z")
        let source = ChatTranscriptSource(messages: [first], pending: [])
        XCTAssertEqual(source, ChatTranscriptSource(messages: [first], pending: []))
        XCTAssertNotEqual(source, ChatTranscriptSource(messages: [edited], pending: []), "Equal IDs do not hide an authoritative message update.")
        var pending = OutgoingMessage(groupID: group, userID: sender, clientID: UUID(), body: "Retry", failed: false)
        let before = ChatTranscriptSource(messages: [first], pending: [pending])
        pending.failed = true
        XCTAssertNotEqual(before, ChatTranscriptSource(messages: [first], pending: [pending]))
        XCTAssertNotEqual(source, ChatTranscriptSource(messages: [], pending: []), "Logout and authoritative cleared history drop cached transcript rows.")
    }

    @MainActor func testReadOnlyInspirationAndPlanControlsExpandForAccessibleText() {
        let option = PollOption(id: "one", label: "Dinner and a walk by the waterfront with the whole group")
        let normal = UIHostingController(rootView: InspirationTile(option: option, place: nil, thumbnail: nil).environment(\.dynamicTypeSize, .large))
        let large = UIHostingController(rootView: InspirationTile(option: option, place: nil, thumbnail: nil).environment(\.dynamicTypeSize, .accessibility3))
        let bounds = CGSize(width: 300, height: 10000)
        let normalSize = normal.sizeThatFits(in: bounds), largeSize = large.sizeThatFits(in: bounds)
        XCTAssertGreaterThan(normalSize.height, 40)
        XCTAssertGreaterThan(largeSize.height, normalSize.height, "Inspiration grows rather than clipping accessible text.")
        XCTAssertLessThanOrEqual(largeSize.width, 260.5, "The carousel tile stays inside the message width.")
        let normalRSVP = UIHostingController(rootView: RSVPButtons(selected: "going", busy: false, action: { _ in }).environment(\.dynamicTypeSize, .large))
        let largeRSVP = UIHostingController(rootView: RSVPButtons(selected: "going", busy: false, action: { _ in }).environment(\.dynamicTypeSize, .accessibility3))
        XCTAssertGreaterThan(largeRSVP.sizeThatFits(in: bounds).height, normalRSVP.sizeThatFits(in: bounds).height, "RSVP buttons stack at accessible text sizes.")
    }
    func testInlineQuestionKeepsScopeAndQuotedMessageIdentitySeparate() throws {
        let groupID = UUID(), sourceID = UUID()
        let question = "Friday or Saturday?"
        let json: [String: Any] = ["id": sourceID.uuidString, "group_id": groupID.uuidString, "role": "pal", "body": question, "created_at": "2026-10-11T20:00:00Z", "cards": [["type": "question", "entity_id": groupID.uuidString, "question": question, "suggestions": ["Friday", "Saturday", "Either works"]]]]
        let message = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
        let card = try XCTUnwrap(message.cards.first)
        XCTAssertEqual(card.questionText(for: groupID), question)
        XCTAssertEqual(card.suggestedAnswers, ["Friday", "Saturday", "Either works"])
        XCTAssertNotEqual(message.id, card.entityID, "Answer replies use the delivered message ID, not the group scope UUID.")
        XCTAssertNil(message.plainBody(in: .empty), "The question appears once in its card.")
        let roundTrip = try JSONDecoder().decode(MessageCard.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(roundTrip, card)
        XCTAssertNil(card.questionText(for: UUID()), "A question from another group does not render.")
    }

    func testQuestionSuggestionsValidateBoundsAndRetainOrdinaryTextFallback() throws {
        let groupID = UUID()
        var card = MessageCard(type: "question", entityID: groupID, question: " Dinner? ", suggestions: [" Yes ", "No"])
        XCTAssertEqual(card.questionText(for: groupID), "Dinner?")
        XCTAssertEqual(card.suggestedAnswers, ["Yes", "No"])
        for suggestions in [["Yes"], ["Yes", "Yes"], ["Yes", "YES"], ["Yes", " "], ["Yes", String(repeating: "x", count: 61)], ["1", "2", "3", "4", "5"]] {
            card.suggestions = suggestions
            XCTAssertNil(card.questionText(for: groupID))
        }
        card.suggestions = ["Yes", "No"]; card.question = String(repeating: "x", count: 201)
        XCTAssertNil(card.questionText(for: groupID))
        let json: [String: Any] = ["id": UUID().uuidString, "group_id": groupID.uuidString, "role": "pal", "body": "Dinner?", "created_at": "2026-10-11T20:00:00Z", "cards": [["type": "question", "entity_id": groupID.uuidString, "question": "Dinner?", "suggestions": ["Yes"]]]]
        let message = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(message.plainBody(in: .empty), "Dinner?", "An unsupported card never removes its readable message.")
        let legacy = try JSONDecoder().decode(MessageCard.self, from: JSONSerialization.data(withJSONObject: ["type": "plan", "entity_id": UUID().uuidString]))
        XCTAssertNil(legacy.question)
        XCTAssertNil(legacy.suggestions)
    }

    @MainActor func testSuggestedAnswerChipsExpandForAccessibleText() throws {
        let groupID = UUID()
        let group = try JSONDecoder().decode(ChatGroup.self, from: JSONSerialization.data(withJSONObject: ["id": groupID.uuidString, "name": "Dinner"]))
        let card = MessageCard(type: "question", entityID: groupID, question: "What kind of dinner sounds good?", suggestions: ["Korean barbecue", "Italian", "Vegetarian", "Anything works"])
        let store = PalStore(), source = UUID()
        let normal = UIHostingController(rootView: QuestionCardView(group: group, card: card, sourceMessageID: source).environmentObject(store).environment(\.dynamicTypeSize, .large))
        let large = UIHostingController(rootView: QuestionCardView(group: group, card: card, sourceMessageID: source).environmentObject(store).environment(\.dynamicTypeSize, .accessibility3))
        let bounds = CGSize(width: 270, height: 10000)
        let normalSize = normal.sizeThatFits(in: bounds), largeSize = large.sizeThatFits(in: bounds)
        XCTAssertGreaterThan(normalSize.height, 80)
        XCTAssertGreaterThan(largeSize.height, normalSize.height, "Question and answer text wraps instead of clipping.")
        XCTAssertLessThanOrEqual(largeSize.width, 270.5)
    }

}
