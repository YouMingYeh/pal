import XCTest
import SwiftUI
import WebKit
@testable import Pal

final class MascotTests: XCTestCase {
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
