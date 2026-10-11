import SwiftUI

@main
struct PalApp: App {
    @UIApplicationDelegateAdaptor(PalAppDelegate.self) private var appDelegate
    @StateObject private var store = PalStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
    }
}
