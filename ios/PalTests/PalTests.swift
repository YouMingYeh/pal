import XCTest
import SwiftUI
import Security
import UserNotifications
import EventKitUI
import ImageIO
@testable import Pal

final class PalTests: XCTestCase {
    @MainActor func testNavigationCancellationDoesNotPresentFailure() async {
        let store = PalStore()
        store.report(URLError(.cancelled))
        XCTAssertNil(store.error)
        store.report(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertNil(store.error)
        store.report(CancellationError())
        XCTAssertNil(store.error)
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { store.report(error) }
        }
        task.cancel()
        await task.value
        XCTAssertNil(store.error)
        store.report(URLError(.notConnectedToInternet))
        XCTAssertNotNil(store.error)
        XCTAssertFalse(PalCancellation.isCancellation(NSError(domain: "OtherDomain", code: NSURLErrorCancelled)))
        XCTAssertTrue(PalCancellation.isCancellation(URLError(.timedOut), taskCancelled: true))
    }
    func testExpiredPollCannotAcceptVotesEvenBeforeMaintenanceClosesIt() throws {
        var poll = try JSONDecoder().decode(GroupPoll.self, from: Data("""
        {"id":"\(UUID())","kind":"time","question":"When?","options":[],"status":"open","votes":[],"deadline_at":"2026-10-11T19:41:02Z"}
        """.utf8))
        XCTAssertTrue(poll.canVote(now: PalDate.date("2026-10-11T19:41:01Z")!))
        XCTAssertFalse(poll.canVote(now: PalDate.date("2026-10-11T19:41:02Z")!))
        XCTAssertFalse(poll.canVote(now: PalDate.date("2026-10-11T19:59:38Z")!))
        poll.status = "closed"
        XCTAssertFalse(poll.canVote(now: PalDate.date("2026-10-11T19:40:00Z")!))
    }

