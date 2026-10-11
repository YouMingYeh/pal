import XCTest
import UIKit
import SwiftUI
import Vision
@testable import Pal

final class FetchTests: XCTestCase {
    @MainActor func testInitiallyEmptyMountedAvatarActuallyLoadsAndDrawsItsImage() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        AvatarURLProtocol.prepare(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AvatarURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = PalImageCache(session: session)
        let url = try XCTUnwrap(URL(string: "https://cache.test/storage/v1/object/sign/avatars/mounted.jpg?token=fresh"))
        XCTAssertNil(cache.cached(url))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        let previous = window.rootViewController
        let host = UIHostingController(rootView: PalCachedAvatarImage(url: url, cache: cache).frame(width: 64, height: 64).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white))
        window.rootViewController = host
        defer { window.rootViewController = previous }
        window.layoutIfNeeded(); host.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        while cache.cached(url) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(cache.cached(url), "An initially empty avatar must mount its task and perform the real image load.")
        XCTAssertEqual(AvatarURLProtocol.requestCount, 1)
        try await Task.sleep(for: .milliseconds(50))
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let point = CGPoint(x: rendered.size.width / 2, y: rendered.size.height / 2)
        let crop = try XCTUnwrap(rendered.cgImage?.cropping(to: CGRect(x: point.x * rendered.scale, y: point.y * rendered.scale, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[0], 200)
        XCTAssertLessThan(pixel[2], 80, "The actual mounted center must draw the orange photo, rather than the empty white placeholder.")
    }
    @MainActor func testCachedConversationDrawsMessagesAndPalBeforeAnyScrollInteraction() async throws {
        try await assertInitialConversationRendering(preload: true)
    }

    @MainActor func testFirstAsyncHistoryDrawsMessagesAndPalWithoutScrollInteraction() async throws {
        try await assertInitialConversationRendering(preload: false)
    }

    @MainActor func testReadingOlderMessagesDoesNotJumpWhenNewHistoryArrives() async throws {
        try await assertInitialConversationRendering(preload: true, checkReadingPosition: true)
    }

    @MainActor func testPushedConversationStaysAtLatestThroughLaterViewportLayout() async throws {
        try await assertInitialConversationRendering(preload: true, pushed: true, resizeViewport: true)
    }

    @MainActor private func assertInitialConversationRendering(preload: Bool, checkReadingPosition: Bool = false, pushed: Bool = false, resizeViewport: Bool = false) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This test uses a temporary authentication fixture only in the simulator.")
        #else
        let originalSession = SessionKeychain.load()
        let account = UUID(), groupID = UUID()
        let fixture = AuthSession(accessToken: "chat-render-fixture", refreshToken: "unused", expiresIn: 3600, expiresAt: nil, user: .init(id: account, email: "render@example.test"))
        try SessionKeychain.save(StoredSession(fixture))
        defer { SessionKeychain.clear(); if let originalSession { try? SessionKeychain.save(originalSession) } }
        let group = try JSONDecoder().decode(ChatGroup.self, from: JSONSerialization.data(withJSONObject: ["id": groupID.uuidString, "name": "Render fixture", "is_direct": true]))
        let messageJSON: [[String: Any]] = (0..<60).map { index in
            ["id": UUID().uuidString, "group_id": groupID.uuidString, "role": "pal", "body": index == 59 ? "The latest message is visible before you touch the screen." : "A varied-length conversation message \(index). " + String(repeating: "We should get dinner together. ", count: index % 5), "emotion": "heureux", "created_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1791750000 + Double(index) * 240))]
        }
        ChatRenderURLProtocol.prepare(try JSONSerialization.data(withJSONObject: ["messages": messageJSON]))
        URLProtocol.registerClass(ChatRenderURLProtocol.self)
        defer { URLProtocol.unregisterClass(ChatRenderURLProtocol.self) }
        let store = PalStore()
        if preload { _ = try await store.messages(in: group) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        let previous = window.rootViewController
        let navigation = ChatRenderNavigation()
        let host = UIHostingController(rootView: ChatRenderHost(group: group, navigation: navigation, pushed: pushed).environmentObject(store).environment(\.scenePhase, .inactive).preferredColorScheme(.light))
        window.rootViewController = host
        defer { window.rootViewController = previous }
        window.layoutIfNeeded(); host.view.layoutIfNeeded()
        if pushed { withAnimation { navigation.path = [group] } }
        if !preload {
            try await Task.sleep(for: .milliseconds(50))
            _ = try await store.messages(in: group)
        }
        XCTAssertEqual(store.cachedMessages[groupID]?.count, 60)
        try await Task.sleep(for: .milliseconds(pushed ? 500 : 150))
        if resizeViewport {
            // Navigation, keyboard, and composer insets can settle after the first row layout.
            host.additionalSafeAreaInsets.bottom = 90
            host.view.setNeedsLayout(); window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot); attachment.lifetime = .keepAlways; add(attachment)
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.cgImage)).perform([textRequest])
        let visibleText = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertTrue(visibleText.contains("latest message"), "Initial layout must show the latest cached message without scrolling. Actual visible text: \(visibleText)")
        // Exclude the navigation-bar mascot and composer. The conversation itself must draw a Pal avatar and text.
        let region = CGRect(x: 10, y: 130, width: window.bounds.width - 20, height: window.bounds.height - 330)
        let crop = try XCTUnwrap(screenshot.cgImage?.cropping(to: region.applying(CGAffineTransform(scaleX: screenshot.scale, y: screenshot.scale))))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let orange = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 210 && pixels[$0 + 1] > 65 && pixels[$0 + 1] < 175 && pixels[$0 + 2] < 70 }.count
        let ink = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 80 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 }.count
        XCTAssertGreaterThan(orange, 80, "The mounted cached transcript must draw a real Pal avatar before any scroll or tap.")
        XCTAssertGreaterThan(ink, 80, "The mounted cached transcript must draw its message text before any scroll or tap.")
        func scrollViews(in view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: host.view).filter { $0.bounds.height > 250 }.max { $0.contentSize.height < $1.contentSize.height })
        XCTAssertTrue([UIScrollView.KeyboardDismissMode.interactive, .interactiveWithAccessory].contains(scroll.keyboardDismissMode), "The mounted chat must preserve UIKit's native interactive swipe-to-dismiss keyboard behavior, including its input accessory.")
        let bottomOffset = max(-scroll.adjustedContentInset.top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        XCTAssertEqual(scroll.contentOffset.y, bottomOffset, accuracy: 3, "Initial conversation must actually be at the latest message, including final lazy-row heights.")
        if checkReadingPosition {
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            let readingOffset = scroll.contentOffset.y
            let incoming: [String: Any] = ["id": UUID().uuidString, "group_id": groupID.uuidString, "role": "pal", "body": "One more incoming message.", "created_at": "2026-10-12T23:00:00Z"]
            ChatRenderURLProtocol.prepare(try JSONSerialization.data(withJSONObject: ["messages": messageJSON + [incoming]]))
            _ = try await store.api("/api/groups/" + groupID.uuidString + "/state", method: "POST", json: [:])
            _ = try await store.messages(in: group)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(store.cachedMessages[groupID]?.count, 61)
            XCTAssertEqual(scroll.contentOffset.y, readingOffset, accuracy: 2, "New history must preserve the user's position while reading older messages.")
        }
        #endif
    }

    func testBackgroundFetchesDoNotChangeVisibleStateButKeepConcurrentRequestAccounting() {
        var tracked = PalFetchState()
        tracked.begin()
        let loading = tracked.presentation
        tracked.begin()
        XCTAssertEqual(tracked.presentation, loading, "Overlapping cold readers share one visible loading state.")
        XCTAssertTrue(tracked.presentation.isLoading)
        tracked.finish()
        let confirmed = tracked.presentation
        XCTAssertTrue(tracked.isLoading, "Another reader still owns an outstanding request.")
        XCTAssertTrue(confirmed.hasLoaded)
        XCTAssertFalse(confirmed.isLoading, "Confirmed content need not be invalidated just to spin a hidden refresh.")
        tracked.begin(); tracked.finish()
        XCTAssertEqual(tracked.presentation, confirmed)
        tracked.fail(PalFailure(message: "Offline"))
        XCTAssertEqual(tracked.presentation.issue, "Offline")
        tracked.begin()
        XCTAssertEqual(tracked.presentation, confirmed, "Retry clears the inline error without clearing the content.")
        tracked.finish()
        XCTAssertFalse(tracked.isLoading)
        XCTAssertEqual(tracked.presentation, confirmed)
    }

    func testSnapshotEqualityIncludesReadMarkersReactionsCardResponsesAndTypingLeases() {
        let member = UUID()
        var initial = GroupState.empty
        initial.members = [GroupMember(userID: member, displayName: "Amy", avatarURL: "https://example.com/photo?token=old")]
        initial.plans = [GroupPlan(id: UUID(), title: "Dinner", status: "confirmed", attendees: [])]
        initial.polls = [GroupPoll(id: UUID(), kind: "time", question: "When?", options: [], status: "open", votes: [])]
        var updated = initial
        XCTAssertEqual(initial, updated)
        updated.members[0].avatarURL = "https://example.com/photo?token=new"
        XCTAssertNotEqual(initial, updated, "Fresh signed URLs must still reach photo views.")
        updated = initial; updated.members[0].lastReadAt = "2026-10-11T20:00:00Z"
        XCTAssertNotEqual(initial, updated)
        updated = initial; updated.plans[0].attendees = [PlanAttendee(userID: member, status: "going")]
        XCTAssertNotEqual(initial, updated)
        updated = initial; updated.polls[0].responses = [PollResponse(userID: member, optionIDs: [])]
        XCTAssertNotEqual(initial, updated, "Explicit none must differ from unknown availability.")
        updated = initial; updated.reactions = [MessageReaction(messageID: UUID(), userID: member, emoji: "❤️")]
        XCTAssertNotEqual(initial, updated)
        updated = initial; updated.palActivity = PalWorkActivity(activity: "thinking", jobID: UUID(), status: "accepted", expiresAt: "2026-10-11T20:01:00Z")
        XCTAssertNotEqual(initial, updated)
    }

    func testMessageEqualityIncludesReplyEmotionMentionsAndAttachmentURLChanges() throws {
        let member = UUID(), source = UUID()
        var json: [String: Any] = ["id": UUID().uuidString, "group_id": UUID().uuidString, "role": "pal", "body": "Friday works.", "created_at": "2026-10-11T20:00:00Z"]
        func decode() throws -> ChatMessage { try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json)) }
        let plain = try decode()
        XCTAssertEqual(plain, try decode())
        json["emotion"] = "heureux"
        XCTAssertNotEqual(plain, try decode())
        json.removeValue(forKey: "emotion")
        json["mentions"] = [["type": "user", "user_id": member.uuidString]]
        XCTAssertNotEqual(plain, try decode())
        json.removeValue(forKey: "mentions")
        json["reply"] = ["id": source.uuidString, "sender_id": member.uuidString, "role": "user", "body": "Friday?"]
        XCTAssertNotEqual(plain, try decode())
        json.removeValue(forKey: "reply")
        json["attachments"] = [["id": UUID().uuidString, "kind": "image", "url": "https://example.com/photo?token=old", "mime_type": "image/jpeg", "byte_size": 100]]
        let original = try decode()
        var attachments = try XCTUnwrap(json["attachments"] as? [[String: Any]])
        attachments[0]["url"] = "https://example.com/photo?token=new"
        json["attachments"] = attachments
        XCTAssertNotEqual(original, try decode())
    }

    func testConfirmedReadReceiptUsesServerTimeAndDoesNotRegressOnAnOlderTarget() throws {
        let userID = UUID(), oldID = UUID(), latestID = UUID()
        var member = GroupMember(userID: userID, displayName: "Reader", lastReadAt: "2026-10-11T12:00:00Z", lastReadMessageID: oldID)
        let receipt = try JSONDecoder().decode(PalReadReceipt.self, from: Data("{\"last_read_at\":\"2026-10-11T12:01:00+00:00\"}".utf8))
        receipt.apply(to: &member, messageID: latestID, targetCreatedAt: "2026-10-11T12:01:00Z")
        XCTAssertEqual(member.lastReadMessageID, latestID)
        XCTAssertEqual(member.lastReadAt, "2026-10-11T12:01:00+00:00")
        receipt.apply(to: &member, messageID: oldID, targetCreatedAt: "2026-10-11T12:00:00Z")
        XCTAssertEqual(member.lastReadMessageID, latestID, "A rejected old target must not overwrite the server's newer read marker.")
        let stale = try JSONDecoder().decode(PalReadReceipt.self, from: Data("{\"last_read_at\":\"2026-10-11T11:59:00Z\"}".utf8))
        stale.apply(to: &member, messageID: oldID, targetCreatedAt: "2026-10-11T11:59:00Z")
        XCTAssertEqual(member.lastReadMessageID, latestID)
    }
    @MainActor func testAvatarCacheActuallyReusesDecodedPixelsAcrossSignedURLsAndClearsOnAccountChange() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 800), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        }
        AvatarURLProtocol.prepare(data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AvatarURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = PalImageCache(session: session)
        cache.setOwner(UUID())
        let first = try XCTUnwrap(URL(string: "https://cache.test/storage/v1/object/sign/avatars/user/a.jpg?token=old"))
        let refreshed = try XCTUnwrap(URL(string: "https://cache.test/storage/v1/object/sign/avatars/user/a.jpg?token=new"))
        let decoded = try await cache.image(first)
        let reused = try await cache.image(refreshed)
        XCTAssertTrue(decoded === reused, "Re-signing must reuse the same decoded image without a placeholder flash.")
        XCTAssertEqual(decoded.size, CGSize(width: 512, height: 256))
        XCTAssertEqual(AvatarURLProtocol.requestCount, 1)
        cache.setOwner(UUID())
        XCTAssertNil(cache.cached(first), "Private pixels cannot cross account changes.")
        _ = try await cache.image(refreshed)
        XCTAssertEqual(AvatarURLProtocol.requestCount, 2)
    }
    @MainActor func testOverlappingReadsShareOneRequestAndCompletedReadsRevalidate() async throws {
        let pool = PalFetchPool()
        var calls = 0
        let operation: @MainActor () async throws -> Data = {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            return Data("snapshot".utf8)
        }
        async let first = pool.value(for: "owner/messages", operation: operation)
        async let second = pool.value(for: "owner/messages", operation: operation)
        let values = try await (first, second)
        XCTAssertEqual(values.0, values.1)
        XCTAssertEqual(calls, 1)
        _ = try await pool.value(for: "owner/messages", operation: operation)
        XCTAssertEqual(calls, 2, "Later refreshes must reach the server, rather than freezing an old transcript.")
    }

    @MainActor func testCancelledScreenDoesNotCancelAnotherReadersSnapshot() async throws {
        let pool = PalFetchPool()
        var calls = 0
        let operation: @MainActor () async throws -> Data = {
            calls += 1
            try await Task.sleep(for: .milliseconds(40))
            return Data([42])
        }
        let leaving = Task { try await pool.value(for: "messages", operation: operation) }
        try await Task.sleep(for: .milliseconds(5))
        let visible = Task { try await pool.value(for: "messages", operation: operation) }
        leaving.cancel()
        do { _ = try await leaving.value; XCTFail("The leaving screen must not apply the snapshot.") }
        catch { XCTAssertTrue(PalCancellation.isCancellation(error)) }
        let result = try await visible.value
        XCTAssertEqual(result, Data([42]))
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testFailuresCanRetryAndLogoutRejectsLateUncancellableResults() async throws {
        let pool = PalFetchPool()
        do { _ = try await pool.value(for: "profile") { throw PalFailure(message: "Offline") }; XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, "Offline") }
        let retry = try await pool.value(for: "profile") { Data([1]) }
        XCTAssertEqual(retry, Data([1]))
        var continuation: CheckedContinuation<Data, Never>?
        let late = Task {
            try await pool.value(for: "profile") { await withCheckedContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        pool.clear()
        continuation?.resume(returning: Data([2]))
        do { _ = try await late.value; XCTFail("An old account must never apply a late read.") }
        catch { XCTAssertTrue(PalCancellation.isCancellation(error)) }
        let current = try await pool.value(for: "profile") { Data([3]) }
        XCTAssertEqual(current, Data([3]))
    }

    @MainActor func testMutationInvalidatesOnlyRelatedSnapshotsAndDoesNotCancelOtherReads() async throws {
        let pool = PalFetchPool()
        var related: CheckedContinuation<Data, Never>?
        var unrelated: CheckedContinuation<Data, Never>?
        let beforeWrite = Task { try await pool.value(for: "owner/group/state") { await withCheckedContinuation { related = $0 } } }
        let profile = Task { try await pool.value(for: "owner/profile") { await withCheckedContinuation { unrelated = $0 } } }
        while related == nil || unrelated == nil { await Task.yield() }
        pool.invalidate { $0.hasSuffix("/state") }
        let afterWrite = try await pool.value(for: "owner/group/state") { Data([9]) }
        related?.resume(returning: Data([1])); unrelated?.resume(returning: Data([2]))
        do { _ = try await beforeWrite.value; XCTFail("The stale pre-write snapshot must not overwrite the new value.") }
        catch { XCTAssertTrue(PalCancellation.isCancellation(error)) }
        let untouched = try await profile.value
        XCTAssertEqual(untouched, Data([2]))
        XCTAssertEqual(afterWrite, Data([9]))
    }

    func testAttachmentDimensionsStayFixedAcrossLoadingAndSignedURLRotation() {
        let id = UUID()
        let original = ChatAttachment(id: id, kind: "image", url: URL(string: "https://example.com/a?token=one"), mimeType: "image/jpeg", byteSize: 1, width: 800, height: 1600)
        var refreshed = original; refreshed.url = URL(string: "https://example.com/a?token=two")
        var unavailable = original; unavailable.url = nil
        XCTAssertEqual(original.displaySize, CGSize(width: 140, height: 280))
        XCTAssertEqual(original.displaySize, refreshed.displaySize)
        XCTAssertEqual(original.displaySize, unavailable.displaySize)
        var landscape = original; landscape.width = 1600; landscape.height = 800
        XCTAssertEqual(landscape.displaySize, CGSize(width: 240, height: 120))
        var unknown = original; unknown.width = nil; unknown.height = nil
        XCTAssertEqual(unknown.displaySize, CGSize(width: 160, height: 120))
    }

    func testFetchStateKeepsConfirmedContentOnFailureAndDoesNotTreatCancellationAsAnError() {
        var state = PalFetchState()
        XCTAssertFalse(state.hasLoaded)
        state.begin(); state.begin(); state.finish()
        XCTAssertTrue(state.isLoading, "One completed reader cannot hide another active refresh.")
        XCTAssertTrue(state.hasLoaded)
        state.fail(PalFailure(message: "Offline"))
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.hasLoaded)
        XCTAssertEqual(state.issue, "Offline")
        state.begin(); state.fail(CancellationError())
        XCTAssertNil(state.issue)
        XCTAssertTrue(state.hasLoaded)
    }

    @MainActor func testSignedAvatarIdentityIgnoresOnlySignatureRotationNotNewPhotoOrHost() throws {
        let first = try XCTUnwrap(URL(string: "https://project.supabase.co/storage/v1/object/sign/avatars/user/a.jpg?token=old"))
        let refreshed = try XCTUnwrap(URL(string: "https://project.supabase.co/storage/v1/object/sign/avatars/user/a.jpg?token=new"))
        let changed = try XCTUnwrap(URL(string: "https://project.supabase.co/storage/v1/object/sign/avatars/user/b.jpg?token=new"))
        let otherHost = try XCTUnwrap(URL(string: "https://other.supabase.co/storage/v1/object/sign/avatars/user/a.jpg?token=new"))
        XCTAssertEqual(PalImageCache.key(for: first), PalImageCache.key(for: refreshed))
        XCTAssertNotEqual(PalImageCache.key(for: first), PalImageCache.key(for: changed))
        XCTAssertNotEqual(PalImageCache.key(for: first), PalImageCache.key(for: otherHost))
        let external = try XCTUnwrap(URL(string: "https://images.example/photo?id=1"))
        let externalOther = try XCTUnwrap(URL(string: "https://images.example/photo?id=2"))
        XCTAssertNotEqual(PalImageCache.key(for: external), PalImageCache.key(for: externalOther))
    }
}

private final class AvatarURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func prepare(_ data: Data) { lock.lock(); defer { lock.unlock() }; responseData = data; count = 0 }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cache.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let data = Self.responseData; Self.count += 1; Self.lock.unlock()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class ChatRenderNavigation: ObservableObject {
    @Published var path: [ChatGroup] = []
}

private struct ChatRenderHost: View {
    let group: ChatGroup
    @ObservedObject var navigation: ChatRenderNavigation
    let pushed: Bool
    var body: some View {
        NavigationStack(path: $navigation.path) {
            Group {
                if pushed { Text("Fixture inbox") }
                else { ChatView(group: group) }
            }.navigationDestination(for: ChatGroup.self) { ChatView(group: $0) }
        }
    }
}

private final class ChatRenderURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var history = Data()
    static func prepare(_ data: Data) { lock.lock(); defer { lock.unlock() }; history = data }
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "Authorization") == "Bearer chat-render-fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let data = request.url?.path.hasSuffix("/messages") == true ? Self.history : Data("{}".utf8); Self.lock.unlock()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
