import ActivityKit
import Foundation

enum MindropQuickVoicePhase: String, Codable, Hashable {
    case recording
    case processing
    case completed
    case failed
    case permissionDenied
}

struct MindropQuickVoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: MindropQuickVoicePhase
        var transcript: String
        var response: String
        var updatedAt: Date
        var waveformSeed: Int

        init(
            phase: MindropQuickVoicePhase,
            transcript: String = "",
            response: String = "",
            updatedAt: Date = .now,
            waveformSeed: Int = 0
        ) {
            self.phase = phase
            self.transcript = transcript
            self.response = response
            self.updatedAt = updatedAt
            self.waveformSeed = waveformSeed
        }
    }

    var sessionID: String
    var startedAt: Date
    var isDiagnostic: Bool = false
}
