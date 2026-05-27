import Foundation

struct AppSnapshot: Codable {
    var session: SessionState
    var notes: [ThoughtNote]
    var deletedNotes: [ThoughtNote]
    var messages: [ChatMessage]
    var deletedMessages: [ChatMessage]
    var profileStats: ProfileStats
    var hasTrimmedChatHistory: Bool
    var hasPendingCloudChanges: Bool
    var profile: UserProfile
    var followsSystemAppearance: Bool

    init(
        session: SessionState,
        notes: [ThoughtNote],
        deletedNotes: [ThoughtNote] = [],
        messages: [ChatMessage],
        deletedMessages: [ChatMessage] = [],
        profileStats: ProfileStats = .empty,
        hasTrimmedChatHistory: Bool = false,
        hasPendingCloudChanges: Bool = false,
        profile: UserProfile,
        followsSystemAppearance: Bool = true
    ) {
        self.session = session
        self.notes = notes
        self.deletedNotes = deletedNotes
        self.messages = messages
        self.deletedMessages = deletedMessages
        self.profileStats = profileStats
        self.hasTrimmedChatHistory = hasTrimmedChatHistory
        self.hasPendingCloudChanges = hasPendingCloudChanges
        self.profile = profile
        self.followsSystemAppearance = followsSystemAppearance
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case notes
        case deletedNotes
        case messages
        case deletedMessages
        case profileStats
        case hasTrimmedChatHistory
        case hasPendingCloudChanges
        case profile
        case followsSystemAppearance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(SessionState.self, forKey: .session)
        notes = try container.decode([ThoughtNote].self, forKey: .notes)
        deletedNotes = try container.decodeIfPresent([ThoughtNote].self, forKey: .deletedNotes) ?? []
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        deletedMessages = try container.decodeIfPresent([ChatMessage].self, forKey: .deletedMessages) ?? []
        profileStats = try container.decodeIfPresent(ProfileStats.self, forKey: .profileStats) ?? .empty
        hasTrimmedChatHistory = try container.decodeIfPresent(Bool.self, forKey: .hasTrimmedChatHistory) ?? false
        hasPendingCloudChanges = try container.decodeIfPresent(Bool.self, forKey: .hasPendingCloudChanges) ?? false
        profile = try container.decode(UserProfile.self, forKey: .profile)
        followsSystemAppearance = try container.decodeIfPresent(Bool.self, forKey: .followsSystemAppearance) ?? true
    }
}

enum PersistenceStore {
    private static let snapshotKey = "mindrop.snapshot.v1"
    private static let installationMarkerKey = "mindrop.installationMarker.v1"

    static func load() -> AppSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(AppSnapshot.self, from: data)
    }

    static func save(_ snapshot: AppSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey)
    }

    static func saveAndFlush(_ snapshot: AppSnapshot) {
        save(snapshot)
        UserDefaults.standard.synchronize()
    }

    static func shouldResetKeychainForFreshInstall(hasExistingSnapshot: Bool) -> Bool {
        let defaults = UserDefaults.standard
        let hasInstallationMarker = defaults.bool(forKey: installationMarkerKey)
        if !hasInstallationMarker {
            defaults.set(true, forKey: installationMarkerKey)
        }
        return !hasInstallationMarker && !hasExistingSnapshot
    }
}
