import AVFoundation
import Foundation
import Speech

enum SpeechState: Equatable {
    case idle
    case requestingPermission
    case recording
    case denied
    case failed(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published private(set) var state: SpeechState = .idle
    @Published private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isStoppingIntentionally = false
    private var recognitionSessionID = UUID()
    private var hasPreparedForFirstUse = false

    func toggleRecording() async {
        if state.isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !state.isRecording else { return }
        state = .requestingPermission

        guard await requestPermissions() else {
            state = .denied
            return
        }

        do {
            try beginRecognition()
            state = .recording
        } catch {
            state = .failed("语音识别启动失败")
        }
    }

    func prepareForFirstUse() async {
        guard !hasPreparedForFirstUse, !state.isRecording else { return }
        hasPreparedForFirstUse = true

        guard await requestPermissions() else {
            state = .denied
            return
        }

        _ = recognizer?.isAvailable

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            hasPreparedForFirstUse = false
        }
    }

    func stop() {
        isStoppingIntentionally = true
        recognitionSessionID = UUID()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        state = .idle
    }

    func consumeTranscript() -> String {
        let text = transcript
        transcript = ""
        return text
    }

    private func requestPermissions() async -> Bool {
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard speechGranted else { return false }

        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func beginRecognition() throws {
        task?.cancel()
        task = nil
        transcript = ""
        isStoppingIntentionally = false
        let sessionID = UUID()
        recognitionSessionID = sessionID

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                guard self.recognitionSessionID == sessionID else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil {
                    guard !self.isStoppingIntentionally else { return }
                    self.stop()
                    self.state = .failed("语音识别中断")
                }
            }
        }
    }
}
