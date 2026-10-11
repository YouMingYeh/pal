import XCTest
import UIKit
import CoreImage
@testable import Pal

final class GroupAccessTests: XCTestCase {
    @MainActor func testGeneratedInviteQRCodeDecodesToTrustedPalInvite() throws {
        let code = UUID().uuidString.lowercased()
        let url = PalGroupAccess.inviteURL(code: code)
        let image = try XCTUnwrap(PalGroupAccess.qrImage(for: url)?.cgImage)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let feature = try XCTUnwrap(detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)
        let payload = try XCTUnwrap(feature.messageString)
        XCTAssertEqual(payload, url.absoluteString)
        XCTAssertEqual(PalStore.inviteCode(from: payload), code)
        XCTAssertNil(PalStore.inviteCode(from: "https://example.com/join?code=\(code)"))
    }
    @MainActor func testGroupNameMatchesServerUTF16Limit() {
        XCTAssertFalse(PalGroupAccess.validName(" \n "))
        XCTAssertTrue(PalGroupAccess.validName("\(String(repeating: "a", count: 80)) "))
        XCTAssertFalse(PalGroupAccess.validName(String(repeating: "a", count: 81)))
        XCTAssertTrue(PalGroupAccess.validName(String(repeating: "🐾", count: 40)))
        XCTAssertFalse(PalGroupAccess.validName(String(repeating: "🐾", count: 41)))
    }
    func testPalAvatarNavigationReusesTheExistingPrivateChatAndKeepsBackNavigation() throws {
        let groupID = UUID(), palID = UUID()
        let shared = try JSONDecoder().decode(ChatGroup.self, from: JSONSerialization.data(withJSONObject: ["id": groupID.uuidString, "name": "Friends", "is_direct": false]))
        let pal = try JSONDecoder().decode(ChatGroup.self, from: JSONSerialization.data(withJSONObject: ["id": palID.uuidString, "name": "Pal", "is_direct": true]))
        XCTAssertEqual(PalChatNavigation.path(in: [shared, pal], from: [groupID]), [groupID, palID], "Back returns to the group that opened Pal.")
        XCTAssertEqual(PalChatNavigation.path(in: [shared, pal], from: [groupID, palID]), [groupID, palID], "Tapping Pal in the DM cannot push another copy.")
        XCTAssertEqual(PalChatNavigation.path(in: [shared, pal], from: [palID, groupID]), [palID], "An existing DM is reused in the navigation stack.")
        XCTAssertNil(PalChatNavigation.path(in: [shared], from: [groupID]), "Missing private chat refreshes the existing inbox instead of creating a group.")
        XCTAssertNil(PalChatNavigation.path(in: [], from: []))
    }

}
