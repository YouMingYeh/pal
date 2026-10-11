import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let extensionContext else { return }
        let host = UIHostingController(rootView: ShareView(context: extensionContext).tint(PalTheme.ink))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private struct ShareView: View {
    let context: NSExtensionContext
    @StateObject private var store = PalStore()
    @State private var bodyText = ""
    @State private var groupID: UUID?
    @State private var clientID = UUID()
    @State private var attempted = false
    @State private var loading = true
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    ProgressView("Loading shared content…")
                } else if !store.isSignedIn {
                    Text("Open Pal and sign in, then share again.")
                } else {
                    Section("Share to") {
                        if store.groups.isEmpty {
                            Text("Open Pal to create or join a group, then share again.")
                        } else {
                            Picker("Group", selection: $groupID) {
                                ForEach(store.groups) { group in
                                    Text(group.name).tag(Optional(group.id))
                                }
                            }
                            .disabled(attempted || sending)
                        }
                    }
                    if !bodyText.isEmpty {
                        Section("Shared content") {
                            Text(bodyText).textSelection(.enabled)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(PalTheme.error)
                        if !attempted {
                            Button("Try again") { Task { await load() } }
                        }
                    }
                }
            }
            .navigationTitle("Share to Pal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        context.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                    }
                    .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(attempted ? "Retry" : "Send") { Task { await send() } }
                        .disabled(loading || sending || bodyText.isEmpty || groupID == nil || !store.isSignedIn)
                }
            }
            .overlay {
                if sending { ProgressView("Sending…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard !attempted else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            var values: [String] = []
            for item in context.inputItems.compactMap({ $0 as? NSExtensionItem }) {
                if let text = item.attributedContentText?.string { values.append(text) }
                for provider in item.attachments ?? [] {
                    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                       provider.canLoadObject(ofClass: NSURL.self) {
                        values.append(try await readURL(provider))
                    }
                    if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                       provider.canLoadObject(ofClass: NSString.self) {
                        values.append(try await readText(provider))
                    }
                }
            }
            bodyText = SharePayload.body(from: values)
            guard !bodyText.isEmpty else { throw PalFailure(message: "No supported link or text was shared.") }
            guard store.isSignedIn else { return }
            try await store.loadGroups()
            if groupID == nil { groupID = store.groups.first?.id }
        } catch {
            if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    private func send() async {
        guard !sending, let group = store.groups.first(where: { $0.id == groupID }) else { return }
        attempted = true
        sending = true
        error = nil
        defer { sending = false }
        do {
            // The same body, group, and client ID survive an uncertain server response.
            try await store.send(bodyText, to: group, clientID: clientID)
            context.completeRequest(returningItems: nil)
        } catch {
            if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    private func readURL(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let url = value as? URL { continuation.resume(returning: url.absoluteString) }
                else { continuation.resume(throwing: PalFailure(message: "Unable to read the shared link.")) }
            }
        }
    }

    private func readText(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let text = value as? String { continuation.resume(returning: text) }
                else { continuation.resume(throwing: PalFailure(message: "Unable to read the shared text.")) }
            }
        }
    }
}
