import Foundation
import Security

struct SupabaseSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let user: SupabaseUser

    var needsRefresh: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }
}

struct SupabaseUser: Codable, Equatable {
    let id: String
    let email: String?
}

struct SupabaseProfile: Codable, Equatable {
    let userID: String
    let nickname: String
    let mindropID: String
    let avatarName: String
    let avatarURL: String?
    let legacyAvatarDataBase64: String?

    var userProfile: UserProfile {
        UserProfile(
            nickname: nickname,
            userID: mindropID,
            avatarName: avatarName,
            avatarURL: avatarURL,
            avatarDataBase64: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case nickname
        case mindropID = "mindrop_id"
        case avatarName = "avatar_name"
        case avatarURL = "avatar_url"
        case legacyAvatarDataBase64 = "avatar_data"
    }
}

struct FeishuBotCredentials: Equatable {
    let appID: String
    let appSecret: String
    let verificationToken: String
    let encryptKey: String
}

struct FeishuConnectionSetup: Equatable {
    let callbackURL: String
    let pairingCode: String
    let pairingExpiresAt: Date
}

struct SupabaseAppData {
    let notes: [ThoughtNote]
    let deletedNotes: [ThoughtNote]
    let messages: [ChatMessage]
    let deletedMessages: [ChatMessage]
    let hasTrimmedChatHistory: Bool
    let followsSystemAppearance: Bool
    let hasSettings: Bool

    var hasRemoteRows: Bool {
        hasSettings || hasContentRows
    }

    var hasContentRows: Bool {
        !notes.isEmpty || !deletedNotes.isEmpty || !messages.isEmpty || !deletedMessages.isEmpty
    }
}

enum SupabaseServiceError: LocalizedError {
    case invalidConfiguration
    case missingSession
    case emailConfirmationRequired
    case serverMessage(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Supabase 配置不完整"
        case .missingSession:
            return "登录状态已过期，请重新登录"
        case .emailConfirmationRequired:
            return "注册成功，请先查收邮件完成确认后再登录"
        case .serverMessage(let message):
            return message
        case .unexpectedResponse:
            return "服务返回异常，请稍后再试"
        }
    }
}

final class SupabaseService {
    static let shared = SupabaseService()

    private let projectURL = URL(string: "https://ayzmmchrepbtfnjegqxp.supabase.co")
    private let mindropAPIBaseURL = URL(string: "https://www.mindrop.chat")
    private let publishableKey = "sb_publishable_9J-FGmHuu68MO4UVUWSbtA_XLpeROVX"
    private let urlSession: URLSession
    private let keychain = KeychainStore(service: "app.mindrop.ios.supabase")
    private let sessionAccount = "current-session"

    private init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    fileprivate static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    fileprivate static let isoFormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    fileprivate static func date(from value: String) -> Date? {
        isoFormatter.date(from: value) ?? isoFormatterWithoutFractionalSeconds.date(from: value)
    }

    func storedSession() throws -> SupabaseSession? {
        try keychain.read(SupabaseSession.self, account: sessionAccount)
    }

    func saveSession(_ session: SupabaseSession) throws {
        try keychain.save(session, account: sessionAccount)
    }

    func clearSession() throws {
        try keychain.delete(account: sessionAccount)
    }

    func signIn(email: String, password: String) async throws -> SupabaseSession {
        let response: AuthResponse = try await authRequest(
            path: "/auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            body: ["email": email, "password": password]
        )
        let session = try response.session()
        try saveSession(session)
        return session
    }

    func signUp(email: String, password: String) async throws -> SupabaseSession? {
        let response: AuthResponse = try await authRequest(
            path: "/auth/v1/signup",
            body: ["email": email, "password": password]
        )

        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            return nil
        }

