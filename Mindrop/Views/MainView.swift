import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var transcriber = SpeechTranscriber()
    @State private var draftText = ""
    @State private var voiceStartTask: Task<Void, Never>?
    @State private var shouldFinishVoiceAfterStart = false

    var body: some View {
        TabView(selection: $store.selectedTab) {
            HistoryView()
                .tabItem {
                    Image("HistoryTabIcon")
                    Text("历史")
                }
                .tag(AppTab.history)

            InputView(
                draftText: $draftText,
                speechState: transcriber.state,
                transcript: transcriber.transcript,
                submit: submitDraft,
                startVoiceInput: startVoiceInput,
                finishVoiceInput: finishVoiceInput
            )
            .tabItem {
                Image("MindropTabIcon")
                Text("念落")
            }
            .tag(AppTab.input)

            ProfileView(isActive: store.selectedTab == .profile)
                .tabItem {
                    Image("MeTabIcon")
                    Text("我的")
                }
                .tag(AppTab.profile)
        }
        .tint(Color.mindInk.opacity(0.88))
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.selectedTab)
        .onChange(of: transcriber.transcript) { _, newValue in
            guard transcriber.state.isRecording else { return }
            draftText = newValue
        }
        .onChange(of: transcriber.state) { _, state in
            if case .denied = state {
                store.presentToast("请在系统设置中开启语音识别和麦克风权限")
            }
            if case .failed(let message) = state {
                store.presentToast(message)
            }
        }
        .onChange(of: store.selectedTab) { _, tab in
            guard tab == .input else { return }
            prepareVoiceInput()
        }
    }

    private func submitDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.selectedTab = .input
        store.submitThought(text)
        draftText = ""
    }

    private func toggleVoiceInput() {
        if transcriber.state.isRecording {
            finishVoiceInput()
        } else {
            startVoiceInput()
        }
    }

    private func startVoiceInput() {
        guard voiceStartTask == nil, !transcriber.state.isRecording else { return }
        shouldFinishVoiceAfterStart = false
        voiceStartTask = Task { @MainActor in
            await transcriber.start()
            voiceStartTask = nil
            if shouldFinishVoiceAfterStart {
                shouldFinishVoiceAfterStart = false
                finishVoiceInput()
            }
        }
    }

    private func prepareVoiceInput() {
        Task { @MainActor in
            await transcriber.prepareForFirstUse()
        }
    }

    private func finishVoiceInput() {
        guard transcriber.state.isRecording else {
            if voiceStartTask != nil {
                shouldFinishVoiceAfterStart = true
            } else {
                submitConsumedTranscript()
            }
            return
        }
        shouldFinishVoiceAfterStart = false
        transcriber.stop()
        submitConsumedTranscript()
    }

    private func submitConsumedTranscript() {
        let text = transcriber.consumeTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            draftText = text
            submitDraft()
        }
    }
}
