import ActivityKit
import AppIntents
import Foundation

@available(iOS 18.0, *)
struct MindropStartQuickVoiceIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "语音念落"
    static var description = IntentDescription("通过侧键或控制项快速记录念头。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        MindropQuickVoiceDiagnostics.append("legacy start intent perform entered")
        if let activity = await MindropQuickVoiceCaptureController.shared.startDiagnosticProbe(label: "legacy start intent") {
            return .result(
                actionButtonIntent: MindropSendQuickVoiceIntent(sessionID: activity.attributes.sessionID),
                activityIdentifier: activity.id
            )
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct MindropSendQuickVoiceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "发送给小落"
    static var description = IntentDescription("结束当前语音输入并交给小落处理。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "会话")
    var sessionID: String

    init() {
        sessionID = ""
    }

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func perform() async throws -> some IntentResult {
        if #available(iOS 18.0, *) {
            await MindropQuickVoiceCaptureController.shared.submitFromLiveActivity(sessionID: sessionID)
        }
        return .result()
    }
}

@available(iOS 18.0, *)
struct MindropQuickVoiceProbeIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "侧键诊断"
    static var description = IntentDescription("验证侧键、灵动岛和录音是否能在后台链路中启动。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        MindropQuickVoiceDiagnostics.append("probe intent perform entered")
        if let activity = await MindropQuickVoiceCaptureController.shared.startDiagnosticProbe(label: "probe intent") {
            return .result(
                actionButtonIntent: MindropSendQuickVoiceIntent(sessionID: activity.attributes.sessionID),
                activityIdentifier: activity.id
            )
        }
        return .result()
    }
}

#if !MINDROP_WIDGET_EXTENSION
@available(iOS 18.0, *)
struct MindropShortcutTextProbeIntent: AppIntent {
    static var title: LocalizedStringResource = "快捷文本诊断"
    static var description = IntentDescription("接收快捷指令听写文本，验证念落能否在快捷指令后台保存。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(
        title: "文本",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var text: String

    init() {
        text = ""
    }

    init(text: String) {
        self.text = text
    }

    func perform() async throws -> some IntentResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        MindropQuickVoiceDiagnostics.append("shortcut text probe perform entered, text length: \(trimmed.count)")

        guard !trimmed.isEmpty else {
            MindropQuickVoiceDiagnostics.append("shortcut text probe failed: empty text")
            return .result()
        }

        do {
            let aiResult = try await MindropQuickVoiceRemoteService.shared.capture(text: trimmed)
            let result = MindropQuickThoughtProcessor().apply(transcript: trimmed, result: aiResult)
            MindropQuickVoiceDiagnostics.append(
                "shortcut text probe remote processed, category: \(result.category?.rawValue ?? "nil"), noteID: \(result.noteID?.uuidString ?? "nil")"
            )
            return .result()
        } catch {
            MindropQuickVoiceDiagnostics.append("shortcut text probe remote failed, using local fallback: \(error)")
            let result = await MindropQuickThoughtProcessor().process(transcript: trimmed)
            MindropQuickVoiceDiagnostics.append(
                "shortcut text probe local processed, category: \(result.category?.rawValue ?? "nil"), noteID: \(result.noteID?.uuidString ?? "nil"), fallback: \(result.didUseFallback)"
            )
            return .result()
        }
    }
}

@available(iOS 18.0, *)
struct MindropQuickVoiceShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MindropQuickVoiceProbeIntent(),
            phrases: [
                "用 \(.applicationName) 侧键诊断",
                "让 \(.applicationName) 测试侧键",
                "\(.applicationName) 诊断录音"
            ],
            shortTitle: "侧键诊断",
            systemImageName: "waveform"
        )

        AppShortcut(
            intent: MindropShortcutTextProbeIntent(),
            phrases: [
                "用 \(.applicationName) 保存快捷文本",
                "让 \(.applicationName) 处理听写文本",
                "\(.applicationName) 快捷文本诊断"
            ],
            shortTitle: "快捷文本诊断",
            systemImageName: "text.bubble"
        )
    }
}
#endif