        let session = try response.session()
        try saveSession(session)
        return session
    }

    func refresh(_ session: SupabaseSession) async throws -> SupabaseSession {
        let response: AuthResponse = try await authRequest(
            path: "/auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: ["refresh_token": session.refreshToken]
        )
        let refreshedSession = try response.session()
        try saveSession(refreshedSession)
        return refreshedSession
    }

    func signOut(_ session: SupabaseSession?) async {
        if let session {
            var request = try? makeRequest(path: "/auth/v1/logout", method: "POST", accessToken: session.accessToken)
            request?.httpBody = Data()
            if let request {
                _ = try? await urlSession.data(for: request)
            }
        }
        try? clearSession()
    }

    func fetchSnapshot(using session: SupabaseSession) async throws -> AppSnapshot? {
        let activeSession = try await activeSession(from: session)
        var components = try urlComponents(path: "/rest/v1/app_snapshots")
        components.queryItems = [
            URLQueryItem(name: "select", value: "snapshot"),
            URLQueryItem(name: "user_id", value: "eq.\(activeSession.user.id)"),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }
        var request = try makeRequest(url: url, method: "GET", accessToken: activeSession.accessToken)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await perform(request)
        return try JSONDecoder().decode([SnapshotRecord].self, from: data).first?.snapshot
    }

    func upsertSnapshot(_ snapshot: AppSnapshot, using session: SupabaseSession) async throws {
        let activeSession = try await activeSession(from: session)
        let snapshotData = try JSONEncoder().encode(snapshot)
        let snapshotObject = try JSONSerialization.jsonObject(with: snapshotData)
        let body: [String: Any] = [
            "user_id": activeSession.user.id,
            "snapshot": snapshotObject
        ]

        var components = try urlComponents(path: "/rest/v1/app_snapshots")
        components.queryItems = [
            URLQueryItem(name: "on_conflict", value: "user_id")
        ]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }

        var request = try makeRequest(url: url, method: "POST", accessToken: activeSession.accessToken)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    func fetchProfile(using session: SupabaseSession) async throws -> SupabaseProfile? {
        let activeSession = try await activeSession(from: session)
        var components = try urlComponents(path: "/rest/v1/profiles")
        components.queryItems = [
            URLQueryItem(name: "select", value: "user_id,nickname,mindrop_id,avatar_name,avatar_url,avatar_data"),
            URLQueryItem(name: "user_id", value: "eq.\(activeSession.user.id)"),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }
        var request = try makeRequest(url: url, method: "GET", accessToken: activeSession.accessToken)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await perform(request)
        return try JSONDecoder().decode([SupabaseProfile].self, from: data).first
    }

    func upsertProfile(_ profile: UserProfile, using session: SupabaseSession) async throws -> SupabaseProfile {
        let activeSession = try await activeSession(from: session)
        let body: [String: Any] = [
            "user_id": activeSession.user.id,
            "nickname": profile.nickname,
            "mindrop_id": profile.userID,
            "avatar_name": profile.avatarName,
            "avatar_url": profile.avatarURL ?? NSNull()
        ]

        var components = try urlComponents(path: "/rest/v1/profiles")
        components.queryItems = [
            URLQueryItem(name: "on_conflict", value: "user_id")
        ]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }

        var request = try makeRequest(url: url, method: "POST", accessToken: activeSession.accessToken)
        request.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        guard let profile = try JSONDecoder().decode([SupabaseProfile].self, from: data).first else {
            throw SupabaseServiceError.unexpectedResponse
        }
        return profile
    }

    func uploadAvatar(_ data: Data, using session: SupabaseSession) async throws -> String {
        let activeSession = try await activeSession(from: session)
        let objectPath = "\(activeSession.user.id)/avatar.jpg"
        var request = try makeRequest(
            path: "/storage/v1/object/avatars/\(objectPath)",
            method: "POST",
            accessToken: activeSession.accessToken
        )
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.httpBody = data
        _ = try await perform(request)

        guard let projectURL else { throw SupabaseServiceError.invalidConfiguration }
        return projectURL
            .appendingPathComponent("/storage/v1/object/public/avatars/\(objectPath)")
            .absoluteString + "?v=\(Int(Date().timeIntervalSince1970))"
    }

    func upsertPushToken(
        deviceID: String,
        token: String,
        environment: String,
        using session: SupabaseSession
    ) async throws {
        let activeSession = try await activeSession(from: session)
        let now = Self.isoFormatter.string(from: .now)
        let body: [String: Any] = [
            "user_id": activeSession.user.id,
            "device_id": deviceID,
            "token": token,
            "platform": "ios",
            "environment": environment,
            "app_bundle_id": "app.mindrop.ios",
            "updated_at": now,
            "revoked_at": NSNull()
        ]

        var components = try urlComponents(path: "/rest/v1/push_tokens")
        components.queryItems = [URLQueryItem(name: "on_conflict", value: "user_id,device_id,environment")]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }

        var request = try makeRequest(url: url, method: "POST", accessToken: activeSession.accessToken)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    func revokePushToken(deviceID: String, environment: String, using session: SupabaseSession) async throws {
        let activeSession = try await activeSession(from: session)
        var components = try urlComponents(path: "/rest/v1/push_tokens")
        components.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(activeSession.user.id)"),
            URLQueryItem(name: "device_id", value: "eq.\(deviceID)"),
            URLQueryItem(name: "environment", value: "eq.\(environment)")
        ]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }

        let now = Self.isoFormatter.string(from: .now)
        let body: [String: Any] = [
            "updated_at": now,
            "revoked_at": now
        ]
        var request = try makeRequest(url: url, method: "PATCH", accessToken: activeSession.accessToken)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    func createFeishuConnection(credentials: FeishuBotCredentials, using session: SupabaseSession) async throws -> FeishuConnectionSetup {
        let activeSession = try await activeSession(from: session)
        guard let baseURL = mindropAPIBaseURL,
              let url = URL(string: "/api/feishu/connections", relativeTo: baseURL)?.absoluteURL else {
            throw SupabaseServiceError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(activeSession.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            FeishuConnectionCreateRequest(
                appID: credentials.appID,
                appSecret: credentials.appSecret,
                verificationToken: credentials.verificationToken,
                encryptKey: credentials.encryptKey,
                timeZone: TimeZone.current.identifier
            )
        )

        let data = try await perform(request)
        let payload = try JSONDecoder().decode(FeishuConnectionCreateResponse.self, from: data)
        guard let expiresAt = Self.date(from: payload.pairingExpiresAt) else {
            throw SupabaseServiceError.unexpectedResponse
        }
        return FeishuConnectionSetup(
            callbackURL: payload.callbackURL,
            pairingCode: payload.pairingCode,
            pairingExpiresAt: expiresAt
        )
    }

    func fetchAppData(using session: SupabaseSession) async throws -> SupabaseAppData {
        let activeSession = try await activeSession(from: session)
        let allNotes = try await fetchNotes(using: activeSession)
        let allMessages = try await fetchMessages(using: activeSession)
        let settings = try await fetchSettings(using: activeSession)
        return SupabaseAppData(
            notes: allNotes.filter { $0.deletedAt == nil },
            deletedNotes: allNotes.filter { $0.deletedAt != nil },
            messages: allMessages.filter { $0.deletedAt == nil },
            deletedMessages: allMessages.filter { $0.deletedAt != nil },
            hasTrimmedChatHistory: settings?.hasTrimmedChatHistory ?? false,
            followsSystemAppearance: settings?.followsSystemAppearance ?? true,
            hasSettings: settings != nil
        )
    }

    func syncAppData(
        notes: [ThoughtNote],
        deletedNotes: [ThoughtNote],
        messages: [ChatMessage],
        deletedMessages: [ChatMessage],
        hasTrimmedChatHistory: Bool,
        followsSystemAppearance: Bool,
        using session: SupabaseSession
    ) async throws {
        let activeSession = try await activeSession(from: session)
        try await upsertSettings(
            hasTrimmedChatHistory: hasTrimmedChatHistory,
            followsSystemAppearance: followsSystemAppearance,
            using: activeSession
        )
        try await upsertNotes(notes + deletedNotes, using: activeSession)
        try await upsertMessages(messages + deletedMessages, using: activeSession)
    }

    private func fetchNotes(using session: SupabaseSession) async throws -> [ThoughtNote] {
        var components = try urlComponents(path: "/rest/v1/thought_notes")
        components.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_id", value: "eq.\(session.user.id)"),
            URLQueryItem(name: "order", value: "created_at.desc")
        ]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }
        let data = try await perform(try makeRequest(url: url, method: "GET", accessToken: session.accessToken))
        return try JSONDecoder().decode([RemoteThoughtNote].self, from: data).map(\.note)
    }

    private func fetchMessages(using session: SupabaseSession) async throws -> [ChatMessage] {
        var components = try urlComponents(path: "/rest/v1/chat_messages")
        components.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_id", value: "eq.\(session.user.id)"),
            URLQueryItem(name: "order", value: "created_at.asc")
        ]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }
        let data = try await perform(try makeRequest(url: url, method: "GET", accessToken: session.accessToken))
        return try JSONDecoder().decode([RemoteChatMessage].self, from: data).map(\.message)
    }

    private func fetchSettings(using session: SupabaseSession) async throws -> RemoteUserSettings? {
        var components = try urlComponents(path: "/rest/v1/user_settings")
        components.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_id", value: "eq.\(session.user.id)"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }
        let data = try await perform(try makeRequest(url: url, method: "GET", accessToken: session.accessToken))
        return try JSONDecoder().decode([RemoteUserSettings].self, from: data).first
    }

    private func upsertSettings(
        hasTrimmedChatHistory: Bool,
        followsSystemAppearance: Bool,
        using session: SupabaseSession
    ) async throws {
        let body: [String: Any] = [
            "user_id": session.user.id,
            "has_trimmed_chat_history": hasTrimmedChatHistory,
            "follows_system_appearance": followsSystemAppearance
        ]
        var components = try urlComponents(path: "/rest/v1/user_settings")
        components.queryItems = [URLQueryItem(name: "on_conflict", value: "user_id")]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }
        var request = try makeRequest(url: url, method: "POST", accessToken: session.accessToken)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    private func upsertNotes(_ notes: [ThoughtNote], using session: SupabaseSession) async throws {
        guard !notes.isEmpty else { return }
        let body = notes.map { RemoteThoughtNote(note: $0, userID: session.user.id).body }
        var request = try upsertRequest(path: "/rest/v1/thought_notes", accessToken: session.accessToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    private func upsertMessages(_ messages: [ChatMessage], using session: SupabaseSession) async throws {
        guard !messages.isEmpty else { return }
        let body = messages.map { RemoteChatMessage(message: $0, userID: session.user.id).body }
        var request = try upsertRequest(path: "/rest/v1/chat_messages", accessToken: session.accessToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    private func upsertRequest(path: String, accessToken: String) throws -> URLRequest {
        var components = try urlComponents(path: path)
        components.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }
        var request = try makeRequest(url: url, method: "POST", accessToken: accessToken)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        return request
    }

    private func activeSession(from session: SupabaseSession) async throws -> SupabaseSession {
        let latestSession = (try? storedSession()) ?? session
        guard latestSession.needsRefresh else { return latestSession }
        return try await refresh(latestSession)
    }

    private func authRequest<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        body: [String: String]
    ) async throws -> T {
        var components = try urlComponents(path: path)
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }

        var request = try makeRequest(url: url, method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await perform(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeRequest(path: String, method: String, accessToken: String? = nil) throws -> URLRequest {
        let components = try urlComponents(path: path)
        guard let url = components.url else { throw SupabaseServiceError.invalidConfiguration }
        return try makeRequest(url: url, method: method, accessToken: accessToken)
    }

    private func makeRequest(url: URL, method: String, accessToken: String? = nil) throws -> URLRequest {
        guard !publishableKey.isEmpty else { throw SupabaseServiceError.invalidConfiguration }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func urlComponents(path: String) throws -> URLComponents {
        guard let projectURL else { throw SupabaseServiceError.invalidConfiguration }
        guard var components = URLComponents(url: projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw SupabaseServiceError.invalidConfiguration
        }
        components.path = path
        return components
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.unexpectedResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = try? JSONDecoder().decode(SupabaseErrorResponse.self, from: data) {
                throw SupabaseServiceError.serverMessage(error.displayMessage)
            }
            if let rawMessage = String(data: data, encoding: .utf8), !rawMessage.isEmpty {
                throw SupabaseServiceError.serverMessage(rawMessage)
            }
            throw SupabaseServiceError.unexpectedResponse
        }

        return data
    }
}

private struct AuthResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let user: SupabaseUser?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }

    func session() throws -> SupabaseSession {
        guard let accessToken, let refreshToken, let user else {
            throw SupabaseServiceError.emailConfirmationRequired
        }

        return SupabaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn ?? 3600),
            user: user
        )
    }
}

