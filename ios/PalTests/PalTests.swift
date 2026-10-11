import XCTest
import SwiftUI
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
        XCTAssertNotEqual(alice.userID, bob.userID)
        XCTAssertEqual(Set(aliceMessages.map(\.id)), Set(bobMessages.map(\.id)))
        XCTAssertGreaterThanOrEqual(Set(aliceMessages.filter { $0.role == "user" }.compactMap(\.senderID)).count, 2)
        XCTAssertTrue(aliceMessages.contains { $0.role == "pal" && !$0.body.hasPrefix("Reminder:") })
        XCTAssertTrue(aliceMessages.contains { $0.role == "pal" && $0.body.hasPrefix("Reminder:") })
        try await attachScreenshot(of: NavigationStack { ChatView(group: aliceGroup) }.environmentObject(alice).environment(\.scenePhase, .active), name: "Live Pal conversation")
        try await attachScreenshot(of: LoginView().environmentObject(alice), name: "Native Apple sign in")
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
