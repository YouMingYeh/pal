import SwiftUI
import WebKit

enum PalMascotActivity { case idle, thinking, speaking }

enum PalMascotEmotion {
    static let all = ["fier", "heureux", "hilare", "curieux", "confus", "surpris", "timide", "triste", "colere", "somnolent", "attentif", "neutre"]
    static func normalized(_ value: String?) -> String {
        guard let value, all.contains(value) else { return "fier" }
        return value
    }
}

struct PalMascotAvatar: View {
    var emotion: String? = nil
    var activity: PalMascotActivity = .idle
    var animated = false
    var size: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false
    @State private var visible = false
    @State private var windowBounds: CGRect = .zero
    @State private var ready = false
    @State private var failed = false
    private var expression: String { activity == .thinking ? "attentif" : PalMascotEmotion.normalized(emotion) }
    private var live: Bool { animated && appeared && visible && scenePhase == .active && !reduceMotion && !failed }

    var body: some View {
        let motion = live && activity != .thinking ? PalMascotFrames.image(for: expression) : nil
        ZStack {
            Image("PalMascot-" + expression).resizable().scaledToFit()
                .frame(width: size * 1.5, height: size * 1.5)
                .opacity(live && (activity == .thinking ? ready : motion != nil) ? 0 : 1)
            if live {
                if activity == .thinking { player }
                else if let motion {
                    MascotFramePlayer(image: motion, emotion: expression, activity: activity)
                        .frame(width: size * 1.5, height: size * 1.5)
                }
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false).accessibilityHidden(true)
        .onGeometryChange(for: Bool.self) { geometry in
            let frame = geometry.frame(in: .global)
            return frame.width > 0 && frame.height > 0 && frame.intersects(windowBounds)
        } action: { visible = $0 }
        .onAppear { appeared = true; updateWindowBounds() }
        .onDisappear { appeared = false; visible = false; ready = false }
        .onChange(of: live) { _, _ in ready = false }
        .onChange(of: animated) { _, _ in failed = false; ready = false }
        .onChange(of: activity) { _, _ in failed = false }
        .onChange(of: emotion) { _, _ in failed = false }
        .onChange(of: scenePhase) { _, value in if value == .active { updateWindowBounds() } }
    }
    private func updateWindowBounds() {
        // Geometry transforms may run on SwiftUI's renderer thread; UIKit reads stay in UI callbacks.
        windowBounds = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.bounds ?? .zero
    }
    private var player: some View {
        MascotWebPlayer(expression: expression, ready: $ready, failed: $failed)
            .frame(width: size * 1.5, height: size * 1.5)
            .opacity(ready ? 1 : 0)
    }
}

@MainActor enum PalMascotFrames {
    private static var cache: [String: UIImage] = [:]
    static func image(for emotion: String) -> UIImage? {
        let expression = PalMascotEmotion.normalized(emotion)
        if let image = cache[expression] { return image }
        let forward = (0..<64).compactMap { UIImage(named: "PalMascotMotion-\(expression)-\($0)") }
        guard forward.count == 64 else { return nil }
        // Reuse the same decoded frames on the return path; adjacent samples meet at both ends.
        let frames = forward + forward.dropFirst().dropLast().reversed()
        guard let image = UIImage.animatedImage(with: frames, duration: Double(frames.count) / 16) else { return nil }
        cache[expression] = image
        return image
    }
}

struct MascotFramePlayer: UIViewRepresentable {
    let image: UIImage
    var emotion = "fier"
    var activity: PalMascotActivity = .idle
    final class Coordinator { var motion: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        // The source raster is larger than its display canvas; it must never set the avatar's layout.
        return CGSize(width: width, height: height)
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image.images?.first {
            view.stopAnimating()
            view.image = image.images?.first
            view.animationImages = image.images
            view.animationDuration = image.duration
            view.animationRepeatCount = 0
        }
        if !view.isAnimating { view.startAnimating() }
        let motion = "\(emotion)-\(activity)"
        if context.coordinator.motion != motion {
            context.coordinator.motion = motion
            view.layer.removeAnimation(forKey: "PalMascotBody")
            if let animation = bodyAnimation() { view.layer.add(animation, forKey: "PalMascotBody") }
        }
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        view.stopAnimating()
        view.animationImages = nil
        view.layer.removeAnimation(forKey: "PalMascotBody")
    }
    private func bodyAnimation() -> CAKeyframeAnimation? {
        let poses: [CGAffineTransform], times: [Double], duration: Double
        switch emotion {
        case "heureux", "hilare":
            poses = [.identity, CGAffineTransform(translationX: 0, y: -3).scaledBy(x: 1.03, y: 0.97), CGAffineTransform(scaleX: 0.98, y: 1.02), .identity, .identity]
            times = [0, 0.25, 0.4, 0.65, 1]; duration = 1.7
        case "timide":
            poses = [CGAffineTransform(rotationAngle: -.pi / 36), CGAffineTransform(rotationAngle: .pi / 36).translatedBy(x: 0, y: 1), CGAffineTransform(rotationAngle: -.pi / 36)]
            times = [0, 0.5, 1]; duration = 2.8
        case "confus":
            poses = [.identity, CGAffineTransform(rotationAngle: -.pi / 20), CGAffineTransform(rotationAngle: -.pi / 20), .identity]
            times = [0, 0.35, 0.65, 1]; duration = 3
        case "colere":
            poses = [.identity, CGAffineTransform(translationX: -1, y: 0), CGAffineTransform(translationX: 1, y: 0), CGAffineTransform(translationX: -1, y: 0), .identity, .identity]
            times = [0, 0.2, 0.3, 0.4, 0.7, 1]; duration = 1.8
        default:
            if activity == .speaking {
                poses = [CGAffineTransform(rotationAngle: -.pi / 90), CGAffineTransform(translationX: 0, y: -2).rotated(by: .pi / 90), CGAffineTransform(rotationAngle: -.pi / 90)]
                times = [0, 0.5, 1]; duration = 1.1
            } else {
                poses = [.identity, CGAffineTransform(scaleX: 1.025, y: 1.025), .identity]
                times = [0, 0.5, 1]; duration = 2.8
            }
        }
        // Match the supplied demo's emotion CSS without a SwiftUI redraw loop.
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = poses.map { NSValue(caTransform3D: CATransform3DMakeAffineTransform($0)) }
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.timingFunctions = (1..<times.count).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        animation.duration = duration
        animation.repeatCount = .infinity
        return animation
    }
}

struct MascotWebPlayer: UIViewRepresentable {
    let expression: String
    @Binding var ready: Bool
    @Binding var failed: Bool
    func makeCoordinator() -> Coordinator { Coordinator(ready: $ready, failed: $failed) }
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        return container
    }
    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.expression = expression
        PalMascotPlayer.shared.acquire(context.coordinator, container: container)
    }
    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        PalMascotPlayer.shared.release(coordinator)
    }
    @MainActor final class Coordinator {
        var expression = "fier"
        fileprivate var active = false
        let ready: Binding<Bool>
        let failed: Binding<Bool>
        init(ready: Binding<Bool>, failed: Binding<Bool>) { self.ready = ready; self.failed = failed }
        func loaded() {
            DispatchQueue.main.async {
                guard self.active else { return }
                self.ready.wrappedValue = true
            }
        }
        func unloaded() {
            active = false
            DispatchQueue.main.async {
                guard !self.active else { return }
                self.ready.wrappedValue = false
            }
        }
        func fallback() {
            active = false
            DispatchQueue.main.async {
                guard !self.active else { return }
                self.ready.wrappedValue = false; self.failed.wrappedValue = true
            }
        }
    }
}

