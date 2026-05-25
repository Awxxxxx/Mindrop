import Foundation
import UserNotifications

enum NotificationAuthorizationState: Equatable {
    case unknown
    case granted
    case denied
}

@MainActor
final class NotificationScheduler: ObservableObject {
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown

    func refreshAuthorizationState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationState = state(from: settings.authorizationStatus)
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            authorizationState = granted ? .granted : .denied
            return granted
        } catch {
            authorizationState = .denied
            return false
        }
    }

    func scheduleReminder(for note: ThoughtNote) async {
        guard let reminderAt = note.reminderAt, reminderAt > .now else {
            cancelReminder(for: note.id)
            return
        }
        let allowed: Bool
        if authorizationState == .granted {
            allowed = true
        } else {
            allowed = await requestAuthorization()
        }
        guard allowed else { return }

        let content = UNMutableNotificationContent()
        content.title = note.reminderNotificationTitle.trimmedNonEmpty ?? "待办时间到啦"
        content.body = note.reminderNotificationBody.trimmedNonEmpty ?? note.content
        content.sound = .default

        let interval = reminderAt.timeIntervalSinceNow
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: note.id.uuidString, content: content, trigger: trigger)
        cancelReminder(for: note.id)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancelReminder(for noteID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [noteID.uuidString])
    }

    private func state(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? {
        guard let value = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
