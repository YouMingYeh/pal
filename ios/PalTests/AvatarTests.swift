import XCTest
import SwiftUI
@testable import Pal

final class AvatarTests: XCTestCase {
    @MainActor func testExistingAccountAvatarTransportAndRendering() async throws {
        guard ProcessInfo.processInfo.environment["PAL_TEST_EXISTING_ACCOUNT"] == "1" else { throw XCTSkip("Read-only avatar review uses the existing signed-in device account.") }
        let store = PalStore()
        guard store.isSignedIn else { throw XCTSkip("This test never signs in or changes the device account.") }
        try await store.loadProfile(); try await store.loadGroups()
        let group = try XCTUnwrap(store.groups.first { !$0.isDirect && $0.name == "Friday dinner" })
        try await store.loadState(group)
        let members = store.states[group.id]?.members ?? []
        let memberPhotoCount = members.filter { $0.avatarURL != nil }.count
        print("Avatar diagnostics: profilePhoto=\(store.profile?.avatarURL != nil), groupPhoto=\(group.avatarURL != nil), memberPhotos=\(memberPhotoCount)/\(members.count).")
        var addresses = [store.profile?.avatarURL, group.avatarURL].compactMap { $0 }
        addresses += (store.states[group.id]?.members ?? []).compactMap(\.avatarURL)
        let urls = Array(Set(addresses)).compactMap(URL.init(string:))
        XCTAssertGreaterThanOrEqual(urls.count, 2, "The live shared room must supply real signed member/group photo URLs.")
        var decoded: [UIImage] = []
        for (index, url) in urls.enumerated() {
            let data: Data, response: URLResponse
            do { (data, response) = try await URLSession.shared.data(from: url) }
            catch { throw PalFailure(message: "Live avatar \(index) transport failed (\((error as NSError).code)).") }
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200, "Live avatar \(index) must return an image; signed URLs are deliberately omitted from logs.")
            XCTAssertNotNil(UIImage(data: data), "Live avatar \(index) must decode as an actual photo.")
            do { decoded.append(try await PalImageCache.shared.image(url)) }
            catch { throw PalFailure(message: "Live avatar \(index) cache/decode failed (\((error as NSError).code)).") }
        }
        XCTAssertEqual(decoded.count, urls.count)
        let url = try XCTUnwrap(urls.first)
        let coldCache = PalImageCache()
        coldCache.setOwner(store.userID)
        XCTAssertNil(coldCache.cached(url))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        let previous = window.rootViewController
        let host = UIHostingController(rootView: AnyView(AvatarView(name: "AV", size: 148).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white).ignoresSafeArea()))
        window.rootViewController = host
        defer { window.rootViewController = previous }
        window.layoutIfNeeded(); host.view.layoutIfNeeded()
        func snapshot() -> UIImage {
            UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        }
        func center(_ image: UIImage) -> Data? {
            let rect = CGRect(x: (image.size.width / 2 - 60) * image.scale, y: (image.size.height / 2 - 60) * image.scale, width: 120 * image.scale, height: 120 * image.scale)
            return image.cgImage?.cropping(to: rect).flatMap { UIImage(cgImage: $0).pngData() }
        }
        let initials = center(snapshot())
        host.rootView = AnyView(AvatarView(name: "AV", url: url.absoluteString, size: 148, imageCache: coldCache).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white).ignoresSafeArea())
        let deadline = Date().addingTimeInterval(10)
        while coldCache.cached(url) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(coldCache.cached(url), "A cold real AvatarView must start its own download on the iPhone.")
        try await Task.sleep(for: .milliseconds(100))
        let actual = snapshot()
        XCTAssertTrue(center(actual) != initials, "The actual AvatarView must draw the decoded live photo, rather than only initials.")
        let attachment = XCTAttachment(image: actual)
        attachment.name = "Live native signed avatar rendering"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
