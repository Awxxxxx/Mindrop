import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch store.session {
            case .welcome:
                WelcomeView()
            case .authenticated, .offline:
                MainView()
            }

            if let toast = store.toast {
                ToastView(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .preferredColorScheme(store.followsSystemAppearance ? nil : .light)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.session)
        .animation(.easeInOut(duration: 0.2), value: store.toast)
        .task(id: store.session) {
            guard store.session == .authenticated else { return }
            await store.refreshCloudDataFromServer()
            await store.refreshRemotePushRegistration()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.recycleExpiredReminders()
                guard store.session == .authenticated else { return }
                Task {
                    await store.refreshCloudDataFromServer()
                    await store.refreshRemotePushRegistration()
                }
            case .inactive:
                store.flushLocalSnapshot()
            case .background:
                store.flushPendingCloudChanges()
            @unknown default:
                break
            }
        }
    }
}
