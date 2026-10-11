import XCTest
import SwiftUI
import Security
@testable import Pal

final class PalTests: XCTestCase {
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
        XCTAssertTrue(state.plans.contains { $0.status == "draft" })
        XCTAssertFalse(state.memories.isEmpty)
        let messages = try await store.messages(in: group)
        XCTAssertTrue(messages.contains { $0.role == "pal" })
        XCTAssertTrue(messages.contains { !$0.cards.isEmpty })
        if let last = messages.last {
            try await store.mutate(group, action: "group.read", data: ["message_id": .string(last.id.uuidString)])
            XCTAssertEqual(store.states[groupID]?.members.first(where: { $0.userID == store.userID })?.lastReadMessageID, last.id)
        }
        try await attachScreenshot(of: NavigationStack { ChatView(group: group) }.environmentObject(store).environment(\.scenePhase, .active), name: "Live v1 Pal chat")
        try await attachScreenshot(of: NavigationStack { GroupCalendarView(group: group) }.environmentObject(store), name: "Live v1 calendar")
        try await attachScreenshot(of: NavigationStack { GroupMapView(group: group) }.environmentObject(store), name: "Live v1 saved map")
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
        let controller = UIHostingController(rootView: view)
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
