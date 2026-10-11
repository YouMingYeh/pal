import SwiftUI

@main
struct PalApp: App {
    @StateObject private var store = PalStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
    }
}
