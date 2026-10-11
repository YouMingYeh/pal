import XCTest
@testable import Pal

final class ConversationTests: XCTestCase {
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

}
