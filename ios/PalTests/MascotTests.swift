import XCTest
import SwiftUI
import WebKit
@testable import Pal

final class MascotTests: XCTestCase {
    @MainActor func testEveryEmotionSharesARealAnimatedFrameSequence() throws {
        for emotion in PalMascotEmotion.all {
            let image = try XCTUnwrap(PalMascotFrames.image(for: emotion))
            let frames = try XCTUnwrap(image.images)
            XCTAssertEqual(frames.count, 32)
            XCTAssertEqual(image.duration, 4)
            XCTAssertEqual(frames.first?.size, CGSize(width: 128, height: 128))
            XCTAssertTrue(image === PalMascotFrames.image(for: emotion))
            XCTAssertNotEqual(frames[0].pngData(), frames[12].pngData(), "The supplied engine blink must change the actual rendered face.")
        }
        XCTAssertTrue(PalMascotFrames.image(for: "unknown") === PalMascotFrames.image(for: "fier"))
    }

    @MainActor func testVisibleNativeAvatarsActuallyPlayAndRenderDifferentPixels() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { throw XCTSkip("Reduce Motion intentionally keeps avatars still.") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        let previous = window.rootViewController
        let host = UIHostingController(rootView: AnyView(VStack(spacing: 25) {
            PalMascotAvatar(emotion: "fier", animated: true, size: 40)
            PalMascotAvatar(emotion: "heureux", animated: true, size: 40)
            PalMascotAvatar(emotion: "triste", animated: true, size: 40)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
            .environment(\.scenePhase, .active)))
        window.rootViewController = host
        defer { window.rootViewController = previous }
        host.view.layoutIfNeeded(); window.layoutIfNeeded()
        func players(_ view: UIView) -> [UIImageView] {
            ((view as? UIImageView).map { [$0] } ?? []) + view.subviews.flatMap(players)
        }
        let deadline = Date().addingTimeInterval(3)
        while players(host.view).filter({ $0.animationImages != nil }).count < 3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let animated = players(host.view).filter { $0.animationImages != nil }
        let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        screenshot.name = "Mounted native mascot runtime"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertEqual(animated.count, 3, "Every visible avatar must reach the actual native frame player.")
        XCTAssertTrue(animated.allSatisfy { $0.isAnimating && $0.window != nil && $0.bounds.width > 0 })
        func pixels() -> [Data?] {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            return animated.map { view in
                let rect = view.convert(view.bounds, to: window).insetBy(dx: -5, dy: -5)
                let pixels = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale, width: rect.width * image.scale, height: rect.height * image.scale)
                return image.cgImage?.cropping(to: pixels).flatMap { UIImage(cgImage: $0).pngData() }
            }
        }
        let initial = pixels()
        XCTAssertTrue(initial.allSatisfy { $0 != nil })
        var changed = Array(repeating: false, count: animated.count)
        for _ in 0..<32 {
            try await Task.sleep(for: .milliseconds(125))
            let current = pixels()
            for index in changed.indices where current[index] != initial[index] { changed[index] = true }
            if !changed.contains(false) { break }
        }
        XCTAssertEqual(changed, [true, true, true], "Every actual avatar, including fier's blink, must render changing on-screen pixels.")
        host.rootView = AnyView(PalMascotAvatar(emotion: "fier", animated: true, size: 40)
            .environment(\.scenePhase, .background))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(players(host.view).contains { $0.isAnimating }, "Backgrounding must stop actual native rendering.")
    }

    @MainActor func testBundledPlayerRunsPausesTransfersAndDisposes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let firstContainer = UIView(frame: CGRect(x: 20, y: 20, width: 100, height: 100))
        let secondContainer = UIView(frame: CGRect(x: 140, y: 20, width: 100, height: 100))
        host.view.addSubview(firstContainer)
        host.view.addSubview(secondContainer)
        let firstState = PlayerState(), secondState = PlayerState()
        let first = firstState.coordinator(), second = secondState.coordinator()
        first.expression = "attentif"
        second.expression = "heureux"
        let lease = PalMascotPlayer.shared
        defer {
            lease.release(first); lease.release(second)
            window.isHidden = true
            previousWindow?.makeKey()
        }

