import ActivityKit
import Foundation

actor MindropQuickVoiceRemoteService {
    static let shared = MindropQuickVoiceRemoteService()

    private let deviceSecretKey = "mindrop.quickVoice.deviceSecret.v1"
    private let lastUploadedTokenKey = "mindrop.quickVoice.lastPushToStartToken.v1"
    private let chatHistoryLimit = 100
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let aiService = AIService()

    private var tokenObservationTask: Task<Void, Never>?
    private var activityObservationTask: Task<Void, Never>?
    private var monitoredActivityIDs = Set<String>()
    private var scheduledEndActivityIDs = Set<String>()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start() {
        if tokenObservationTask == nil {
            tokenObservationTask = Task { await observePushToStartTokens() }
        }
        if activityObservationTask == nil {
            activityObservationTask = Task { await observeRemoteActivities() }
        }
    }

    func capture(text rawText: String) async throws -> AIAnalysisResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MindropQuickVoiceRemoteError.emptyText }
        guard let endpoint = AIService.quickVoiceCaptureEndpoint else {
            throw MindropQuickVoiceRemoteError.endpointNotConfigured
        }

        let snapshot = Self.currentSnapshot()
        let context = Array(snapshot.messages.suffix(10))
        let reminders = Self.reminderCandidates(in: snapshot.notes)
        let qaNotes = Self.qaCandidates(in: snapshot.notes, context: context)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 34
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            QuickVoiceCaptureRequest(
                deviceID: PushNotificationService.shared.deviceID,
                deviceSecret: deviceSecret(),
                environment: PushNotificationService.shared.environment,
                appBundleID: Bundle.main.bundleIdentifier ?? "app.mindrop.ios",
                text: text,
                context: context.map(QuickVoiceContextMessage.init),
                reminders: reminders.prefix(20).map { QuickVoiceReminderCandidate(note: $0) },
                qaNotes: qaNotes.prefix(1).map { QuickVoiceNoteCandidate(note: $0) },
                now: Self.isoFormatter.string(from: .now),
                timeZone: TimeZone.current.identifier,
                thinkingEnabled: false
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MindropQuickVoiceRemoteError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw MindropQuickVoiceRemoteError.serverError(httpResponse.statusCode, detail)
        }

        logLiveActivityDeliveryIfPresent(data)
        return try aiService.decodeAnalyzeResponse(data, sourceText: text)
    }

    private func observePushToStartTokens() async {
        guard #available(iOS 17.2, *) else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            MindropQuickVoiceDiagnostics.append("remote quick voice skipped: live activities disabled by system")
            return
        }

        if let tokenData = Activity<MindropQuickVoiceActivityAttributes>.pushToStartToken {
            await uploadPushToStartToken(tokenData)
        } else {
            MindropQuickVoiceDiagnostics.append("remote quick voice push-to-start token unavailable at launch")
        }

        for await tokenData in Activity<MindropQuickVoiceActivityAttributes>.pushToStartTokenUpdates {
            await uploadPushToStartToken(tokenData)
        }
    }

    private func observeRemoteActivities() async {
        for activity in Activity<MindropQuickVoiceActivityAttributes>.activities {
            await monitorRemoteActivity(activity)
        }

        for await activity in Activity<MindropQuickVoiceActivityAttributes>.activityUpdates {
            await monitorRemoteActivity(activity)
        }
    }

    private func monitorRemoteActivity(_ activity: Activity<MindropQuickVoiceActivityAttributes>) async {
        guard activity.attributes.sessionID.hasPrefix("remote-quick-") else { return }
        await scheduleEndIfCompleted(activity)

        guard !monitoredActivityIDs.contains(activity.id) else { return }
        monitoredActivityIDs.insert(activity.id)

        Task {
            for await _ in activity.contentUpdates {
                await MindropQuickVoiceRemoteService.shared.scheduleEndIfCompleted(activity)
            }
        }
    }

    private func scheduleEndIfCompleted(_ activity: Activity<MindropQuickVoiceActivityAttributes>) async {
        guard activity.content.state.phase == .completed else { return }
        guard !scheduledEndActivityIDs.contains(activity.id) else { return }
        scheduledEndActivityIDs.insert(activity.id)

        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await activity.end(activity.content, dismissalPolicy: .immediate)
            MindropQuickVoiceDiagnostics.append("remote quick voice live activity ended, id: \(activity.id)")
        }
    }

    @available(iOS 17.2, *)
    private func uploadPushToStartToken(_ tokenData: Data) async {
        let token = tokenData.hexString
        guard !token.isEmpty else { return }
        guard MindropSharedStorage.defaults.string(forKey: lastUploadedTokenKey) != token else { return }
        guard let endpoint = AIService.quickVoiceRegisterTokenEndpoint else {
            MindropQuickVoiceDiagnostics.append("remote quick voice token upload skipped: endpoint missing")
            return
        }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 14
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(
                QuickVoiceTokenRegistrationRequest(
                    deviceID: PushNotificationService.shared.deviceID,
                    deviceSecret: deviceSecret(),
                    pushToStartToken: token,
                    environment: PushNotificationService.shared.environment,
                    appBundleID: Bundle.main.bundleIdentifier ?? "app.mindrop.ios"
                )
            )

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw MindropQuickVoiceRemoteError.serverError(status, detail)
            }

            MindropSharedStorage.set(token, forKey: lastUploadedTokenKey)
            MindropSharedStorage.synchronize()
            MindropQuickVoiceDiagnostics.append("remote quick voice push-to-start token uploaded, prefix: \(String(token.prefix(12)))")
        } catch {
            MindropQuickVoiceDiagnostics.append("remote quick voice token upload failed: \(error)")
        }
    }

    private func deviceSecret() -> String {
        if let existing = MindropSharedStorage.defaults.string(forKey: deviceSecretKey),
           !existing.isEmpty {
            return existing
        }

        let value = "\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        MindropSharedStorage.set(value, forKey: deviceSecretKey)
        MindropSharedStorage.synchronize()
        return value
    }

    private func logLiveActivityDeliveryIfPresent(_ data: Data) {
        guard let metadata = try? JSONDecoder().decode(QuickVoiceCaptureMetadata.self, from: data),
              let liveActivity = metadata.liveActivity else {
            return
        }

        if liveActivity.ok {
            MindropQuickVoiceDiagnostics.append("remote quick voice live activity delivered, apnsID: \(liveActivity.apnsID ?? "nil")")
        } else {
            MindropQuickVoiceDiagnostics.append(
                "remote quick voice live activity failed, status: \(liveActivity.status ?? -1), reason: \(liveActivity.reason ?? "nil")"
            )
        }
    }

    private static func currentSnapshot() -> AppSnapshot {
        PersistenceStore.load() ?? AppSnapshot(
            session: .offline,
            notes: [],
            messages: [],
            profile: .loggedOut
        )
    }

    private static func reminderCandidates(in notes: [ThoughtNote]) -> [ThoughtNote] {
        let now = Date()
        return notes
            .filter { $0.category == .todo && $0.reminderAt != nil }
            .sorted { lhs, rhs in
                let lhsReminderAt = lhs.reminderAt ?? .distantPast
                let rhsReminderAt = rhs.reminderAt ?? .distantPast
                let lhsIsFuture = lhsReminderAt >= now
                let rhsIsFuture = rhsReminderAt >= now
                if lhsIsFuture != rhsIsFuture { return lhsIsFuture && !rhsIsFuture }
                if lhsIsFuture { return lhsReminderAt < rhsReminderAt }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private static func qaCandidates(in notes: [ThoughtNote], context: [ChatMessage]) -> [ThoughtNote] {
        guard let previousMessage = context.last,
              previousMessage.role == .assistant,
              previousMessage.category == .qa,
              let noteID = previousMessage.noteID,
              let previousQANote = notes.first(where: { $0.id == noteID && $0.category == .qa }) else {
            return []
        }
        return [previousQANote]
    }

    fileprivate static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct QuickVoiceTokenRegistrationRequest: Encodable {
    let deviceID: String
    let deviceSecret: String
    let pushToStartToken: String
    let environment: String
    let appBundleID: String
}

private struct QuickVoiceCaptureRequest: Encodable {
    let deviceID: String
    let deviceSecret: String
    let environment: String
    let appBundleID: String
    let text: String
    let context: [QuickVoiceContextMessage]
    let reminders: [QuickVoiceReminderCandidate]
    let qaNotes: [QuickVoiceNoteCandidate]
    let now: String
    let timeZone: String
    let thinkingEnabled: Bool
}

private struct QuickVoiceContextMessage: Encodable {
    let role: String
    let text: String
    let category: String?

    init(message: ChatMessage) {
        role = message.role.rawValue
        text = message.text
        category = message.category?.rawValue
    }
}

private struct QuickVoiceReminderCandidate: Encodable {
    let id: String
    let title: String
    let content: String
    let reminderAt: String
    let createdAt: String

    init(note: ThoughtNote) {
        id = note.id.uuidString
        title = note.title
        content = note.content
        reminderAt = note.reminderAt.map { MindropQuickVoiceRemoteService.isoFormatter.string(from: $0) } ?? ""
        createdAt = MindropQuickVoiceRemoteService.isoFormatter.string(from: note.createdAt)
    }
}

private struct QuickVoiceNoteCandidate: Encodable {
    let id: String
    let title: String
    let content: String
    let createdAt: String

    init(note: ThoughtNote) {
        id = note.id.uuidString
        title = note.title
        content = note.content
        createdAt = MindropQuickVoiceRemoteService.isoFormatter.string(from: note.createdAt)
    }
}

private struct QuickVoiceCaptureMetadata: Decodable {
    let liveActivity: QuickVoiceLiveActivityDelivery?

    private enum CodingKeys: String, CodingKey {
        case liveActivity = "_quickVoiceLiveActivity"
    }
}

private struct QuickVoiceLiveActivityDelivery: Decodable {
    let ok: Bool
    let status: Int?
    let reason: String?
    let apnsID: String?
}

enum MindropQuickVoiceRemoteError: Error {
    case emptyText
    case endpointNotConfigured
    case invalidResponse
    case serverError(Int, String)
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
