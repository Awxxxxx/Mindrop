import Foundation
import UIKit
import UserNotifications

func mindropPushDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

final class MindropAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        mindropPushDebugLog("Mindrop push: did register APNs token prefix=\(String(token.prefix(12))) environment=\(PushNotificationService.shared.environment)")
        PushNotificationService.shared.saveDeviceToken(token)
        NotificationCenter.default.post(name: .mindropDidUpdateRemotePushToken, object: nil)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        let nsError = error as NSError
        mindropPushDebugLog("Mindrop push: APNs registration failed domain=\(nsError.domain) code=\(nsError.code) message=\(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let hasMindropPayload = notification.request.content.userInfo["mindrop"] != nil
        mindropPushDebugLog("Mindrop push: will present notification id=\(notification.request.identifier) mindropPayload=\(hasMindropPayload)")
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let hasMindropPayload = response.notification.request.content.userInfo["mindrop"] != nil
        mindropPushDebugLog("Mindrop push: did receive notification response id=\(response.notification.request.identifier) mindropPayload=\(hasMindropPayload)")
        completionHandler()
    }
}

final class PushNotificationService {
    static let shared = PushNotificationService()

    private let deviceIDKey = "mindrop.push.deviceID.v1"
    private let deviceTokenKey = "mindrop.push.deviceToken.v1"
    private let defaults = UserDefaults.standard

    private init() {}

    var deviceID: String {
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: deviceIDKey)
        return value
    }

    var deviceToken: String? {
        defaults.string(forKey: deviceTokenKey)
    }

    var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    @MainActor
    func requestAuthorizationAndRegister() async -> Bool {
        let allowed: Bool
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        mindropPushDebugLog("Mindrop push: notification authorization status=\(settings.authorizationStatus.rawValue)")
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            allowed = true
        case .notDetermined:
            allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        case .denied:
            allowed = false
        @unknown default:
            allowed = false
        }

        guard allowed else {
            mindropPushDebugLog("Mindrop push: notification authorization is not allowed")
            return false
        }
        mindropPushDebugLog("Mindrop push: requesting APNs token environment=\(environment)")
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    func saveDeviceToken(_ token: String) {
        defaults.set(token, forKey: deviceTokenKey)
    }
}

extension Notification.Name {
    static let mindropDidUpdateRemotePushToken = Notification.Name("mindropDidUpdateRemotePushToken")
}