private struct FeishuConnectionCreateRequest: Encodable {
    let appID: String
    let appSecret: String
    let verificationToken: String
    let encryptKey: String
    let timeZone: String
}

private struct FeishuConnectionCreateResponse: Decodable {
    let callbackURL: String
    let pairingCode: String
    let pairingExpiresAt: String
}

private struct SnapshotRecord: Decodable {
    let snapshot: AppSnapshot
}

private struct RemoteUserSettings: Decodable {
    let hasTrimmedChatHistory: Bool
    let followsSystemAppearance: Bool

    private enum CodingKeys: String, CodingKey {
        case hasTrimmedChatHistory = "has_trimmed_chat_history"
        case followsSystemAppearance = "follows_system_appearance"
    }
}

private struct RemoteThoughtNote: Decodable {
    let id: String
    let title: String
    let content: String
    let category: String
    let createdAt: String
    let updatedAt: String?
    let deletedAt: String?
    let reminderAt: String?
    let reminderNotificationTitle: String?
    let reminderNotificationBody: String?
    let expenseAmount: Double?
    let expenseCategory: String?
    let isPinned: Bool
    let recycledAt: String?
    let categoryBeforeRecycle: String?
    private var userID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case category
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case reminderAt = "reminder_at"
        case reminderNotificationTitle = "reminder_notification_title"
        case reminderNotificationBody = "reminder_notification_body"
        case expenseAmount = "expense_amount"
        case expenseCategory = "expense_category"
        case isPinned = "is_pinned"
        case recycledAt = "recycled_at"
        case categoryBeforeRecycle = "category_before_recycle"
    }

    init(note: ThoughtNote, userID: String) {
        self.userID = userID
        id = note.id.uuidString
        title = note.title
        content = note.content
        category = note.category.rawValue
        createdAt = Self.dateString(note.createdAt)
        updatedAt = Self.dateString(note.updatedAt)
        deletedAt = note.deletedAt.map(Self.dateString)
        reminderAt = note.reminderAt.map(Self.dateString)
        reminderNotificationTitle = note.reminderNotificationTitle
        reminderNotificationBody = note.reminderNotificationBody
        expenseAmount = note.expenseAmount.map { NSDecimalNumber(decimal: $0).doubleValue }
        expenseCategory = note.expenseCategory?.rawValue
        isPinned = note.isPinned
        recycledAt = note.recycledAt.map(Self.dateString)
        categoryBeforeRecycle = note.categoryBeforeRecycle?.rawValue
    }

    var body: [String: Any] {
        [
            "id": id,
            "user_id": userID ?? NSNull(),
            "title": title,
            "content": content,
            "category": category,
            "created_at": createdAt,
            "updated_at": updatedAt ?? NSNull(),
            "deleted_at": deletedAt ?? NSNull(),
            "reminder_at": reminderAt ?? NSNull(),
            "reminder_notification_title": reminderNotificationTitle ?? NSNull(),
            "reminder_notification_body": reminderNotificationBody ?? NSNull(),
            "expense_amount": expenseAmount ?? NSNull(),
            "expense_category": expenseCategory ?? NSNull(),
            "is_pinned": isPinned,
            "recycled_at": recycledAt ?? NSNull(),
            "category_before_recycle": categoryBeforeRecycle ?? NSNull()
        ]
    }

    var note: ThoughtNote {
        ThoughtNote(
            id: UUID(uuidString: id) ?? UUID(),
            title: title,
            content: content,
            category: ThoughtCategory(rawValue: category) ?? .idea,
            createdAt: Self.date(from: createdAt) ?? .now,
            updatedAt: updatedAt.flatMap(Self.date) ?? Self.date(from: createdAt) ?? .now,
            deletedAt: deletedAt.flatMap(Self.date),
            reminderAt: reminderAt.flatMap(Self.date),
            reminderNotificationTitle: reminderNotificationTitle,
            reminderNotificationBody: reminderNotificationBody,
            expenseAmount: expenseAmount.map { Decimal($0) },
            expenseCategory: expenseCategory.flatMap(ExpenseCategory.init(rawValue:)),
            isPinned: isPinned,
            recycledAt: recycledAt.flatMap(Self.date),
            categoryBeforeRecycle: categoryBeforeRecycle.flatMap(ThoughtCategory.init(rawValue:))
        )
    }

    private static func dateString(_ date: Date) -> String {
        SupabaseService.isoFormatter.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        SupabaseService.isoFormatter.date(from: value) ??
            SupabaseService.isoFormatterWithoutFractionalSeconds.date(from: value)
    }
}

