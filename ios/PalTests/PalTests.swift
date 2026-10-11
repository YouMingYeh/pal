import XCTest
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
}
