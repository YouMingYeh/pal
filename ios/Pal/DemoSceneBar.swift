import SwiftUI

/// Composer suggestions never replace text being written, and carry their original retry metadata.
struct DemoComposerState {
    struct Submission: Equatable {
        let step: Int
        let generation: UUID
        let body: String
    }
    private struct Prefill {
        let sceneID: String
        let submission: Submission
    }
    private var seen = Set<String>()
    private var prefill: Prefill?

    mutating func suggestion(for demo: DemoState?, isDemo: Bool, draft: String, isEditing: Bool,
                             hasPending: Bool, hasAttachment: Bool, hasReply: Bool) -> String? {
        guard isDemo, let demo, demo.canAdvance, let prompt = demo.nextPrompt,
              !seen.contains(demo.sceneID), !isEditing, !hasPending,
              !hasAttachment, !hasReply else { return nil }
        let replacesUntouchedPrefill = prefill.map { $0.sceneID != demo.sceneID && draft == $0.submission.body } ?? false
        guard draft.isEmpty || replacesUntouchedPrefill else { return nil }
        seen.insert(demo.sceneID)
        prefill = Prefill(sceneID: demo.sceneID, submission: Submission(step: demo.step, generation: demo.generation, body: prompt))
        return prompt
    }

    mutating func submission(for body: String, demo: DemoState?, hasAttachment: Bool, hasReply: Bool) -> Submission? {
        defer { prefill = nil }
        guard let prefill, let demo, demo.canAdvance, prefill.sceneID == demo.sceneID,
              body == prefill.submission.body, !hasAttachment, !hasReply else { return nil }
        return prefill.submission
    }
}

struct DemoRestartControl: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    @State private var confirmation = false
    @State private var busy = false
    @State private var issue: String?
    private var hasPending: Bool { store.outgoing.contains { $0.groupID == group.id } }
    var body: some View {
        Menu {
            Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) { confirmation = true }.disabled(busy || hasPending)
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(PalTheme.ink)
        }.accessibilityLabel("Conversation options")
            .confirmationDialog("Start over?", isPresented: $confirmation, titleVisibility: .visible) {
                Button("Start over", role: .destructive) {
                    guard !busy, !hasPending else { return }
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await store.resetDemo(group) }
                        catch { if !PalCancellation.isCancellation(error) { issue = error.localizedDescription } }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This clears this conversation and its generated plans, then starts it over.") }
            .alert("Couldn’t start over", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
    }
}