private struct RemoteChatMessage: Decodable {
    let id: String
    let role: String
    let text: String
    let category: String?
    let noteID: String?
    let createdAt: String
    let updatedAt: String?
    let deletedAt: String?
    private var userID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case category
        case noteID = "note_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    init(message: ChatMessage, userID: String) {
        self.userID = userID
        id = message.id.uuidString
        role = message.role.rawValue
        text = message.text
        category = message.category?.rawValue
        noteID = message.noteID?.uuidString
        createdAt = SupabaseService.isoFormatter.string(from: message.createdAt)
        updatedAt = SupabaseService.isoFormatter.string(from: message.updatedAt)
        deletedAt = message.deletedAt.map { SupabaseService.isoFormatter.string(from: $0) }
    }

    var body: [String: Any] {
        [
            "id": id,
            "user_id": userID ?? NSNull(),
            "role": role,
            "text": text,
            "category": category ?? NSNull(),
            "note_id": noteID ?? NSNull(),
            "created_at": createdAt,
            "updated_at": updatedAt ?? NSNull(),
            "deleted_at": deletedAt ?? NSNull()
        ]
    }

    var message: ChatMessage {
        ChatMessage(
            id: UUID(uuidString: id) ?? UUID(),
            role: ChatMessage.Role(rawValue: role) ?? .assistant,
            text: text,
            category: category.flatMap(ThoughtCategory.init(rawValue:)),
            noteID: noteID.flatMap(UUID.init(uuidString:)),
            createdAt: Self.date(from: createdAt) ?? .now,
            updatedAt: updatedAt.flatMap(Self.date) ?? Self.date(from: createdAt) ?? .now,
            deletedAt: deletedAt.flatMap(Self.date)
        )
    }

    private static func date(from value: String) -> Date? {
        SupabaseService.isoFormatter.date(from: value) ??
            SupabaseService.isoFormatterWithoutFractionalSeconds.date(from: value)
    }
}

private struct SupabaseErrorResponse: Decodable {
    let message: String?
    let msg: String?
    let errorDescription: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case msg
        case errorDescription = "error_description"
        case error
    }

    var displayMessage: String {
        errorDescription ?? message ?? msg ?? error ?? "请求失败，请稍后再试"
    }
}

private final class KeychainStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        try delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SupabaseServiceError.unexpectedResponse }
    }

    func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SupabaseServiceError.unexpectedResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SupabaseServiceError.unexpectedResponse
        }
    }
}
