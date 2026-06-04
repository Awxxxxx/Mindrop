import ActivityKit
import Foundation

@MainActor
@available(iOS 18.0, *)
final class MindropQuickVoiceCaptureController {
    static let shared = MindropQuickVoiceCaptureController()

    private let transcriber = SpeechTranscriber()
    private let processor = MindropQuickThoughtProcessor()
    private var activeActivity: Activity<MindropQuickVoiceActivityAttributes>?
    private var monitorTask: Task<Void, Never>?
    private var autoSendTask: Task<Void, Never>?
    private var isSubmitting = false
    private var waveformSeed = 0

    func startDiagnosticProbe(label: String) async -> Activity<MindropQuickVoiceActivityAttributes>? {
        debugLog("DIAGNOSTIC probe requested: \(label)")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            debugLog("DIAGNOSTIC RESULT: live activities disabled by system")
            return nil
        }
        await finishExistingSession()

        let attributes = MindropQuickVoiceActivityAttributes(
            sessionID: UUID().uuidString,
            startedAt: .now,
            isDiagnostic: true
        )
        let initialState = MindropQuickVoiceActivityAttributes.ContentState(
            phase: .recording,
            transcript: "侧键诊断：Live Activity 已请求",
            response: ""
        )

        do {
            activeActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil, relevanceScore: 1),
                pushType: nil,
                style: .standard
            )
            debugLog("DIAGNOSTIC RESULT: live activity success, activity id: \(activeActivity?.id ?? "nil")")
        } catch {
            debugLog("DIAGNOSTIC RESULT: live activity failed: \(error)")
            return nil
        }

        await transcriber.start()
        debugLog("DIAGNOSTIC RESULT: transcriber state after start: \(describe(transcriber.state))")
        guard transcriber.state.isRecording else {
            await handleRecordingStartFailure()
            return activeActivity
        }

        startDiagnosticMonitoring()
        debugLog("DIAGNOSTIC RESULT: recording monitor started")
        return activeActivity
    }

    func start() async -> Activity<MindropQuickVoiceActivityAttributes>? {
        debugLog("start requested")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            debugLog("live activities disabled by system")
            return nil
        }
        await finishExistingSession()

        let attributes = MindropQuickVoiceActivityAttributes(
            sessionID: UUID().uuidString,
            startedAt: .now
        )
        let initialState = MindropQuickVoiceActivityAttributes.ContentState(phase: .recording)

        do {
            activeActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil, relevanceScore: 1),
                pushType: nil,
                style: .standard
            )
            debugLog("live activity requested, session: \(attributes.sessionID), activity id: \(activeActivity?.id ?? "nil")")
        } catch {
            debugLog("live activity request failed: \(error)")
            return nil
        }

        await transcriber.start()
        debugLog("transcriber state after start: \(describe(transcriber.state))")
        guard transcriber.state.isRecording else {
            await handleRecordingStartFailure()
            return nil
        }

        startMonitoringTranscript()
        debugLog("recording monitor started")
        return activeActivity
    }

    func submitFromLiveActivity(sessionID: String? = nil) async {
        debugLog("submit requested, session: \(sessionID ?? "nil")")
        guard !isSubmitting else { return }
        isSubmitting = true
        autoSendTask?.cancel()
        monitorTask?.cancel()

        let activity = activity(for: sessionID)
        let transcript = currentTranscript(from: activity)
        transcriber.stop()

        if activity?.attributes.isDiagnostic == true {
            debugLog("DIAGNOSTIC RESULT: send intent triggered, transcript length: \(transcript.count)")
            await updateCompleted(
                activity,
                transcript: transcript.isEmpty ? "诊断发送按钮已触发，但没有识别到文字。" : transcript,
                response: "诊断完成：Live Activity 按钮可以回调 Intent。"
            )
            await end(activity, after: 4)
            isSubmitting = false
            return
        }

        guard !transcript.isEmpty else {
            debugLog("submit failed: empty transcript")
            await update(
                activity,
                phase: .failed,
                transcript: "",
                response: "我还没听清，可以再说一次。"
            )
            await end(activity, after: 2)
            isSubmitting = false
            return
        }

        await update(activity, phase: .processing, transcript: transcript, response: "")
        let result = await processor.process(transcript: transcript)
        let reply = "小落：\(result.reply)"
        debugLog("processor completed, input length: \(result.input.count), reply length: \(reply.count)")
        await updateCompleted(activity, transcript: result.input, response: reply)
        await end(activity, after: 2)
        isSubmitting = false
    }

    private func startMonitoringTranscript() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var lastTranscript = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard let self else { return }
                await self.monitorTick(lastTranscript: &lastTranscript)
            }
        }
    }

    private func startDiagnosticMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var lastTranscript = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard let self else { return }
                await self.diagnosticMonitorTick(lastTranscript: &lastTranscript)
            }
        }
    }

    private func diagnosticMonitorTick(lastTranscript: inout String) async {
        guard transcriber.state.isRecording, !isSubmitting else { return }
        let transcript = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        waveformSeed += 1
        await update(
            activeActivity,
            phase: .recording,
            transcript: transcript.isEmpty ? "侧键诊断：录音中，等待语音识别结果。" : transcript,
            response: ""
        )

        guard transcript != lastTranscript else { return }
        lastTranscript = transcript
        debugLog("DIAGNOSTIC RESULT: transcript changed, length: \(transcript.count)")
    }

    private func monitorTick(lastTranscript: inout String) async {
        guard transcriber.state.isRecording, !isSubmitting else { return }
        let transcript = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        waveformSeed += 1
        await update(activeActivity, phase: .recording, transcript: transcript, response: "")

        guard !transcript.isEmpty, transcript != lastTranscript else { return }
        lastTranscript = transcript
        scheduleAutoSend(expectedTranscript: transcript)
    }

    private func scheduleAutoSend(expectedTranscript: String) {
        autoSendTask?.cancel()
        autoSendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            await self.submitIfStillSilent(expectedTranscript: expectedTranscript)
        }
    }

    private func submitIfStillSilent(expectedTranscript: String) async {
        guard transcriber.state.isRecording else { return }
        let transcript = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript == expectedTranscript else { return }
        await submitFromLiveActivity(sessionID: activeActivity?.attributes.sessionID)
    }

    private func currentTranscript(from activity: Activity<MindropQuickVoiceActivityAttributes>?) -> String {
        let liveTranscript = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveTranscript.isEmpty {
            return liveTranscript
        }
        return activity?.content.state.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func activity(for sessionID: String?) -> Activity<MindropQuickVoiceActivityAttributes>? {
        if let activeActivity,
           sessionID == nil || activeActivity.attributes.sessionID == sessionID {
            return activeActivity
        }
        guard let sessionID else { return activeActivity ?? Activity<MindropQuickVoiceActivityAttributes>.activities.first }
        return Activity<MindropQuickVoiceActivityAttributes>.activities.first { $0.attributes.sessionID == sessionID }
    }

    private func update(
        _ activity: Activity<MindropQuickVoiceActivityAttributes>?,
        phase: MindropQuickVoicePhase,
        transcript: String,
        response: String
    ) async {
        guard let activity else { return }
        let state = MindropQuickVoiceActivityAttributes.ContentState(
            phase: phase,
            transcript: transcript,
            response: response,
            updatedAt: .now,
            waveformSeed: waveformSeed
        )
        await activity.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 1))
    }

    private func updateCompleted(
        _ activity: Activity<MindropQuickVoiceActivityAttributes>?,
        transcript: String,
        response: String
    ) async {
        guard let activity else { return }
        waveformSeed += 1
        let state = MindropQuickVoiceActivityAttributes.ContentState(
            phase: .completed,
            transcript: transcript,
            response: response,
            updatedAt: .now,
            waveformSeed: waveformSeed
        )
        await activity.update(
            ActivityContent(state: state, staleDate: nil, relevanceScore: 1),
            alertConfiguration: AlertConfiguration(
                title: "小落处理好了",
                body: "\(response)",
                sound: .default
            )
        )
    }

    private func handleRecordingStartFailure() async {
        let phase: MindropQuickVoicePhase
        let response: String
        switch transcriber.state {
        case .denied:
            phase = .permissionDenied
            response = "需要先允许麦克风和语音识别权限。"
        case .failed(let message):
            phase = .failed
            response = message
        default:
            phase = .failed
            response = "语音识别启动失败。"
        }
        debugLog("recording start failed: \(describe(transcriber.state))")
        await update(activeActivity, phase: phase, transcript: "", response: response)
        await end(activeActivity, after: 2)
    }

    private func finishExistingSession() async {
        autoSendTask?.cancel()
        monitorTask?.cancel()
        transcriber.stop()
        isSubmitting = false
        if let activeActivity {
            await activeActivity.end(nil, dismissalPolicy: .immediate)
        }
        for activity in Activity<MindropQuickVoiceActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activeActivity = nil
    }

    private func end(
        _ activity: Activity<MindropQuickVoiceActivityAttributes>?,
        after seconds: TimeInterval
    ) async {
        guard let activity else { return }
        try? await Task.sleep(for: .seconds(seconds))
        await activity.end(activity.content, dismissalPolicy: .immediate)
        if activeActivity?.id == activity.id {
            activeActivity = nil
        }
    }

    private func describe(_ state: SpeechState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .requestingPermission:
            return "requestingPermission"
        case .recording:
            return "recording"
        case .denied:
            return "denied"
        case .failed(let message):
            return "failed(\(message))"
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        print("Mindrop quick voice [\(bundleID)]: \(message)")
        MindropQuickVoiceDiagnostics.append(message, source: bundleID)
        #endif
    }
}
