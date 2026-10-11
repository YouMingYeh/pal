import SwiftUI

struct PalFetchStatusView: View {
    var state: PalFetchState
    var hasContent: Bool
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            if let issue = state.issue {
                Text(hasContent ? "Couldn’t update" : "Couldn’t load").font(.subheadline.weight(.medium))
                Text(issue).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again", action: retry).disabled(state.isLoading).tint(PalTheme.accentText)
            } else if !hasContent { ProgressView("Loading…") }
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}
