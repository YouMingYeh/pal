import XCTest
@testable import Pal

final class MessageCacheTests: XCTestCase {
    private func message(group: UUID, id: UUID = UUID(), clientID: UUID? = nil, body: String = "Hello", at: String = "2026-10-11T12:00:00Z") throws -> ChatMessage {
        var fields: [String: Any] = ["id": id.uuidString, "group_id": group.uuidString, "role": "user", "body": body, "created_at": at]
        if let clientID { fields["client_id"] = clientID.uuidString }
        return try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testInboxInvalidatesDeletedHistoryButProtectsOnlyUnconfirmedPosts() throws {
        let group = UUID()
        var cache = PalMessageCache()
        let sent = try message(group: group, clientID: UUID())
        XCTAssertTrue(cache.needsRefresh(groupID: group, latestMessageID: nil))
        cache.acknowledge(sent)
        XCTAssertEqual(cache.latestAcknowledgement(groupID: group)?.id, sent.id)
        let sequence = cache.beginFetch(groupID: group)
        _ = cache.acceptSnapshot([sent], groupID: group, sequence: sequence)
        XCTAssertNil(cache.latestAcknowledgement(groupID: group), "A confirmed message cannot replace an authoritative cleared inbox preview.")
        XCTAssertFalse(cache.needsRefresh(groupID: group, latestMessageID: sent.id))
        XCTAssertTrue(cache.needsRefresh(groupID: group, latestMessageID: nil), "Deleted history must warm again even when its cache was previously loaded.")
        let cleared = cache.beginFetch(groupID: group)
        _ = cache.acceptSnapshot([], groupID: group, sequence: cleared)
        XCTAssertFalse(cache.needsRefresh(groupID: group, latestMessageID: nil), "A fresh empty snapshot must stop further warmups.")
    }

    func testUnknownHistoryIsDistinctFromAConfirmedEmptyChat() {
        var cache = PalMessageCache()
        let group = UUID()
        XCTAssertNil(cache.messages[group])
        let sequence = cache.beginFetch(groupID: group)
        XCTAssertNil(cache.messages[group], "Starting a read cannot claim that a chat is empty.")
        _ = cache.acceptSnapshot([], groupID: group, sequence: sequence)
        XCTAssertEqual(cache.messages[group]?.count, 0)
        cache.clear()
        XCTAssertNil(cache.messages[group])
    }

    func testSnapshotStartedBeforeAcknowledgementKeepsTheSentBubble() throws {
        let group = UUID()
        var cache = PalMessageCache()
        let sequence = cache.beginFetch(groupID: group)
        let sent = try message(group: group, clientID: UUID())
        cache.acknowledge(sent)
        XCTAssertEqual(cache.acceptSnapshot([], groupID: group, sequence: sequence).map(\.id), [sent.id])
        let next = cache.beginFetch(groupID: group)
        XCTAssertEqual(cache.acceptSnapshot([], groupID: group, sequence: next).map(\.id), [sent.id])
    }

    func testSeeingAcknowledgedClientIDDeduplicatesAndEndsProtection() throws {
        let group = UUID(), clientID = UUID()
        var cache = PalMessageCache()
        let sent = try message(group: group, clientID: clientID)
        cache.acknowledge(sent)
        cache.acknowledge(sent)
        let remote = try message(group: group, clientID: clientID, body: "Canonical")
        let sequence = cache.beginFetch(groupID: group)
        let merged = cache.acceptSnapshot([remote, remote], groupID: group, sequence: sequence)
        XCTAssertEqual(merged.map(\.id), [remote.id])
        XCTAssertEqual(merged.first?.body, "Canonical")
        let next = cache.beginFetch(groupID: group)
        XCTAssertTrue(cache.acceptSnapshot([], groupID: group, sequence: next).isEmpty)
    }

    func testSeeingAcknowledgedServerIDEndsProtectionWithoutClientID() throws {
        let group = UUID()
        var cache = PalMessageCache()
        let sent = try message(group: group)
        cache.acknowledge(sent)
        let sequence = cache.beginFetch(groupID: group)
        XCTAssertEqual(cache.acceptSnapshot([sent], groupID: group, sequence: sequence).map(\.id), [sent.id])
        let next = cache.beginFetch(groupID: group)
        XCTAssertTrue(cache.acceptSnapshot([], groupID: group, sequence: next).isEmpty)
    }

    func testOlderResponseCannotOverwriteFreshSnapshot() throws {
        let group = UUID()
        var cache = PalMessageCache()
        let older = cache.beginFetch(groupID: group)
        let newer = cache.beginFetch(groupID: group)
        let fresh = try message(group: group)
        _ = cache.acceptSnapshot([fresh], groupID: group, sequence: newer)
        XCTAssertEqual(cache.acceptSnapshot([], groupID: group, sequence: older).map(\.id), [fresh.id])
    }

    func testBoundsRemoteHistoryButRetainsUnseenAcknowledgementAndStableOrdering() throws {
        let group = UUID()
        var cache = PalMessageCache()
        let sent = try message(group: group, at: "2026-10-01T12:00:00Z")
        cache.acknowledge(sent)
        let remote = try (0..<220).map { index in
            try message(group: group, id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
        }
        let sequence = cache.beginFetch(groupID: group)
        let merged = cache.acceptSnapshot(Array(remote.reversed()), groupID: group, sequence: sequence)
        XCTAssertEqual(merged.count, 201)
        XCTAssertEqual(merged.first?.id, sent.id)
        XCTAssertEqual(Array(merged.dropFirst()).map(\.id), Array(remote.suffix(200)).map(\.id))
    }

    func testPruneAndLogoutRejectOldCallbacksAndDiscardPendingProtection() throws {
        let kept = UUID(), removed = UUID()
        var cache = PalMessageCache()
        let keptMessage = try message(group: kept), removedMessage = try message(group: removed)
        cache.acknowledge(keptMessage)
        cache.acknowledge(removedMessage)
        let old = cache.beginFetch(groupID: removed)
        cache.prune(groupIDs: [kept])
        XCTAssertEqual(Set(cache.messages.keys), [kept])
        let new = cache.beginFetch(groupID: removed)
        XCTAssertTrue(cache.acceptSnapshot([removedMessage], groupID: removed, sequence: old).isEmpty)
        XCTAssertTrue(cache.acceptSnapshot([], groupID: removed, sequence: new).isEmpty)
        let beforeLogout = cache.beginFetch(groupID: kept)
        cache.clear()
        XCTAssertTrue(cache.messages.isEmpty)
        let afterLogin = cache.beginFetch(groupID: kept)
        XCTAssertGreaterThan(afterLogin, beforeLogout)
        XCTAssertTrue(cache.acceptSnapshot([keptMessage], groupID: kept, sequence: beforeLogout).isEmpty)
        XCTAssertTrue(cache.acceptSnapshot([], groupID: kept, sequence: afterLogin).isEmpty)
    }

    func testSnapshotCannotPopulateAnotherGroupsMessages() throws {
        let group = UUID()
        var cache = PalMessageCache()
        let sequence = cache.beginFetch(groupID: group)
        XCTAssertTrue(cache.acceptSnapshot([try message(group: UUID())], groupID: group, sequence: sequence).isEmpty)
    }
}