@MainActor final class PalMascotPlayer: NSObject, WKNavigationDelegate {
    static let shared = PalMascotPlayer()
    private(set) weak var owner: MascotWebPlayer.Coordinator?
    private(set) var webView: WKWebView?
    private var fileURL: URL?
    private var loaded = false
    private var expression: String?

    func acquire(_ coordinator: MascotWebPlayer.Coordinator, container: UIView) {
        if owner !== coordinator {
            owner?.fallback()
            owner = coordinator
            webView?.removeFromSuperview()
            expression = nil
        }
        coordinator.active = true
        if webView == nil {
            guard let file = Bundle.main.url(forResource: "Cloud", withExtension: "html", subdirectory: "Mascot") else {
                coordinator.fallback(); return
            }
            fileURL = file
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
            web.scrollView.isScrollEnabled = false; web.isUserInteractionEnabled = false
            web.navigationDelegate = self
            webView = web
            web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
        guard let webView else { return }
        if webView.superview !== container {
            container.addSubview(webView)
            webView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        if loaded { configure() }
    }

    func release(_ coordinator: MascotWebPlayer.Coordinator) {
        coordinator.unloaded()
        guard owner === coordinator else { return }
        owner = nil; loaded = false; expression = nil
        webView?.evaluateJavaScript("window.Mascot?.configure({active:false}); window.Mascot?.dispose()", completionHandler: nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil; fileURL = nil
    }

    private func configure() {
        guard let owner, let webView, owner.expression != expression else { return }
        expression = owner.expression
        let values: [String: Any] = ["state": "idle", "expression": owner.expression, "ink": PalTheme.mascotInkHex, "paper": PalTheme.mascotPaperHex, "active": true, "reducedMotion": false]
        guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else {
            fail(); return
        }
        webView.evaluateJavaScript("if (!window.Mascot) throw new Error('Missing mascot player'); window.Mascot.configure(\(json));") { [weak self, weak owner] _, error in
            guard let self, self.owner === owner else { return }
            if error == nil { owner?.loaded() }
            else { self.fail() }
        }
    }

    private func fail() {
        guard let owner else { return }
        owner.fallback()
        release(owner)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        loaded = true
        configure()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { fail() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { fail() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if self.webView === webView { fail() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true && url?.standardizedFileURL == fileURL?.standardizedFileURL ? .allow : .cancel)
    }
}