        lease.acquire(first, container: firstContainer)
        try await eventually { firstState.ready || firstState.failed }
        XCTAssertFalse(firstState.failed, "The actual bundled HTML must load and configure.")
        XCTAssertTrue(firstState.ready)
        let web = try XCTUnwrap(lease.webView)
        window.layoutIfNeeded(); host.view.layoutIfNeeded(); firstContainer.layoutIfNeeded()
        XCTAssertGreaterThan(web.bounds.width, 0)
        XCTAssertGreaterThan(web.bounds.height, 0)
        XCTAssertTrue(web.superview === firstContainer)
        XCTAssertTrue(lease.owner === first)
        try await assertString("document.querySelector('svg').getAttribute('data-state')", in: web, equals: "idle")
        try await assertString("document.querySelector('svg').getAttribute('data-expression')", in: web, equals: "attentif")
        try await assertString("String(document.hidden)", in: web, equals: "false")
        let initial = try await string("document.querySelector('svg').innerHTML", in: web)
        XCTAssertTrue(initial.contains("#ff7a1a"))
        XCTAssertTrue(initial.contains("#fffff5"))
        var changed = false
        let frameDeadline = Date().addingTimeInterval(4)
        while !changed, Date() < frameDeadline {
            try await Task.sleep(for: .milliseconds(100))
            changed = try await string("document.querySelector('svg').innerHTML", in: web) != initial
        }
        XCTAssertTrue(changed, "The real SVG should change while the player is active.")

        _ = try await web.evaluateJavaScript("window.Mascot.configure({active:false})")
        let paused = try await string("document.querySelector('svg').innerHTML", in: web)
        try await assertString("document.querySelector('svg').getAttribute('data-active')", in: web, equals: "false")
        try await Task.sleep(for: .milliseconds(250))
        let pausedLater = try await string("document.querySelector('svg').innerHTML", in: web)
        XCTAssertEqual(paused, pausedLater, "Pausing must freeze the actual rendered SVG.")

        lease.acquire(second, container: secondContainer)
        try await eventually { secondState.ready || secondState.failed }
        XCTAssertFalse(secondState.failed)
        XCTAssertFalse(firstState.ready, "Transferring the lease revokes the earlier avatar's live rendering.")
        XCTAssertTrue(firstState.failed, "The earlier avatar must fall back to its static artwork.")
        XCTAssertTrue(lease.webView === web, "Ownership transfers reuse the single WKWebView.")
        XCTAssertTrue(lease.owner === second)
        XCTAssertNil(firstContainer.subviews.first)
        XCTAssertTrue(web.superview === secondContainer)
        try await assertString("document.querySelector('svg').getAttribute('data-expression')", in: web, equals: "heureux")
        try await assertString("document.querySelector('svg').getAttribute('data-active')", in: web, equals: "true")
        lease.release(first)
        XCTAssertTrue(lease.webView === web, "An earlier owner's teardown cannot release the new owner's player.")

        lease.release(second)
        try await eventually { !secondState.ready }
        XCTAssertNil(lease.webView)
        XCTAssertNil(lease.owner)
        XCTAssertNil(web.superview)
        // Holding the released web only for this assertion verifies its terminal JS disposal.
        let disposed = try await string("document.querySelector('svg').innerHTML", in: web)
        _ = try await web.evaluateJavaScript("window.Mascot.configure({active:true,expression:'triste'})")
        try await Task.sleep(for: .milliseconds(250))
        let disposedLater = try await string("document.querySelector('svg').innerHTML", in: web)
        XCTAssertEqual(disposed, disposedLater, "Disposed rendering cannot restart even after another configure call.")
        try await assertString("document.querySelector('svg').getAttribute('data-expression')", in: web, equals: "heureux")
    }

    @MainActor private func assertString(_ script: String, in web: WKWebView, equals expected: String) async throws {
        let actual = try await string(script, in: web)
        XCTAssertEqual(actual, expected)
    }

    @MainActor private func string(_ script: String, in web: WKWebView) async throws -> String {
        let value = try await web.evaluateJavaScript(script)
        return try XCTUnwrap(value as? String)
    }

    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "The local WKWebView lifecycle did not complete before the deadline.")
    }

    @MainActor private final class PlayerState {
        var ready = false
        var failed = false
        func coordinator() -> MascotWebPlayer.Coordinator {
            MascotWebPlayer.Coordinator(
                ready: Binding(get: { self.ready }, set: { self.ready = $0 }),
                failed: Binding(get: { self.failed }, set: { self.failed = $0 })
            )
        }
    }
}
