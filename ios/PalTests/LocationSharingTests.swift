import XCTest
import CoreLocation
@testable import Pal

@MainActor final class LocationSharingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func point(latitude: Double = 37.77, longitude: Double = -122.42, accuracy: Double = 100, age: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
    }
    func testFreshnessRejectsInvalidAndOldLocationsButAcceptsApproximateOrZeroAccuracy() {
        XCTAssertTrue(PalLocationPolicy.isFresh(point(accuracy: 3000), now: now))
        XCTAssertTrue(PalLocationPolicy.isFresh(point(accuracy: 0), now: now))
        XCTAssertFalse(PalLocationPolicy.isFresh(point(age: 301), now: now))
        XCTAssertFalse(PalLocationPolicy.isFresh(point(age: -31), now: now))
        XCTAssertFalse(PalLocationPolicy.isFresh(point(accuracy: -1), now: now))
        XCTAssertFalse(PalLocationPolicy.isFresh(point(accuracy: 10_001), now: now))
        XCTAssertFalse(PalLocationPolicy.isFresh(point(latitude: 91), now: now))
    }
    func testStationaryThrottleAndMovementTrigger() {
        let original = point()
        XCTAssertTrue(PalLocationPolicy.shouldSend(original, last: nil, sentAt: nil, now: now))
        XCTAssertFalse(PalLocationPolicy.shouldSend(original, last: original, sentAt: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(PalLocationPolicy.shouldSend(original, last: original, sentAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(PalLocationPolicy.shouldSend(point(latitude: 37.78), last: original, sentAt: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(PalLocationPolicy.shouldSend(point(age: 301), last: original, sentAt: now.addingTimeInterval(-61), now: now))
    }
    func testSelectedGroupsAndPendingRemovalNeverTransferBetweenAccounts() throws {
        let suite = "Pal-location-test-\(UUID().uuidString)", owner = UUID(), other = UUID(), group = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PalLocationPreferences(defaults: defaults)
        preferences.save([group], owner: owner)
        preferences.save([group], owner: owner, suffix: "removal")
        XCTAssertEqual(preferences.load(owner: owner), [group])
        XCTAssertEqual(preferences.load(owner: owner, suffix: "removal"), [group])
        XCTAssertTrue(preferences.load(owner: other).isEmpty)
        XCTAssertTrue(preferences.load(owner: other, suffix: "removal").isEmpty)
        preferences.save([], owner: owner)
        XCTAssertTrue(preferences.load(owner: owner).isEmpty)
        XCTAssertEqual(preferences.load(owner: owner, suffix: "removal"), [group], "A failed removal remains retryable after tracking has stopped.")
    }
    func testForegroundOnlyAndOnlySelectedCurrentSharedGroups() throws {
        XCTAssertTrue(PalLocationPolicy.canTrack(active: true, hasAccount: true, selectedCount: 1))
        XCTAssertFalse(PalLocationPolicy.canTrack(active: false, hasAccount: true, selectedCount: 1))
        XCTAssertFalse(PalLocationPolicy.canTrack(active: true, hasAccount: false, selectedCount: 1))
        XCTAssertFalse(PalLocationPolicy.canTrack(active: true, hasAccount: true, selectedCount: 0))
        let sharedID = UUID(), otherID = UUID(), directID = UUID(), removedID = UUID()
        func group(_ id: UUID, direct: Bool = false) throws -> ChatGroup {
            try JSONDecoder().decode(ChatGroup.self, from: JSONSerialization.data(withJSONObject: ["id": id.uuidString, "name": "Room", "is_direct": direct]))
        }
        let groups = try [group(sharedID), group(otherID), group(directID, direct: true)]
        XCTAssertEqual(PalLocationPolicy.scopedGroups(selected: [sharedID, directID, removedID], groups: groups), [sharedID])
        XCTAssertTrue(PalLocationPolicy.scopedGroups(selected: [], groups: groups).isEmpty)
    }
    func testServerExpiryAndLegacyStateWithoutLocations() throws {
        let legacy = Data("{\"members\":[],\"places\":[],\"sources\":[],\"polls\":[],\"plans\":[],\"memories\":[],\"reminders\":[],\"reactions\":[],\"settings\":null}".utf8)
        XCTAssertTrue(try JSONDecoder().decode(GroupState.self, from: legacy).locations.isEmpty)
        let fresh = GroupMemberLocation(userID: UUID(), latitude: 37.77, longitude: -122.42, accuracy: 3000,
                                        updatedAt: PalDate.iso(now), expiresAt: PalDate.iso(now.addingTimeInterval(3600)))
        XCTAssertTrue(fresh.isFresh(at: now))
        XCTAssertFalse(fresh.isFresh(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(PalRealtimeProtocol.tables.contains("group_member_locations"))
    }
}
