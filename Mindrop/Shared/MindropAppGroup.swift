import Foundation

enum MindropSharedStorage {
    static let appGroupIdentifier = "group.app.mindrop.ios"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static var defaults: UserDefaults {
        sharedDefaults ?? .standard
    }

    static func data(forKey key: String) -> Data? {
        migrateFromStandardIfNeeded(forKey: key)
        return defaults.data(forKey: key)
    }

    static func bool(forKey key: String) -> Bool {
        migrateFromStandardIfNeeded(forKey: key)
        return defaults.bool(forKey: key)
    }

    static func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        if sharedDefaults != nil {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    static func synchronize() {
        defaults.synchronize()
        if sharedDefaults != nil {
            UserDefaults.standard.synchronize()
        }
    }

    private static func migrateFromStandardIfNeeded(forKey key: String) {
        guard let sharedDefaults else { return }
        guard sharedDefaults.object(forKey: key) == nil else { return }
        guard let standardValue = UserDefaults.standard.object(forKey: key) else { return }
        sharedDefaults.set(standardValue, forKey: key)
    }
}

extension Notification.Name {
    static let mindropQuickCaptureDidSave = Notification.Name("mindrop.quickCaptureDidSave")
}
