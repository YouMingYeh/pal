import XCTest
@testable import Pal

final class MemberDetailTests: XCTestCase {
    func testSummaryDecodesBoundedEvidenceAndExplicitAvailability() throws {
        let member = UUID(), group = UUID(), source = UUID(), memory = UUID()
        let raw: [String: Any] = ["summary": "Vegetarian options, please.", "sources": [["id": source.uuidString, "body": "Vegetarian dishes for me."]],
            "preferences": [["id": memory.uuidString, "user_id": member.uuidString, "key": "food", "value": "vegetarian", "kind": "preference", "expires_at": NSNull()]],
            "availability": [["id": memory.uuidString, "user_id": member.uuidString, "key": "Friday", "value": "After seven", "kind": "availability", "expires_at": "2026-10-17T06:59:59Z"]]]
        let summary = try JSONDecoder().decode(MemberSummary.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(summary.sources.first?.id, source)
        XCTAssertEqual(summary.availability.first?.userID, member)
        XCTAssertTrue(summary.availability[0].isCurrentAvailability(for: member, now: Date(timeIntervalSince1970: 1000)))
        XCTAssertFalse(summary.availability[0].isCurrentAvailability(for: UUID(), now: Date(timeIntervalSince1970: 1000)), "Another person’s availability must not appear under this member.")
        XCTAssertEqual(summary.preferences.first?.value, "vegetarian")
        XCTAssertNotEqual(MemberSummary.key(groupID: group, userID: member), MemberSummary.key(groupID: UUID(), userID: member), "Member summaries remain group-scoped.")
    }

    func testUnknownSummaryRemainsEmptyInsteadOfInventingPersonalityOrSchedule() throws {
        let summary = try JSONDecoder().decode(MemberSummary.self, from: Data(#"{"summary":null,"sources":[],"preferences":[],"availability":[]}"#.utf8))
        XCTAssertNil(summary.summary)
        XCTAssertTrue(summary.sources.isEmpty)
        XCTAssertTrue(summary.availability.isEmpty)
    }
}
