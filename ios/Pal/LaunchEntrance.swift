import SwiftUI

struct PalLaunchEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = true
    @State private var started = false
    @State private var opacity = 1.0
    @State private var scale = 1.0

    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                ZStack {
                    Color(uiColor: .systemBackground)
                    // Same 144-point artwork bounds as the system launch screen.
                    PalMascotAvatar(size: 96).scaleEffect(scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear {
                    guard !started else { return }
                    started = true
                    guard !reduceMotion, scenePhase != .background else { visible = false; return }
                    withAnimation(.easeOut(duration: 0.5), completionCriteria: .logicallyComplete) {
                        opacity = 0
                        scale = 1.035
                    } completion: {
                        visible = false
                    }
                }
            }
        }
        .onChange(of: reduceMotion) { _, reduced in if reduced { visible = false } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { visible = false } }
    }
}
