import SwiftUI

@main
struct MindropApp: App {
    @UIApplicationDelegateAdaptor(MindropAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