    func testAvatarPhotoIsDownsampledAndConvertedBeforeUpload() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let jpeg = try PalAvatarImage.jpegData(from: XCTUnwrap(source.pngData()))
        XCTAssertLessThanOrEqual(jpeg.count, 2 * 1024 * 1024)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(decoded) as String?, "public.jpeg")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [String: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight as String] as? Int)
        XCTAssertEqual(max(width, height), 1024)
        XCTAssertThrowsError(try PalAvatarImage.jpegData(from: Data([0, 1, 2])))
    }
    func testNativeCalendarReceiptOnlyRecordsExplicitSaveAndIsUserScoped() throws {
        let suite = "PalCalendarReceiptTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = UUID(), other = UUID(), plan = UUID()
        XCTAssertFalse(AppleCalendarReceipt.record(action: .canceled, userID: user, planID: plan, version: 1, defaults: defaults))
        XCTAssertFalse(AppleCalendarReceipt.record(action: .deleted, userID: user, planID: plan, version: 1, defaults: defaults))
        XCTAssertNil(AppleCalendarReceipt.savedVersion(userID: user, planID: plan, defaults: defaults))
        XCTAssertTrue(AppleCalendarReceipt.record(action: .saved, userID: user, planID: plan, version: 2, defaults: defaults))
        XCTAssertEqual(AppleCalendarReceipt.savedVersion(userID: user, planID: plan, defaults: defaults), 2)
        XCTAssertNil(AppleCalendarReceipt.savedVersion(userID: other, planID: plan, defaults: defaults))
        XCTAssertNil(AppleCalendarReceipt.savedVersion(userID: user, planID: UUID(), defaults: defaults))
    }
    @MainActor func testCalendarPlanLinkValidatesGroupAndEntity() {
        let group = UUID(), plan = UUID()
        let route = PalStore.calendarPlanRoute(from: URL(string: "pal://group/\(group)/plan/\(plan)")!)
        XCTAssertEqual(route?.groupID, group); XCTAssertEqual(route?.planID, plan)
        let queryRoute = PalStore.calendarPlanRoute(from: URL(string: "pal://group/\(group)?plan=\(plan)")!)
        XCTAssertEqual(queryRoute?.groupID, group); XCTAssertEqual(queryRoute?.planID, plan)
        XCTAssertNil(PalStore.calendarPlanRoute(from: URL(string: "https://group/\(group)/plan/\(plan)")!))
        XCTAssertNil(PalStore.calendarPlanRoute(from: URL(string: "pal://group/\(group)/plan/not-a-uuid")!))
        XCTAssertNil(PalStore.calendarPlanRoute(from: URL(string: "pal://group/\(group)/place/\(plan)")!))
    }
    func testCardDuplicateSuppressionPreservesLinksAndPalMessageVoice() throws {
        let entity = UUID()
        let source = try JSONDecoder().decode(GroupSource.self, from: Data("""
        {"id":"\(entity)","url":"https://example.com/reel","title":"Dinner","status":"pending","place_ids":[]}
        """.utf8))
        var state = GroupState.empty; state.sources = [source]
        func message(_ body: String) throws -> ChatMessage {
            try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode([
                "id": JSONValue.string(UUID().uuidString), "group_id": .string(UUID().uuidString), "role": .string("pal"),
                "body": .string(body), "created_at": .string("2026-10-11T20:00:00Z"), "cards": .array([.object(["type": .string("place"), "entity_id": .string(entity.uuidString)])])
            ]))
        }
        XCTAssertNil(try message("Dinner").displayedBody(in: state))
        XCTAssertNil(try message("Finding places…").displayedBody(in: state))
        XCTAssertEqual(try message("https://example.com/reel").displayedBody(in: state), "https://example.com/reel")
        XCTAssertEqual(try message("Dinner diplomacy, handled.").displayedBody(in: state), "Dinner diplomacy, handled.")
    }
    func testAvailabilitySeparatesNoneWorkFromUnanswered() throws {
        let user = UUID()
        let data = Data("""
        {"id":"\(UUID())","kind":"time","question":"When?","options":[],"status":"open","votes":[],"responses":[{"user_id":"\(user)","option_ids":[]}]}
        """.utf8)
        var poll = try JSONDecoder().decode(GroupPoll.self, from: data)
        XCTAssertTrue(poll.noneWork(for: user))
        XCTAssertFalse(poll.noneWork(for: UUID()))
        poll.responses = nil
        XCTAssertFalse(poll.noneWork(for: user))
        poll.responses = [PollResponse(userID: user, optionIDs: ["friday"])]
        XCTAssertFalse(poll.noneWork(for: user))
    }
    func testNotificationPreferenceRequiresActualOSAuthorization() {
        for status: UNAuthorizationStatus? in [nil, .notDetermined, .denied] { XCTAssertFalse(PalNotificationPreference.isEnabled(true, authorization: status)) }
        for status: UNAuthorizationStatus in [.authorized, .provisional, .ephemeral] {
            XCTAssertTrue(PalNotificationPreference.isEnabled(true, authorization: status))
            XCTAssertFalse(PalNotificationPreference.isEnabled(false, authorization: status))
        }
    }
    func testReminderEditingRequiresOwnerAndManualScheduledKind() throws {
        let owner = UUID()
        let json = """
        {"id":"\(UUID())","body":"Choose dinner","due_at":"2026-10-12T20:00:00Z","timezone":"America/Los_Angeles","status":"scheduled","kind":"reminder","requester_id":"\(owner)"}
        """
        var reminder = try JSONDecoder().decode(GroupReminder.self, from: Data(json.utf8))
        XCTAssertTrue(reminder.canEdit(userID: owner))
        XCTAssertFalse(reminder.canEdit(userID: UUID()))
        XCTAssertFalse(reminder.canEdit(userID: nil))
        reminder.kind = "plan_2h"
        XCTAssertFalse(reminder.canEdit(userID: owner))
        reminder.kind = "reminder"; reminder.status = "completed"
        XCTAssertFalse(reminder.canEdit(userID: owner))
    }

    func testChatRunsSeparateRolesDatesAndLongPauses() throws {
        let sender = UUID()
        func message(_ time: String, role: String = "user") throws -> ChatMessage {
            let data = Data("""
            {"id":"\(UUID())","group_id":"\(UUID())","sender_id":"\(sender)","role":"\(role)","body":"hello","created_at":"\(time)"}
            """.utf8)
            return try JSONDecoder().decode(ChatMessage.self, from: data)
        }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = try message("2026-10-11T20:00:00Z")
        XCTAssertTrue(try message("2026-10-11T20:02:00Z").follows(previous, calendar: utc))
        XCTAssertFalse(try message("2026-10-11T20:05:00Z").follows(previous, calendar: utc))
        XCTAssertFalse(try message("2026-10-11T20:01:00Z", role: "pal").follows(previous, calendar: utc))
        XCTAssertFalse(try message("2026-10-12T00:00:10Z").follows(message("2026-10-11T23:59:50Z"), calendar: utc))
    }

    func testChatLinksPreserveLiteralTextAndRestrictURLSchemes() {
        let body = "Book https://example.com/table?time=7 and keep **this** literal. javascript:alert(1)"
        let linked = PalText.linked(body)
        XCTAssertEqual(String(linked.characters), body)
        let links = linked.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.com/table?time=7")!])
    }
    func testSessionRefreshUsesPersistedExpiryAndSafetyMargin() throws {
        let data = Data("""
        {"access_token":"a","refresh_token":"r","expires_in":3600,"expires_at":2000,
         "user":{"id":"00000000-0000-0000-0000-000000000001","email":"a@example.com"}}
        """.utf8)
        let session = StoredSession(try JSONDecoder().decode(AuthSession.self, from: data), now: Date(timeIntervalSince1970: 1000))
        XCTAssertFalse(session.needsRefresh(now: Date(timeIntervalSince1970: 1900)))
        XCTAssertTrue(session.needsRefresh(now: Date(timeIntervalSince1970: 1950)))
        let restored = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.expires, session.expires)
    }
    func testMessagesDecodePalWithoutHumanSender() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","group_id":"00000000-0000-0000-0000-000000000002",
         "sender_id":null,"role":"pal","body":"Reminder: choose dinner","created_at":"2026-10-11T20:00:00Z"}
        """.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNil(message.senderID)
        XCTAssertEqual(message.role, "pal")
    }

    func testAppleNonceHashMatchesSupabaseSHA256Contract() throws {
        XCTAssertEqual(AppleSignInNonce.hash("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let first = try AppleSignInNonce.make()
        let second = try AppleSignInNonce.make()
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    @MainActor
    func testAppleInvalidCredentialIsRejectedBeforeNetwork() async {
        let store = PalStore()
        do {
            try await store.authenticateApple(identityToken: Data([0xFF]), nonce: "test-nonce")
            XCTFail("Invalid UTF-8 identity tokens must be rejected.")
        } catch {
            XCTAssertTrue(error is PalFailure)
            XCTAssertEqual(error.localizedDescription, "Apple did not return a valid sign-in. Please try again.")
        }
    }

    func testRichMessageReferencesAndMultiplePlacesDecode() throws {
        let group = "00000000-0000-0000-0000-000000000002"
        let entity = "00000000-0000-0000-0000-000000000003"
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","group_id":"\(group)",
        "role":"pal","body":"Choose dinner","created_at":"2026-10-11T20:00:00.123Z",
        "reply_to_id":"\(entity)","cards":[{"type":"place","entity_id":"\(entity)","source_id":"\(entity)"}]}
        """.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(message.replyToID?.uuidString.lowercased(), entity)
        XCTAssertEqual(message.cards.first?.entityID, message.replyToID)
        XCTAssertNotNil(PalDate.date(message.createdAt))
        let sourceData = Data("""
        {"id":"\(entity)","url":"https://www.instagram.com/reel/example/","status":"resolved",
        "place_ids":["\(group)"],"candidates":[{"name":"Restaurant","dishes":["noodles"],"prices":["$12"],
        "evidence":["Video caption"],"confidence":"medium","options":[{"name":"Restaurant","provider":"apple","provider_id":"verified","latitude":37.7,"longitude":-122.4}]}]}
        """.utf8)
        let source = try JSONDecoder().decode(GroupSource.self, from: sourceData)
        XCTAssertEqual(source.placeIDs?.count, 1)
        XCTAssertEqual(source.candidates?.first?.options?.first?.provider, "apple")
        XCTAssertEqual(source.candidates?.first?.dishes, ["noodles"])
    }

    func testOutboxRetainsClientIDAndReplyAcrossRelaunch() throws {
        let item = OutgoingMessage(groupID: UUID(), userID: UUID(), clientID: UUID(), body: "Dinner?", replyToID: UUID(), failed: true)
        let restored = try JSONDecoder().decode(OutgoingMessage.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.clientID, item.clientID)
        XCTAssertEqual(restored.replyToID, item.replyToID)
        XCTAssertEqual(restored.userID, item.userID)
    }

    @MainActor
    func testInvitePathsValidateAndPersistWhileSignedOut() throws {
        let code = "00000000-0000-0000-0000-000000000042"
        XCTAssertEqual(PalStore.inviteCode(from: URL(string: "https://pal-jade.vercel.app/join/" + code)!), code)
        XCTAssertEqual(PalStore.inviteCode(from: URL(string: "pal://join?code=" + code)!), code)
        XCTAssertNil(PalStore.inviteCode(from: URL(string: "https://example.com/join/" + code)!))
        XCTAssertNil(PalStore.inviteCode(from: URL(string: "pal://join?code=not-a-uuid")!))
        XCTAssertEqual(PalStore.inviteCode(from: "  https://pal-jade.vercel.app/join/" + code + "  "), code)
        XCTAssertEqual(PalStore.inviteCode(from: "  " + code + "  "), code)
        XCTAssertNil(PalStore.inviteCode(from: "https://example.com/join/" + code))
        let original = SessionKeychain.load()
        let pending = UserDefaults.standard.string(forKey: "PendingPalInvite")
        SessionKeychain.clear()
        defer {
            SessionKeychain.clear()
            if let original { try? SessionKeychain.save(original) }
            UserDefaults.standard.set(pending, forKey: "PendingPalInvite")
        }
        let store = PalStore()
        XCTAssertFalse(store.isSignedIn)
        store.handleURL(URL(string: "https://pal-jade.vercel.app/join/" + code)!)
        XCTAssertEqual(store.pendingInvite, code)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "PendingPalInvite"), code)
    }

    func testManualSourceAndPalReactionNullableFieldsDecode() throws {
        let source = try JSONDecoder().decode(GroupSource.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000003","url":null,"title":null,"status":"resolved",
        "place_ids":[],"candidates":[],"metadata":{"thumbnailUrl":"https://example.com/video.jpg"},
        "contributors":[{"user_id":"00000000-0000-0000-0000-000000000001","source_id":null}]}
        """.utf8))
        XCTAssertNil(source.url)
        XCTAssertEqual(source.thumbnailURL?.host, "example.com")
        XCTAssertEqual(source.contributors?.count, 1)
        let reaction = try JSONDecoder().decode(MessageReaction.self, from: Data("""
        {"message_id":"00000000-0000-0000-0000-000000000003","user_id":null,"emoji":"👍"}
        """.utf8))
        XCTAssertNil(reaction.userID)
    }

    @MainActor
    func testPushFailureReportsItsActualReasonAndDoesNotChangeSession() {
        let store = PalStore()
        let owner = store.userID
        var received: String?
        let observer = NotificationCenter.default.addObserver(forName: .palDeviceError, object: nil, queue: nil) { event in received = event.object as? String }
        defer { NotificationCenter.default.removeObserver(observer) }
        PalAppDelegate().application(UIApplication.shared, didFailToRegisterForRemoteNotificationsWithError: PalFailure(message: "APNs network unavailable"))
        XCTAssertEqual(received, "APNs network unavailable")
        store.recordPushRegistrationError(received ?? "Missing callback")
        XCTAssertEqual(store.pushRegistrationIssue, "APNs network unavailable")
        XCTAssertEqual(store.error, "Notifications could not register: APNs network unavailable")
        XCTAssertEqual(store.userID, owner)
    }

    func testLegacySessionMigratesToSharedKeychain() throws {
        let original = SessionKeychain.load()
        SessionKeychain.clear()
        defer { SessionKeychain.clear(); if let original { try? SessionKeychain.save(original) } }
        let data = Data("""
        {"access_token":"unit-test-token","refresh_token":"unit-test-refresh","expires_in":3600,
        "user":{"id":"00000000-0000-0000-0000-000000000099"}}
        """.utf8)
        let session = StoredSession(try JSONDecoder().decode(AuthSession.self, from: data))
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.pal.spike", kSecAttrAccount as String: "session", kSecValueData as String: try JSONEncoder().encode(session)]
        XCTAssertEqual(SecItemAdd(legacy as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(SessionKeychain.load()?.session.user.id, session.session.user.id)
        var remove = legacy
        remove.removeValue(forKey: kSecValueData as String)
        XCTAssertEqual(SecItemDelete(remove as CFDictionary), errSecSuccess)
        XCTAssertEqual(SessionKeychain.load()?.session.user.id, session.session.user.id, "Migrated session must remain readable after legacy item is removed.")
    }

    @MainActor
    func testLiveSharedConversationAndReminder() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["PAL_TEST_EMAIL"],
              let password = environment["PAL_TEST_PASSWORD"],
              let bobEmail = environment["PAL_TEST_BOB_EMAIL"],
              let bobPassword = environment["PAL_TEST_BOB_PASSWORD"],
              let groupValue = environment["PAL_TEST_GROUP_ID"],
              let groupID = UUID(uuidString: groupValue) else {
            throw XCTSkip("Live credentials are supplied only through an ignored test-run configuration.")
        }
        let bob = PalStore()
        try await bob.authenticate(email: bobEmail, password: bobPassword, signUp: false)
        try await bob.loadGroups()
        let bobGroup = try XCTUnwrap(bob.groups.first { $0.id == groupID })
        let bobMessages = try await bob.messages(in: bobGroup)

        let alice = PalStore()
        try await alice.authenticate(email: email, password: password, signUp: false)
        try await alice.loadGroups()
        let aliceGroup = try XCTUnwrap(alice.groups.first { $0.id == groupID })
        let aliceMessages = try await alice.messages(in: aliceGroup)
        try await alice.loadProfile()
        try await alice.loadState(aliceGroup)
        XCTAssertGreaterThanOrEqual(alice.states[aliceGroup.id]?.members.count ?? 0, 2)
        XCTAssertNotEqual(alice.userID, bob.userID)
        XCTAssertEqual(Set(aliceMessages.map(\.id)), Set(bobMessages.map(\.id)))
        XCTAssertGreaterThanOrEqual(Set(aliceMessages.filter { $0.role == "user" }.compactMap(\.senderID)).count, 2)
        XCTAssertTrue(aliceMessages.contains { $0.role == "pal" && !$0.body.hasPrefix("Reminder:") })
        XCTAssertTrue(aliceMessages.contains { $0.role == "pal" && $0.body.hasPrefix("Reminder:") })
        try await attachScreenshot(of: NavigationStack { ChatView(group: aliceGroup) }.environmentObject(alice).environment(\.scenePhase, .active), name: "Live Pal conversation")
        try await attachScreenshot(of: NavigationStack { GroupCalendarView(group: aliceGroup) }.environmentObject(alice), name: "Live group calendar")
        try await attachScreenshot(of: NavigationStack { GroupMapView(group: aliceGroup) }.environmentObject(alice), name: "Live saved places")
        try await attachScreenshot(of: LoginView().environmentObject(alice), name: "Native Apple sign in")
    }

    @MainActor
    func testLiveV1StateAndCards() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["PAL_TEST_EMAIL"], let password = env["PAL_TEST_PASSWORD"],
              let groupID = env["PAL_TEST_V1_GROUP_ID"].flatMap(UUID.init(uuidString:)) else {
            throw XCTSkip("V1 live fixture is supplied only through an ignored test-run configuration.")
        }
        let store = PalStore()
        try await store.authenticate(email: email, password: password, signUp: false)
        try await store.loadGroups()
        try await store.loadProfile()
        let group = try XCTUnwrap(store.groups.first { $0.id == groupID })
        try await store.loadState(group)
        let state = try XCTUnwrap(store.states[groupID])
        XCTAssertGreaterThanOrEqual(state.members.count, 2)
        XCTAssertFalse(state.places.isEmpty)
        XCTAssertFalse(state.polls.isEmpty)
        XCTAssertTrue(state.plans.contains { $0.status == "draft" || $0.status == "confirmed" })
        XCTAssertFalse(state.memories.isEmpty)
        try await store.joinGroup(code: "https://pal-jade.vercel.app/join/" + group.inviteCode)
        XCTAssertEqual(store.path, [groupID])
        if let poll = state.polls.first(where: { $0.kind == "time" && $0.canVote() }) {
            let previous = poll.votes.filter { $0.userID == store.userID }.map(\.optionID)
            try await store.mutate(group, action: "poll.vote", data: ["id": .string(poll.id.uuidString), "option_ids": .array([])])
            XCTAssertTrue(store.states[groupID]?.polls.first(where: { $0.id == poll.id })?.noneWork(for: store.userID) == true)
            try await attachScreenshot(of: NavigationStack { PollCardView(group: group, pollID: poll.id).padding() }.environmentObject(store), name: "Live v1 no available times")
            if !previous.isEmpty { try await store.mutate(group, action: "poll.vote", data: ["id": .string(poll.id.uuidString), "option_ids": .array(previous.map(JSONValue.string))]) }
        }
        let messages = try await store.messages(in: group)
        XCTAssertTrue(messages.contains { $0.role == "pal" })
        XCTAssertTrue(messages.contains { !$0.cards.isEmpty })
        if let last = messages.last {
            try await store.mutate(group, action: "group.read", data: ["message_id": .string(last.id.uuidString)])
            XCTAssertEqual(store.states[groupID]?.members.first(where: { $0.userID == store.userID })?.lastReadMessageID, last.id)
        }
        try await attachScreenshot(of: NavigationStack { ChatView(group: group) }.environmentObject(store).environment(\.scenePhase, .active), name: "Live v1 Pal chat")
        try await attachScreenshot(of: NavigationStack { ChatView(group: group) }.environmentObject(store).environment(\.scenePhase, .active).preferredColorScheme(.dark), name: "Live v1 Pal chat dark")
        try await attachScreenshot(of: NavigationStack { GroupCalendarView(group: group) }.environmentObject(store), name: "Live v1 calendar")
        try await attachScreenshot(of: NavigationStack { GroupMapView(group: group) }.environmentObject(store), name: "Live v1 saved map")
        try await attachScreenshot(of: NavigationStack { ProfileView() }.environmentObject(store), name: "Live v1 profile and Google Calendar")
        try await attachScreenshot(of: NavigationStack { ProfileView() }.environmentObject(store).preferredColorScheme(.dark), name: "Live v1 profile dark")
        try await attachScreenshot(of: NavigationStack { ReminderEditor(group: group) }.environmentObject(store), name: "Live v1 new reminder")
        if let plan = state.plans.first(where: { $0.status != "cancelled" }) { try await attachScreenshot(of: NavigationStack { PlanDetailView(group: group, plan: plan) }.environmentObject(store), name: "Live v1 plan details") }
        let cards = messages.flatMap(\.cards)
        try await attachScreenshot(of: NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 16) { ForEach(cards) { PalCardView(group: group, card: $0) } }.padding() }
                .background(Color(uiColor: .systemBackground)).navigationTitle("Group decisions")
        }.environmentObject(store), name: "Live v1 cards")
        if let card = cards.last {
            try await attachScreenshot(of: NavigationStack { ScrollView { PalCardView(group: group, card: card).padding() }.background(Color(uiColor: .systemBackground)) }.environmentObject(store).environment(\.dynamicTypeSize, .accessibility3).preferredColorScheme(.dark), name: "Live v1 accessible dark card")
        }
    }

    @MainActor
    private func attachScreenshot<Content: View>(of view: Content, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController
        let controller = UIHostingController(rootView: view.tint(PalTheme.ink))
        window.rootViewController = controller
        defer { window.rootViewController = previous }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(3))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
