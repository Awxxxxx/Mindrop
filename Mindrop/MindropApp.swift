import SwiftUI

@main
struct MindropApp: App {
    @UIApplicationDelegateAdaptor(MindropAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task {
                    await MindropQuickVoiceRemoteService.shared.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        store.reloadSharedSnapshotIfNeeded()
                        Task {
                            await MindropQuickVoiceRemoteService.shared.start()
                        }
                    }
                }
        }
    }
}
