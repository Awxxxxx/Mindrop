import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppStore: ObservableObject {
    @Published var session: SessionState = .welcome { didSet { persistIfReady(markCloudDirty: false) } }
    @Published var selectedTab: AppTab = .history
    @Published var selectedCategory: ThoughtCategory = .todo
    @Published var selectedRange: TimeRange = .seven
    @Published var notes: [ThoughtNote] = [] { didSet { persistIfReady(markCloudDirty: true) } }
    @Published var messages: [ChatMessage] = [] { didSet { persistIfReady(markCloudDirty: true) } }
    @Published var profileStats: ProfileStats = .empty { didSet { persistIfReady(markCloudDirty: true) } }
    @Published var hasTrimmedChatHistory = false { didSet { persistIfReady(markCloudDirty: true) } }
    @Published var profile = UserProfile.loggedOut { didSet { persistIfReady(markCloudDirty: false) } }
    @Published var followsSystemAppearance = true { didSet { persistIfReady(markCloudDirty: true) } }
    @Published var isAIThinking = false
    @Published var isAuthenticating = false
    @Published var isSavingProfile = false
    @Published var isDeletingAccount = false
    @Published var streamingAssistantMessageID: UUID?
    @Published var toast: String?
    let notificationScheduler = NotificationScheduler()

    private let chatHistoryLimit = 100
    private let qaNoteLimit = 100
    private let expiredReminderRecycleInterval: TimeInterval = 24 * 60 * 60
    private let aiService = AIService()
    private let supabaseService = SupabaseService.shared
    private var isRestoring = true
    private var isApplyingRemoteSnapshot = false
    private var isPreparingCloudSession = false
    private var currentSupabaseSession: SupabaseSession?
    private var cloudSyncTask: Task<Void, Never>?
    private var hasPendingCloudChanges = false
    private var cloudSyncRevision = 0
    private var pendingAIRequestCount = 0
    private var deletedNotes: [ThoughtNote] = []
    private var deletedMessages: [ChatMessage] = []
    private var pushTokenObserver: NSObjectProtocol?
    private var feishuPairingDraft: FeishuConfigurationDraft?

    init() {
        let snapshot = PersistenceStore.load()
        if PersistenceStore.shouldResetKeychainForFreshInstall(hasExistingSnapshot: snapshot != nil) {
            try? supabaseService.clearSession()
        }

        if let snapshot {
            session = snapshot.session
            notes = snapshot.notes.filter { $0.deletedAt == nil }
            deletedNotes = snapshot.deletedNotes + snapshot.notes.filter { $0.deletedAt != nil }
            messages = snapshot.messages.filter { $0.deletedAt == nil }
            deletedMessages = snapshot.deletedMessages + snapshot.messages.filter { $0.deletedAt != nil }
            profileStats = snapshot.profileStats
            hasTrimmedChatHistory = snapshot.hasTrimmedChatHistory
            hasPendingCloudChanges = snapshot.hasPendingCloudChanges
            profile = snapshot.profile
            followsSystemAppearance = snapshot.followsSystemAppearance
            enforceChatHistoryLimit()
        } else {
            seed()
        }
        removeBuiltInSampleDataFromCurrentState()
        migrateDefaultMeetingSampleReminder()
        if backfillProfileStatsFromCurrentData() {
            hasPendingCloudChanges = true
        }
        if enforceQANoteLimit() {
            hasPendingCloudChanges = true
        }
        selectedTab = .history
        selectedCategory = .todo
        isRestoring = false
        recycleExpiredReminders()
        observeRemotePushTokenUpdates()
        persistIfReady(markCloudDirty: false)

        Task {
            await restoreSupabaseSession()
            await notificationScheduler.refreshAuthorizationState()
            await rescheduleFutureReminders()
        }
    }

    var isLoggedIn: Bool {
        session == .authenticated
    }

    var shouldShowHistorySampleNotes: Bool {
        !hasUserCreatedRealNotes
    }

    var historyNotesForDisplay: [ThoughtNote] {
        shouldShowHistorySampleNotes ? Self.builtInSampleNotes : notes
    }

    var shouldShowChatSampleMessages: Bool {
        !hasUserCreatedRealMessages
    }

    var chatMessagesForDisplay: [ChatMessage] {
        shouldShowChatSampleMessages ? Self.builtInSampleMessages : messages
    }

    func isHistorySampleNote(_ note: ThoughtNote) -> Bool {
        shouldShowHistorySampleNotes && Self.builtInSampleNoteIDs.contains(note.id)
    }

    func isChatSampleMessage(_ message: ChatMessage) -> Bool {
        shouldShowChatSampleMessages && Self.builtInSampleDisplayMessageIDs.contains(message.id)
    }

    func refreshRemotePushRegistration() async {
        await registerForRemotePushIfPossible()
    }

    func refreshCloudDataFromServer() async {
        guard session == .authenticated else { return }
        guard var authSession = currentSupabaseSession else { return }

        do {
            if authSession.needsRefresh {
                authSession = try await supabaseService.refresh(authSession)
                currentSupabaseSession = authSession
            }
            let remoteData = try await supabaseService.fetchAppData(using: authSession)
            applyRemoteAppData(remoteData)
            recycleExpiredReminders()
        } catch {
            print("Mindrop cloud refresh failed: \(error.localizedDescription)")
        }
    }

    func flushLocalSnapshot() {
        persistImmediately()
    }

    func flushPendingCloudChanges() {
        persistImmediately()
        scheduleCloudSync(delayMilliseconds: 0)
    }

    func login(account: String, password: String) async -> Bool {
        let email = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isValidEmail, !password.isEmpty else {
            showToast("请输入正确邮箱和密码")
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let authSession = try await supabaseService.signIn(email: email, password: password)
            isPreparingCloudSession = true
            defer { isPreparingCloudSession = false }
            currentSupabaseSession = authSession
            session = .authenticated
            selectedTab = .history
            selectedCategory = .todo
            removeBuiltInSampleDataFromCurrentState()
            await syncRemoteDataOrMigrateLegacy(using: authSession)
            recycleExpiredReminders()
            await syncCloudProfile(using: authSession)
            await registerForRemotePushIfPossible()
            showToast("登录成功，已开启云同步")
            return true
        } catch {
            showToast(authErrorMessage(from: error))
            return false
        }
    }

    func register(account: String, password: String, confirmPassword: String) async -> Bool {
        let email = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isValidEmail else {
            showToast("请输入正确邮箱")
            return false
        }
        guard password.isValidPassword else {
            showToast("密码至少8位且包含字母和数字")
            return false
        }
        guard password == confirmPassword else {
            showToast("两次密码不一致")
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            if let authSession = try await supabaseService.signUp(email: email, password: password) {
                isPreparingCloudSession = true
                defer { isPreparingCloudSession = false }
                currentSupabaseSession = authSession
                session = .authenticated
                selectedTab = .history
                selectedCategory = .todo
                removeBuiltInSampleDataFromCurrentState()
                await syncCloudProfile(using: authSession)
                await registerForRemotePushIfPossible()
                recycleExpiredReminders()
                queueCloudSyncIfNeeded()
                showToast("注册成功，已开启云同步")
            } else {
                showToast("注册成功，请查收确认邮件后再登录")
            }
            return true
        } catch {
            showToast(authErrorMessage(from: error))
            return false
        }
    }

    func useOffline() {
        currentSupabaseSession = nil
        Task { await supabaseService.signOut(nil) }
        session = .offline
        selectedTab = .history
        selectedCategory = .todo
    }

    func logout() {
        let authSession = currentSupabaseSession
        let deviceID = PushNotificationService.shared.deviceID
        let environment = PushNotificationService.shared.environment
        currentSupabaseSession = nil
        Task { [supabaseService] in
            if let authSession {
                try? await supabaseService.revokePushToken(
                    deviceID: deviceID,
                    environment: environment,
                    using: authSession
                )
            }
            await supabaseService.signOut(authSession)
        }
        session = .welcome
        profile = UserProfile.loggedOut
        selectedTab = .history
        selectedCategory = .todo
        showToast("已退出登录")
    }

    func deleteAccount() async -> Bool {
        guard session == .authenticated, let authSession = currentSupabaseSession else {
            showToast("请先登录账号")
            return false
        }

        isDeletingAccount = true
        cloudSyncTask?.cancel()
        defer { isDeletingAccount = false }

        do {
            try await supabaseService.deleteAccount(using: authSession)
            clearLocalDataAfterAccountDeletion()
            showToast("账号已注销")
            return true
        } catch {
            showToast("注销失败：\(authErrorMessage(from: error))")
            return false
        }
    }

    private func clearLocalDataAfterAccountDeletion() {
        let noteIDs = notes.map(\.id)
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        noteIDs.forEach { notificationScheduler.cancelReminder(for: $0) }

        isApplyingRemoteSnapshot = true
        currentSupabaseSession = nil
        feishuPairingDraft = nil
        pendingAIRequestCount = 0
        isAIThinking = false
        streamingAssistantMessageID = nil
        notes = []
        deletedNotes = []
        messages = []
        deletedMessages = []
        profileStats = .empty
        hasTrimmedChatHistory = false
        hasPendingCloudChanges = false
        cloudSyncRevision += 1
        profile = .loggedOut
        followsSystemAppearance = true
        selectedTab = .history
        selectedCategory = .todo
        session = .welcome
        isApplyingRemoteSnapshot = false

        try? supabaseService.clearSession()
        PersistenceStore.saveAndFlush(currentSnapshot())
    }

    func submitThought(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if isFeishuPairingCommand(text) {
            appendChatMessage(ChatMessage(role: .user, text: text, category: nil))
            Task { await replyWithFeishuPairingCode() }
            return
        }

        if feishuPairingDraft != nil {
            Task { await handleFeishuPairingInput(text) }
            return
        }

        if looksLikeFeishuConfiguration(text) {
            feishuPairingDraft = FeishuConfigurationDraft()
            Task { await handleFeishuPairingInput(text) }
            return
        }

        let context = recentAIContext()
        let reminders = reminderCandidates()
        let qaNotes = qaCandidates(for: context)
        appendChatMessage(ChatMessage(role: .user, text: text, category: nil))
        let fallback = localAnalysis(for: text)
        beginAIThinking()

        Task {
            defer { endAIThinking() }

            let result: AIAnalysisResult
            do {
                result = try await aiService.analyze(
                    text: text,
                    context: context,
                    reminderCandidates: reminders,
                    qaCandidates: qaNotes
                )
            } catch {
                print("Mindrop AI request failed: \(error)")
                result = fallbackResult(after: error, fallback: fallback)
                if !Task.isCancelled {
                    showToast("小落暂时连接不上服务，已先放到待办里")
                }
            }

            guard !Task.isCancelled else { return }
            applyAnalysisResult(result)
        }
    }

    private func applyAnalysisResult(_ result: AIAnalysisResult) {
        if result.action == .updateReminder {
            if applyReminderUpdate(result) {
                appendChatMessage(ChatMessage(role: .assistant, text: result.reply, category: .todo, noteID: result.targetNoteID))
            } else {
                appendChatMessage(ChatMessage(role: .assistant, text: "小落没找到要修改的提醒，可以再说具体一点~", category: .todo))
                showToast("未找到对应提醒")
            }
            selectedCategory = .todo
            return
        }

        if result.action == .deleteReminder {
            if let deletedNote = applyReminderDelete(result) {
                appendChatMessage(ChatMessage(role: .assistant, text: result.reply, category: .todo, noteID: deletedNote.id))
                showToast("已移至回收站")
            } else {
                appendChatMessage(ChatMessage(role: .assistant, text: "小落没找到要删除的提醒，可以再说具体一点~", category: .todo))
                showToast("未找到对应提醒")
            }
            selectedCategory = .todo
            return
        }

        if result.action == .updateQA {
            if applyQAUpdate(result) {
                appendChatMessage(ChatMessage(role: .assistant, text: result.reply, category: .qa, noteID: result.targetNoteID))
            } else {
                let note = makeNote(from: result)
                notes.insert(note, at: 0)
                recordNoteForStats(note)
                enforceQANoteLimit()
                appendChatMessage(ChatMessage(role: .assistant, text: result.reply, category: result.category, noteID: note.id))
            }
            selectedCategory = .qa
            return
        }

        let note = makeNote(from: result)
        notes.insert(note, at: 0)
        recordNoteForStats(note)
        enforceQANoteLimit()
        if note.reminderAt != nil {
            scheduleReminderAndPrepareText(for: note, forceRefresh: true)
        }

        appendChatMessage(ChatMessage(role: .assistant, text: result.reply, category: result.category, noteID: note.id))
        selectedCategory = result.category
    }

    private func applyReminderUpdate(_ result: AIAnalysisResult) -> Bool {
        guard result.category == .todo,
              let reminderAt = result.reminderAt,
              let index = targetReminderIndex(for: result) else {
            return false
        }

        var note = notes[index]
        notificationScheduler.cancelReminder(for: note.id)
        note.title = reminderUpdateText(result.title, fallback: note.title)
        note.content = reminderUpdateText(result.content, fallback: note.content)
        note.reminderAt = reminderAt
        note.reminderNotificationTitle = nil
        note.reminderNotificationBody = nil
        note.expenseAmount = nil
        note.expenseCategory = nil
        note.updatedAt = .now
        note.deletedAt = nil
        notes[index] = note
        recordNoteForStats(note)

        if reminderAt > .now {
            scheduleReminderAndPrepareText(for: note, forceRefresh: true)
        }
        showToast("提醒已更新")
        return true
    }

    private func applyReminderDelete(_ result: AIAnalysisResult) -> ThoughtNote? {
        guard result.category == .todo,
              let index = targetReminderIndex(for: result) else {
            return nil
        }

        let deletedNote = notes[index]
        moveToRecycleBin(deletedNote)
        return deletedNote
    }

    private func applyQAUpdate(_ result: AIAnalysisResult) -> Bool {
        guard result.category == .qa,
              let targetNoteID = result.targetNoteID,
              let index = notes.firstIndex(where: { $0.id == targetNoteID && $0.category == .qa }) else {
            return false
        }

        var note = notes[index]
        note.title = qaUpdateText(result.title, fallback: note.title)
        note.content = qaUpdateText(result.content, fallback: note.content)
        note.reminderAt = nil
        note.expenseAmount = nil
        note.expenseCategory = nil
        note.updatedAt = .now
        note.deletedAt = nil
        notes[index] = note
        recordNoteForStats(note)
        enforceQANoteLimit()
        return true
    }

    private func targetReminderIndex(for result: AIAnalysisResult) -> Int? {
        if let targetNoteID = result.targetNoteID,
           let index = notes.firstIndex(where: { $0.id == targetNoteID && $0.category == .todo }) {
            return index
        }

        let candidates = notes.enumerated().filter { _, note in
            note.category == .todo && note.reminderAt != nil
        }
        return candidates.count == 1 ? candidates[0].offset : nil
    }

    private func reminderUpdateText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "待办提醒" else { return fallback }
        return trimmed
    }

    private func qaUpdateText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "知识问答" else { return fallback }
        return trimmed
    }

    func moveToRecycleBin(_ note: ThoughtNote) {
        update(note) { draft in
            if draft.category != .recycleBin {
                draft.categoryBeforeRecycle = draft.category
            }
            draft.recycledAt = .now
            draft.category = .recycleBin
        }
        if let updatedNote = notes.first(where: { $0.id == note.id }) {
            recordNoteForStats(updatedNote)
        }
        notificationScheduler.cancelReminder(for: note.id)
    }

    func move(_ note: ThoughtNote, to category: ThoughtCategory) {
        update(note) { draft in
            draft.category = category
            if category != .recycleBin {
                draft.recycledAt = nil
                draft.categoryBeforeRecycle = nil
            }
            if category != .todo {
                draft.reminderAt = nil
                draft.reminderNotificationTitle = nil
                draft.reminderNotificationBody = nil
            }
            if category != .bill {
                draft.expenseAmount = nil
                draft.expenseCategory = nil
            }
        }
        guard let updatedNote = notes.first(where: { $0.id == note.id }) else { return }
        if updatedNote.category == .todo, let reminderAt = updatedNote.reminderAt, reminderAt > .now {
            scheduleReminderAndPrepareText(for: updatedNote)
        } else {
            notificationScheduler.cancelReminder(for: note.id)
        }
        recordNoteForStats(updatedNote)
        enforceQANoteLimit()
        showToast("已移动至“\(category.rawValue)”")
    }

    func pin(_ note: ThoughtNote) {
        update(note) { draft in
            draft.isPinned.toggle()
        }
    }

    func restore(_ note: ThoughtNote) {
        let now = Date()
        update(note) { draft in
            let restoredCategory = draft.categoryBeforeRecycle ?? .idea
            draft.category = restoredCategory == .recycleBin ? .idea : restoredCategory
            draft.recycledAt = nil
            draft.categoryBeforeRecycle = nil
            if draft.category == .todo, let reminderAt = draft.reminderAt, reminderAt <= now {
                draft.reminderAt = nil
                draft.reminderNotificationTitle = nil
                draft.reminderNotificationBody = nil
            } else if draft.category != .todo {
                draft.reminderAt = nil
                draft.reminderNotificationTitle = nil
                draft.reminderNotificationBody = nil
            }
            if draft.category != .bill {
                draft.expenseAmount = nil
                draft.expenseCategory = nil
            }
        }
        guard let restoredNote = notes.first(where: { $0.id == note.id }) else { return }
        if restoredNote.category == .todo, let reminderAt = restoredNote.reminderAt, reminderAt > .now {
            scheduleReminderAndPrepareText(for: restoredNote)
        } else {
            notificationScheduler.cancelReminder(for: restoredNote.id)
        }
        recordNoteForStats(restoredNote)
        enforceQANoteLimit()
        showToast("已还原至“\(restoredNote.category.rawValue)”")
    }

    func deletePermanently(_ note: ThoughtNote) {
        rememberDeletedNote(note)
        notes.removeAll { $0.id == note.id }
        notificationScheduler.cancelReminder(for: note.id)
    }

    func purgeExpiredRecycleBinNotes() {
        let deadline = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let expiredIDs = notes
            .filter { $0.category == .recycleBin && ($0.recycledAt ?? $0.createdAt) < deadline }
            .map(\.id)
        guard !expiredIDs.isEmpty else { return }
        notes
            .filter { expiredIDs.contains($0.id) }
            .forEach { rememberDeletedNote($0) }
        notes.removeAll { expiredIDs.contains($0.id) }
        expiredIDs.forEach { notificationScheduler.cancelReminder(for: $0) }
    }

    func recycleExpiredReminders(now: Date = .now) {
        let deadline = now.addingTimeInterval(-expiredReminderRecycleInterval)
        var updatedNotes = notes
        var recycledNoteIDs: [UUID] = []

        for index in updatedNotes.indices {
            guard updatedNotes[index].category == .todo,
                  let reminderAt = updatedNotes[index].reminderAt,
                  reminderAt <= deadline else {
                continue
            }

            updatedNotes[index].categoryBeforeRecycle = .todo
            updatedNotes[index].recycledAt = now
            updatedNotes[index].category = .recycleBin
            updatedNotes[index].updatedAt = now
            updatedNotes[index].deletedAt = nil
            recordNoteForStats(updatedNotes[index])
            recycledNoteIDs.append(updatedNotes[index].id)
        }

        guard !recycledNoteIDs.isEmpty else { return }
        recycledNoteIDs.forEach { notificationScheduler.cancelReminder(for: $0) }
        let shouldForceCloudSync = isPreparingCloudSession
        notes = updatedNotes
        if shouldForceCloudSync {
            markPendingCloudChanges()
            PersistenceStore.save(currentSnapshot())
            scheduleCloudSync()
        }
    }

    func updateNote(_ note: ThoughtNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updatedNote = note
        let previousNote = notes[index]
        if updatedNote.category == .recycleBin, previousNote.category != .recycleBin {
            updatedNote.categoryBeforeRecycle = previousNote.category
            updatedNote.recycledAt = .now
        } else if updatedNote.category != .recycleBin {
            updatedNote.categoryBeforeRecycle = nil
            updatedNote.recycledAt = nil
        }
        updatedNote.reminderNotificationTitle = nil
        updatedNote.reminderNotificationBody = nil
        updatedNote.updatedAt = .now
        updatedNote.deletedAt = nil
        notes[index] = updatedNote
        recordNoteForStats(updatedNote)
        enforceQANoteLimit()
        if updatedNote.category == .todo, let reminderAt = updatedNote.reminderAt, reminderAt > .now {
            scheduleReminderAndPrepareText(for: updatedNote, forceRefresh: true)
        } else {
            notificationScheduler.cancelReminder(for: updatedNote.id)
        }
        showToast("已保存")
    }

    func updateProfile(
        nickname: String,
        userID: String,
        avatarDataBase64: String? = nil,
        shouldRemoveAvatar: Bool = false
    ) async -> Bool {
        let nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (1...16).contains(nickname.count) else {
            showToast("昵称需为 1-16 个字符")
            return false
        }
        guard userID.isValidMindropID else {
            showToast("ID 需为 3-20 位字母或数字")
            return false
        }

        var updatedProfile = profile
        updatedProfile.nickname = nickname
        updatedProfile.userID = userID
        updatedProfile.avatarDataBase64 = nil

        if session == .authenticated, let authSession = currentSupabaseSession {
            isSavingProfile = true
            defer { isSavingProfile = false }

            do {
                if let avatarDataBase64,
                   let avatarData = Data(base64Encoded: avatarDataBase64) {
                    updatedProfile.avatarURL = try await supabaseService.uploadAvatar(avatarData, using: authSession)
                    updatedProfile.avatarName = UserProfile.defaultAvatarName
                } else if shouldRemoveAvatar {
                    updatedProfile.avatarURL = nil
                    updatedProfile.avatarName = UserProfile.defaultAvatarName
                }
                let cloudProfile = try await supabaseService.upsertProfile(updatedProfile, using: authSession)
                profile = cloudProfile.userProfile
            } catch {
                showToast(authErrorMessage(from: error))
                return false
            }
        } else {
            updatedProfile.avatarDataBase64 = avatarDataBase64
            if shouldRemoveAvatar {
                updatedProfile.avatarURL = nil
                updatedProfile.avatarDataBase64 = nil
                updatedProfile.avatarName = UserProfile.defaultAvatarName
            }
            profile = updatedProfile
        }

        showToast("个人资料已更新")
        return true
    }

    func saveConversationToIdea(message: ChatMessage) {
        let note = ThoughtNote(
            title: title(from: message.text, fallback: "问答灵感"),
            content: message.text,
            category: .idea
        )
        notes.insert(note, at: 0)
        recordNoteForStats(note)
        showToast("已保存至灵感沉淀")
    }

    func deleteChatMessage(_ message: ChatMessage) {
        rememberDeletedMessage(message)
        messages.removeAll { $0.id == message.id }
        if streamingAssistantMessageID == message.id {
            streamingAssistantMessageID = nil
        }
    }

    func presentToast(_ message: String) {
        showToast(message)
    }

    private func update(_ note: ThoughtNote, mutate: (inout ThoughtNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        mutate(&notes[index])
        notes[index].updatedAt = .now
        notes[index].deletedAt = nil
    }

    private func rememberDeletedNote(_ note: ThoughtNote) {
        recordNoteForStats(note)
        var tombstone = note
        let deletedAt = Date()
        tombstone.deletedAt = deletedAt
        tombstone.updatedAt = deletedAt
        if let index = deletedNotes.firstIndex(where: { $0.id == tombstone.id }) {
            if tombstone.isNewerSyncRecord(than: deletedNotes[index]) {
                deletedNotes[index] = tombstone
            }
        } else {
            deletedNotes.append(tombstone)
        }
    }

    private func rememberDeletedMessage(_ message: ChatMessage) {
        recordMessageForStats(message)
        var tombstone = message
        let deletedAt = Date()
        tombstone.deletedAt = deletedAt
        tombstone.updatedAt = deletedAt
        if let index = deletedMessages.firstIndex(where: { $0.id == tombstone.id }) {
            if tombstone.isNewerSyncRecord(than: deletedMessages[index]) {
                deletedMessages[index] = tombstone
            }
        } else {
            deletedMessages.append(tombstone)
        }
    }

    @discardableResult
    private func backfillProfileStatsFromCurrentData() -> Bool {
        let sampleMessageIDs = Self.builtInSampleMessageIDs(in: messages)
        var stats = profileStats

        for note in notes + deletedNotes where !Self.isBuiltInSampleNote(note) {
            guard let record = Self.noteStatRecord(for: note) else { continue }
            Self.upsertNoteStat(record, into: &stats)
        }

        for message in messages + deletedMessages where !Self.shouldSkipMessageStatBackfill(message, sampleMessageIDs: sampleMessageIDs) {
            guard let record = Self.messageStatRecord(for: message) else { continue }
            Self.upsertMessageStat(record, into: &stats)
        }

        stats = Self.normalizedProfileStats(stats)
        guard stats != profileStats else { return false }
        profileStats = stats
        return true
    }

    private func recordNoteForStats(_ note: ThoughtNote) {
        guard !Self.isBuiltInSampleNote(note),
              let record = Self.noteStatRecord(for: note) else {
            return
        }

        var stats = profileStats
        Self.upsertNoteStat(record, into: &stats)
        stats = Self.normalizedProfileStats(stats)
        if stats != profileStats {
            profileStats = stats
        }
    }

    private func recordMessageForStats(_ message: ChatMessage) {
        guard let record = Self.messageStatRecord(for: message) else { return }

        var stats = profileStats
        Self.upsertMessageStat(record, into: &stats)
        stats = Self.normalizedProfileStats(stats)
        if stats != profileStats {
            profileStats = stats
        }
    }

    private static func noteStatRecord(for note: ThoughtNote) -> NoteStatRecord? {
        guard let category = statsCategory(for: note) else { return nil }
        return NoteStatRecord(
            noteID: note.id,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            category: category,
            expenseAmount: category == .bill ? note.expenseAmount : nil,
            expenseCategory: category == .bill ? (note.expenseCategory ?? .other) : nil
        )
    }

    private static func messageStatRecord(for message: ChatMessage) -> MessageStatRecord? {
        guard message.role == .user else { return nil }
        return MessageStatRecord(
            messageID: message.id,
            createdAt: message.createdAt,
            updatedAt: message.updatedAt
        )
    }

    private static func shouldSkipMessageStatBackfill(_ message: ChatMessage, sampleMessageIDs: Set<UUID>) -> Bool {
        sampleMessageIDs.contains(message.id) ||
            (message.deletedAt != nil && builtInSampleMessageTemplateIndex(for: message) != nil)
    }

    private static func statsCategory(for note: ThoughtNote) -> ThoughtCategory? {
        if note.category != .recycleBin {
            return note.category
        }

        if let category = note.categoryBeforeRecycle, category != .recycleBin {
            return category
        }
        if note.expenseAmount != nil || note.expenseCategory != nil {
            return .bill
        }
        if note.reminderAt != nil {
            return .todo
        }
        return .idea
    }

    private static func mergedProfileStats(_ local: ProfileStats, _ remote: ProfileStats) -> ProfileStats {
        var stats = local
        for record in remote.noteRecords {
            upsertNoteStat(record, into: &stats)
        }
        for record in remote.messageRecords {
            upsertMessageStat(record, into: &stats)
        }
        return normalizedProfileStats(stats)
    }

    private static func upsertNoteStat(_ record: NoteStatRecord, into stats: inout ProfileStats) {
        if let index = stats.noteRecords.firstIndex(where: { $0.noteID == record.noteID }) {
            if record.updatedAt >= stats.noteRecords[index].updatedAt {
                stats.noteRecords[index] = record
            }
        } else {
            stats.noteRecords.append(record)
        }
    }

    private static func upsertMessageStat(_ record: MessageStatRecord, into stats: inout ProfileStats) {
        if let index = stats.messageRecords.firstIndex(where: { $0.messageID == record.messageID }) {
            if record.updatedAt >= stats.messageRecords[index].updatedAt {
                stats.messageRecords[index] = record
            }
        } else {
            stats.messageRecords.append(record)
        }
    }

    private static func normalizedProfileStats(_ stats: ProfileStats) -> ProfileStats {
        ProfileStats(
            noteRecords: stats.noteRecords.sorted { $0.createdAt > $1.createdAt },
            messageRecords: stats.messageRecords.sorted { $0.createdAt < $1.createdAt }
        )
    }

    private func observeRemotePushTokenUpdates() {
        pushTokenObserver = NotificationCenter.default.addObserver(
            forName: .mindropDidUpdateRemotePushToken,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncStoredRemotePushTokenIfPossible()
            }
        }
    }

    private func replyWithFeishuPairingCode() async {
        guard session == .authenticated, currentSupabaseSession != nil else {
            appendChatMessage(ChatMessage(role: .assistant, text: "先登录 Mindrop，再对我说“飞书配对”。", category: nil))
            showToast("请先登录后再配对飞书")
            return
        }

        feishuPairingDraft = FeishuConfigurationDraft()
        appendChatMessage(ChatMessage(
            role: .assistant,
            text: """
            🎉恭喜你发现了彩蛋！让我来跟你的飞书bot完成配对吧，配置成功后，你可以直接在飞书上跟我交流，数据也会同步到app中~

            接下来需要 4 个信息：
            1. App ID：在飞书开放平台 > 你的企业自建应用 > 凭证与基础信息里。
            2. App Secret：同样在凭证与基础信息里。
            3. Verification Token：在事件与回调/事件订阅 > 加密策略里。
            4. Encrypt Key：同样在事件与回调/事件订阅 > 加密策略里；如果为空，先开启或重置加密策略生成。

            收集完成后，我会生成你的专属回调地址和绑定码。你发来的这些值不会写入聊天记录。

            \(feishuPairingPrompt(for: .appID))
            """,
            category: nil
        ))
    }

    private func handleFeishuPairingInput(_ text: String) async {
        guard session == .authenticated, let authSession = currentSupabaseSession else {
            feishuPairingDraft = nil
            appendChatMessage(ChatMessage(role: .assistant, text: "先登录 Mindrop，再对我说“飞书配对”。", category: nil))
            showToast("请先登录后再配对飞书")
            return
        }

        if isCancelFeishuPairingCommand(text) {
            feishuPairingDraft = nil
            appendChatMessage(ChatMessage(role: .user, text: "取消飞书配对", category: nil))
            appendChatMessage(ChatMessage(role: .assistant, text: "已取消飞书配对。之后需要时再对我说“飞书配对”。", category: nil))
            return
        }

        var draft = feishuPairingDraft ?? FeishuConfigurationDraft()
        let parsedDraft = parseFeishuConfiguration(text)
        if parsedDraft.hasAnyValue {
            draft.merge(parsedDraft)
            appendChatMessage(ChatMessage(
                role: .user,
                text: "飞书配置（已隐藏）",
                category: nil
            ))
        } else if let field = draft.currentField {
            let value = valueForFeishuField(from: text, field: field)
            appendChatMessage(ChatMessage(
                role: .user,
                text: "\(field.displayName) 已填写（已隐藏）",
                category: nil
            ))

            guard isPlausibleFeishuValue(value, for: field) else {
                appendChatMessage(ChatMessage(
                    role: .assistant,
                    text: "\(field.displayName) 看起来没有识别到。\(feishuPairingPrompt(for: field))",
                    category: nil
                ))
                feishuPairingDraft = draft
                return
            }

            draft.set(value, for: field)
        }

        guard let credentials = draft.credentials else {
            feishuPairingDraft = draft
            if let nextField = draft.currentField {
                appendChatMessage(ChatMessage(role: .assistant, text: feishuPairingPrompt(for: nextField), category: nil))
            }
            return
        }

        feishuPairingDraft = nil
        do {
            let setup = try await supabaseService.createFeishuConnection(credentials: credentials, using: authSession)
            UIPasteboard.general.string = setup.callbackURL
            appendChatMessage(ChatMessage(
                role: .assistant,
                text: """
                已生成你的飞书 Bot 连接。

                回调地址：
                \(setup.callbackURL)

                保存通过后，去你的 Bot 单聊发送：
                绑定 \(setup.pairingCode)

                绑定码 30 分钟内有效。我已经帮你复制了回调地址。
                """,
                category: nil
            ))
            showToast("飞书回调地址已复制")
        } catch {
            appendChatMessage(ChatMessage(role: .assistant, text: "飞书连接创建失败：\(error.localizedDescription)", category: nil))
            showToast("飞书连接创建失败")
        }
    }

    private func feishuPairingPrompt(for field: FeishuConfigurationField) -> String {
        switch field {
        case .appID:
            return "先把 App ID 发给我。位置：飞书开放平台 > 你的企业自建应用 > 凭证与基础信息 > App ID。通常以 cli_ 开头。"
        case .appSecret:
            return "现在把 App Secret 发给我。位置：飞书开放平台 > 你的企业自建应用 > 凭证与基础信息 > App Secret。"
        case .verificationToken:
            return "现在把 Verification Token 发给我。位置：飞书开放平台 > 你的企业自建应用 > 事件与回调/事件订阅 > 加密策略 > Verification Token。"
        case .encryptKey:
            return "最后把 Encrypt Key 发给我。位置：飞书开放平台 > 你的企业自建应用 > 事件与回调/事件订阅 > 加密策略 > Encrypt Key；如果为空，先开启或重置加密策略生成。"
        }
    }

    private func valueForFeishuField(from text: String, field: FeishuConfigurationField) -> String {
        let parsedDraft = parseFeishuConfiguration(text)
        if let parsedValue = parsedDraft.value(for: field), !parsedValue.isEmpty {
            return parsedValue
        }
        if let separatorIndex = text.firstIndex(where: { $0 == ":" || $0 == "：" || $0 == "=" }) {
            return sanitizeFeishuConfigValue(String(text[text.index(after: separatorIndex)...]))
        }
        return sanitizeFeishuConfigValue(text.components(separatedBy: .newlines).first ?? text)
    }

    private func isPlausibleFeishuValue(_ value: String, for field: FeishuConfigurationField) -> Bool {
        let trimmed = sanitizeFeishuConfigValue(value)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return false
        }

        switch field {
        case .appID:
            return trimmed.lowercased().hasPrefix("cli_") && trimmed.count >= 8
        case .appSecret:
            return trimmed.count >= 8
        case .verificationToken, .encryptKey:
            return trimmed.count >= 4
        }
    }

    private func isCancelFeishuPairingCommand(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return ["取消", "取消飞书配对", "停止飞书配对", "退出飞书配对", "cancel"].contains(normalized)
    }

    private func looksLikeFeishuConfiguration(_ text: String) -> Bool {
        let normalized = normalizeFeishuConfigKey(text)
        return normalized.contains("飞书配置") ||
            normalized.contains("feishuappid") ||
            normalized.contains("appid") ||
            normalized.contains("appsecret") ||
            normalized.contains("verificationtoken") ||
            normalized.contains("encryptkey")
    }

    private func parseFeishuConfiguration(_ text: String) -> FeishuConfigurationDraft {
        var appID = ""
        var appSecret = ""
        var verificationToken = ""
        var encryptKey = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separatorIndex = line.firstIndex(where: { $0 == ":" || $0 == "：" || $0 == "=" }) else {
                continue
            }

            let rawKey = String(line[..<separatorIndex])
            let rawValue = String(line[line.index(after: separatorIndex)...])
            let key = normalizeFeishuConfigKey(rawKey)
            let value = sanitizeFeishuConfigValue(rawValue)

            if key.contains("appid") || key.contains("应用id") {
                appID = value
            } else if key.contains("appsecret") || key.contains("应用secret") || key.contains("应用密钥") {
                appSecret = value
            } else if key.contains("verificationtoken") || key.contains("verification") || key.contains("验证token") {
                verificationToken = value
            } else if key.contains("encryptkey") || key.contains("加密key") {
                encryptKey = value
            }
        }

        return FeishuConfigurationDraft(
            appID: appID,
            appSecret: appSecret,
            verificationToken: verificationToken,
            encryptKey: encryptKey
        )
    }

    private func normalizeFeishuConfigKey(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func sanitizeFeishuConfigValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    }

    private func isFeishuPairingCommand(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return ["飞书配对", "飞书绑定", "配对飞书", "绑定飞书", "lark配对", "feishu配对"].contains(normalized)
    }

    private func registerForRemotePushIfPossible() async {
        guard session == .authenticated else {
            mindropPushDebugLog("Mindrop push: skip registration because session=\(session.rawValue)")
            return
        }
        guard currentSupabaseSession != nil else {
            mindropPushDebugLog("Mindrop push: skip registration because Supabase session is missing")
            return
        }
        guard await PushNotificationService.shared.requestAuthorizationAndRegister() else { return }
        await syncStoredRemotePushTokenIfPossible()
    }

    private func syncStoredRemotePushTokenIfPossible() async {
        guard session == .authenticated else {
            mindropPushDebugLog("Mindrop push: skip token upload because session=\(session.rawValue)")
            return
        }
        guard let authSession = currentSupabaseSession else {
            mindropPushDebugLog("Mindrop push: skip token upload because Supabase session is missing")
            return
        }
        guard let token = PushNotificationService.shared.deviceToken, !token.isEmpty else {
            mindropPushDebugLog("Mindrop push: skip token upload because APNs token is not available yet")
            return
        }

        do {
            mindropPushDebugLog("Mindrop push: uploading APNs token prefix=\(String(token.prefix(12))) environment=\(PushNotificationService.shared.environment)")
            try await supabaseService.upsertPushToken(
                deviceID: PushNotificationService.shared.deviceID,
                token: token,
                environment: PushNotificationService.shared.environment,
                using: authSession
            )
            mindropPushDebugLog("Mindrop push: uploaded APNs token")
            cancelFutureLocalReminders()
        } catch {
            mindropPushDebugLog("Mindrop push token sync failed: \(error.localizedDescription)")
        }
    }

    private func persistIfReady(markCloudDirty: Bool) {
        guard !isRestoring, !isApplyingRemoteSnapshot, !isPreparingCloudSession else { return }
        if markCloudDirty {
            markPendingCloudChanges()
        }
        PersistenceStore.save(currentSnapshot())
        if markCloudDirty {
            scheduleCloudSync()
        }
    }

    private func persistImmediately() {
        guard !isRestoring, !isApplyingRemoteSnapshot, !isPreparingCloudSession else { return }
        PersistenceStore.saveAndFlush(currentSnapshot())
    }

    private func currentSnapshot() -> AppSnapshot {
        AppSnapshot(
            session: session,
            notes: notes,
            deletedNotes: deletedNotes,
            messages: messages,
            deletedMessages: deletedMessages,
            profileStats: profileStats,
            hasTrimmedChatHistory: hasTrimmedChatHistory,
            hasPendingCloudChanges: hasPendingCloudChanges,
            profile: profile,
            followsSystemAppearance: followsSystemAppearance
        )
    }

    private func removeBuiltInSampleDataFromCurrentState() {
        let sampleNoteIDs = notes.filter(Self.isBuiltInSampleNote).map(\.id)
        let sampleMessageIDs = Self.builtInSampleMessageIDs(in: messages)
        sampleNoteIDs.forEach { notificationScheduler.cancelReminder(for: $0) }
        notes.removeAll(where: Self.isBuiltInSampleNote)
        messages.removeAll { sampleMessageIDs.contains($0.id) }
    }

    private func restoreSupabaseSession() async {
        do {
            guard var authSession = try supabaseService.storedSession() else {
                if session == .authenticated {
                    session = .welcome
                }
                return
            }

            if authSession.needsRefresh {
                authSession = try await supabaseService.refresh(authSession)
            }

            isPreparingCloudSession = true
            defer { isPreparingCloudSession = false }
            currentSupabaseSession = authSession
            session = .authenticated
            selectedTab = .history
            selectedCategory = .todo
            removeBuiltInSampleDataFromCurrentState()
            await syncRemoteDataOrMigrateLegacy(using: authSession)
            recycleExpiredReminders()
            await syncCloudProfile(using: authSession)
            await registerForRemotePushIfPossible()
        } catch {
            currentSupabaseSession = nil
            try? supabaseService.clearSession()
            if session == .authenticated {
                session = .welcome
                showToast("登录已过期，请重新登录")
            }
        }
    }

    private func syncRemoteDataOrMigrateLegacy(using authSession: SupabaseSession) async {
        do {
            let remoteData = try await supabaseService.fetchAppData(using: authSession)
            let legacySnapshot = try await supabaseService.fetchSnapshot(using: authSession)

            if remoteData.hasContentRows {
                applyRemoteAppData(remoteData)
            } else if let legacySnapshot, !legacySnapshot.notes.isEmpty || !legacySnapshot.messages.isEmpty {
                applyRemoteSnapshot(legacySnapshot, shouldUploadMergedData: true)
                showToast("已恢复旧版云端数据")
            } else if remoteData.hasRemoteRows {
                applyRemoteAppData(remoteData)
            } else if let legacySnapshot {
                applyRemoteSnapshot(legacySnapshot, shouldUploadMergedData: false)
            } else {
                queueCloudSyncIfNeeded()
            }
        } catch {
            queueCloudSyncIfNeeded()
            showToast("云端数据暂时无法读取，已保留本机数据")
        }
    }

    private func syncCloudProfile(using authSession: SupabaseSession) async {
        do {
            if let cloudProfile = try await supabaseService.fetchProfile(using: authSession) {
                profile = try await migrateLegacyAvatarIfNeeded(from: cloudProfile, using: authSession)
                persistCloudProfileChange()
                return
            }

            let createdProfile = try await createInitialCloudProfile(using: authSession)
            profile = createdProfile.userProfile
            persistCloudProfileChange()
        } catch {
            print("Mindrop profile sync failed: \(error.localizedDescription)")
            showToast("个人资料同步失败：\(authErrorMessage(from: error))")
        }
    }

    private func persistCloudProfileChange() {
        PersistenceStore.save(currentSnapshot())
    }

    private func migrateLegacyAvatarIfNeeded(
        from cloudProfile: SupabaseProfile,
        using authSession: SupabaseSession
    ) async throws -> UserProfile {
        var migratedProfile = cloudProfile.userProfile
        guard migratedProfile.avatarURL == nil,
              let legacyAvatar = cloudProfile.legacyAvatarDataBase64,
              let avatarData = Data(base64Encoded: legacyAvatar) else {
            return migratedProfile
        }

        migratedProfile.avatarURL = try await supabaseService.uploadAvatar(avatarData, using: authSession)
        migratedProfile.avatarDataBase64 = nil
        let savedProfile = try await supabaseService.upsertProfile(migratedProfile, using: authSession)
        return savedProfile.userProfile
    }

    private func createInitialCloudProfile(using authSession: SupabaseSession) async throws -> SupabaseProfile {
        var lastDuplicateError: Error?

        for _ in 0..<5 {
            var fallbackProfile = profile
            fallbackProfile.userID = randomNumericMindropID()
            if fallbackProfile.avatarURL == nil,
               let avatarDataBase64 = fallbackProfile.avatarDataBase64,
               let avatarData = Data(base64Encoded: avatarDataBase64) {
                fallbackProfile.avatarURL = try await supabaseService.uploadAvatar(avatarData, using: authSession)
                fallbackProfile.avatarDataBase64 = nil
            }

            do {
                return try await supabaseService.upsertProfile(fallbackProfile, using: authSession)
            } catch {
                guard isDuplicateProfileIDError(error) else { throw error }
                lastDuplicateError = error
            }
        }

        throw lastDuplicateError ?? SupabaseServiceError.unexpectedResponse
    }

    private func randomNumericMindropID() -> String {
        String(format: "%08d", Int.random(in: 0...99_999_999))
    }

    private func applyRemoteSnapshot(_ snapshot: AppSnapshot, shouldUploadMergedData: Bool) {
        let shouldResumePendingSync = hasPendingCloudChanges
        cloudSyncTask?.cancel()
        isApplyingRemoteSnapshot = true
        session = .authenticated
        let sampleDeletedAt = Date()
        let remoteSampleNoteTombstones = snapshot.notes
            .filter(Self.isBuiltInSampleNote)
            .map { Self.deletedBuiltInSampleNote($0, deletedAt: sampleDeletedAt) }
        let localSampleMessageIDs = Self.builtInSampleMessageIDs(in: messages)
        let remoteSampleMessageIDs = Self.builtInSampleMessageIDs(in: snapshot.messages)
        let remoteSampleMessageTombstones = snapshot.messages
            .filter { remoteSampleMessageIDs.contains($0.id) }
            .map { Self.deletedBuiltInSampleMessage($0, deletedAt: sampleDeletedAt) }
        let mergedNotes = mergeNotes(
            localActive: notes.filter { !Self.isBuiltInSampleNote($0) },
            localDeleted: deletedNotes,
            remoteActive: snapshot.notes.filter { $0.deletedAt == nil && !Self.isBuiltInSampleNote($0) },
            remoteDeleted: snapshot.deletedNotes + snapshot.notes.filter { $0.deletedAt != nil } + remoteSampleNoteTombstones
        )
        notes = mergedNotes.active
        deletedNotes = mergedNotes.deleted
        let mergedMessages = mergeMessages(
            localActive: messages.filter { !localSampleMessageIDs.contains($0.id) },
            localDeleted: deletedMessages,
            remoteActive: snapshot.messages.filter { $0.deletedAt == nil && !remoteSampleMessageIDs.contains($0.id) },
            remoteDeleted: snapshot.deletedMessages + snapshot.messages.filter { $0.deletedAt != nil } + remoteSampleMessageTombstones
        )
        messages = mergedMessages.active
        deletedMessages = mergedMessages.deleted
        profileStats = Self.mergedProfileStats(profileStats, snapshot.profileStats)
        hasTrimmedChatHistory = snapshot.hasTrimmedChatHistory
        profile = snapshot.profile
        followsSystemAppearance = snapshot.followsSystemAppearance
        enforceChatHistoryLimit()
        let didEnforceQALimit = enforceQANoteLimit()
        _ = migrateDefaultMeetingSampleReminder()
        let didBackfillStats = backfillProfileStatsFromCurrentData()
        isApplyingRemoteSnapshot = false

        PersistenceStore.save(currentSnapshot())
        if shouldUploadMergedData || didEnforceQALimit || didBackfillStats {
            markPendingCloudChanges()
            PersistenceStore.save(currentSnapshot())
            scheduleCloudSync()
        } else if shouldResumePendingSync {
            scheduleCloudSync(delayMilliseconds: 1_500)
        }
        Task {
            await rescheduleFutureReminders()
        }
    }

    private func applyRemoteAppData(_ data: SupabaseAppData) {
        let shouldResumePendingSync = hasPendingCloudChanges
        cloudSyncTask?.cancel()
        isApplyingRemoteSnapshot = true
        session = .authenticated
        let sampleDeletedAt = Date()
        let remoteSampleNoteTombstones = data.notes
            .filter(Self.isBuiltInSampleNote)
            .map { Self.deletedBuiltInSampleNote($0, deletedAt: sampleDeletedAt) }
        let localSampleMessageIDs = Self.builtInSampleMessageIDs(in: messages)
        let remoteSampleMessageIDs = Self.builtInSampleMessageIDs(in: data.messages)
        let remoteSampleMessageTombstones = data.messages
            .filter { remoteSampleMessageIDs.contains($0.id) }
            .map { Self.deletedBuiltInSampleMessage($0, deletedAt: sampleDeletedAt) }
        let mergedNotes = mergeNotes(
            localActive: notes.filter { !Self.isBuiltInSampleNote($0) },
            localDeleted: deletedNotes,
            remoteActive: data.notes.filter { !Self.isBuiltInSampleNote($0) },
            remoteDeleted: data.deletedNotes + remoteSampleNoteTombstones
        )
        notes = mergedNotes.active
        deletedNotes = mergedNotes.deleted
        let mergedMessages = mergeMessages(
            localActive: messages.filter { !localSampleMessageIDs.contains($0.id) },
            localDeleted: deletedMessages,
            remoteActive: data.messages.filter { !remoteSampleMessageIDs.contains($0.id) },
            remoteDeleted: data.deletedMessages + remoteSampleMessageTombstones
        )
        messages = mergedMessages.active
        deletedMessages = mergedMessages.deleted
        profileStats = Self.mergedProfileStats(profileStats, data.profileStats)
        hasTrimmedChatHistory = data.hasTrimmedChatHistory
        followsSystemAppearance = data.followsSystemAppearance
        enforceChatHistoryLimit()
        let didEnforceQALimit = enforceQANoteLimit()
        _ = migrateDefaultMeetingSampleReminder()
        let didBackfillStats = backfillProfileStatsFromCurrentData()
        isApplyingRemoteSnapshot = false

        PersistenceStore.save(currentSnapshot())
        if didEnforceQALimit || didBackfillStats {
            markPendingCloudChanges()
            PersistenceStore.save(currentSnapshot())
            scheduleCloudSync()
        } else if shouldResumePendingSync {
            scheduleCloudSync(delayMilliseconds: 1_500)
        }
        Task {
            await rescheduleFutureReminders()
        }
    }

    private func mergeNotes(
        localActive: [ThoughtNote],
        localDeleted: [ThoughtNote],
        remoteActive: [ThoughtNote],
        remoteDeleted: [ThoughtNote]
    ) -> (active: [ThoughtNote], deleted: [ThoughtNote]) {
        var mergedByID: [UUID: ThoughtNote] = [:]
        for note in localActive + localDeleted + remoteActive + remoteDeleted {
            if let current = mergedByID[note.id] {
                mergedByID[note.id] = note.isNewerSyncRecord(than: current) ? note : current
            } else {
                mergedByID[note.id] = note
            }
        }

        let active = mergedByID.values
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.createdAt > rhs.createdAt
            }
        let deleted = mergedByID.values
            .filter { $0.deletedAt != nil }
            .sorted { $0.syncTimestamp > $1.syncTimestamp }
        return (active, deleted)
    }

    private func mergeMessages(
        localActive: [ChatMessage],
        localDeleted: [ChatMessage],
        remoteActive: [ChatMessage],
        remoteDeleted: [ChatMessage]
    ) -> (active: [ChatMessage], deleted: [ChatMessage]) {
        var mergedByID: [UUID: ChatMessage] = [:]
        for message in localActive + localDeleted + remoteActive + remoteDeleted {
            if let current = mergedByID[message.id] {
                mergedByID[message.id] = message.isNewerSyncRecord(than: current) ? message : current
            } else {
                mergedByID[message.id] = message
            }
        }

        let active = mergedByID.values
            .filter { $0.deletedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
        let deleted = mergedByID.values
            .filter { $0.deletedAt != nil }
            .sorted { $0.syncTimestamp > $1.syncTimestamp }
        return (active, deleted)
    }

    private var hasSyncableCloudContent: Bool {
        let sampleMessageIDs = Self.builtInSampleMessageIDs(in: messages)
        return notes.contains { !Self.isBuiltInSampleNote($0) } ||
            !deletedNotes.isEmpty ||
            messages.contains { !sampleMessageIDs.contains($0.id) } ||
            !deletedMessages.isEmpty ||
            !profileStats.noteRecords.isEmpty ||
            !profileStats.messageRecords.isEmpty ||
            hasTrimmedChatHistory ||
            !followsSystemAppearance
    }

    private var hasUserCreatedRealNotes: Bool {
        notes.contains { !Self.isBuiltInSampleNote($0) } ||
            deletedNotes.contains { !Self.isBuiltInSampleNote($0) } ||
            !profileStats.noteRecords.isEmpty
    }

    private var hasUserCreatedRealMessages: Bool {
        let sampleMessageIDs = Self.builtInSampleMessageIDs(in: messages)
        return messages.contains { !sampleMessageIDs.contains($0.id) } ||
            deletedMessages.contains { Self.builtInSampleMessageTemplateIndex(for: $0) == nil } ||
            !profileStats.messageRecords.isEmpty
    }

    private func queueCloudSyncIfNeeded(delayMilliseconds: UInt64 = 500) {
        guard hasSyncableCloudContent else { return }
        markPendingCloudChanges()
        PersistenceStore.save(currentSnapshot())
        scheduleCloudSync(delayMilliseconds: delayMilliseconds)
    }

    private func markPendingCloudChanges() {
        hasPendingCloudChanges = true
        cloudSyncRevision += 1
    }

    private func scheduleCloudSync(delayMilliseconds: UInt64 = 500) {
        guard session == .authenticated, let authSession = currentSupabaseSession else { return }
        guard hasPendingCloudChanges else { return }
        let notes = notes.filter { !Self.isBuiltInSampleNote($0) }
        let deletedNotes = deletedNotes
        let sampleMessageIDs = Self.builtInSampleMessageIDs(in: messages)
        let messages = messages.filter { !sampleMessageIDs.contains($0.id) }
        let deletedMessages = deletedMessages
        let profileStats = profileStats
        let hasTrimmedChatHistory = hasTrimmedChatHistory
        let followsSystemAppearance = followsSystemAppearance
        let syncRevision = cloudSyncRevision
        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self, supabaseService, authSession, notes, deletedNotes, messages, deletedMessages, profileStats, hasTrimmedChatHistory, followsSystemAppearance, delayMilliseconds, syncRevision] in
            do {
                if delayMilliseconds > 0 {
                    try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
                }
                try await supabaseService.syncAppData(
                    notes: notes,
                    deletedNotes: deletedNotes,
                    messages: messages,
                    deletedMessages: deletedMessages,
                    profileStats: profileStats,
                    hasTrimmedChatHistory: hasTrimmedChatHistory,
                    followsSystemAppearance: followsSystemAppearance,
                    using: authSession
                )
                await MainActor.run {
                    guard let self, self.cloudSyncRevision == syncRevision else { return }
                    self.hasPendingCloudChanges = false
                    PersistenceStore.save(self.currentSnapshot())
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Self.isCancellationError(error) else { return }
                print("Mindrop cloud sync failed: \(error.localizedDescription)")
            }
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func authErrorMessage(from error: Error) -> String {
        let rawMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lowercased = rawMessage.lowercased()

        if lowercased.contains("invalid login credentials") {
            return "邮箱或密码不正确"
        }
        if lowercased.contains("already registered") || lowercased.contains("already been registered") {
            return "这个邮箱已经注册过了，请直接登录"
        }
        if lowercased.contains("email not confirmed") {
            return "请先查收邮件完成确认后再登录"
        }
        if isDuplicateProfileIDError(error) {
            return "这个用户 ID 已被占用"
        }

        return rawMessage
    }

    private func isDuplicateProfileIDError(_ error: Error) -> Bool {
        let rawMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lowercased = rawMessage.lowercased()
        return lowercased.contains("duplicate key") ||
            lowercased.contains("profiles_mindrop_id_key") ||
            lowercased.contains("mindrop_id")
    }

    private func appendChatMessage(_ message: ChatMessage) {
        recordMessageForStats(message)
        var updatedMessages = messages
        updatedMessages.append(message)
        if updatedMessages.count > chatHistoryLimit {
            let overflow = updatedMessages.count - chatHistoryLimit
            updatedMessages.prefix(overflow).forEach { rememberDeletedMessage($0) }
            updatedMessages.removeFirst(overflow)
            hasTrimmedChatHistory = true
        }
        messages = updatedMessages
        persistImmediately()
        scheduleCloudSync(delayMilliseconds: 0)
    }

    private func enforceChatHistoryLimit() {
        guard messages.count > chatHistoryLimit else { return }
        let overflow = messages.count - chatHistoryLimit
        messages.prefix(overflow).forEach { rememberDeletedMessage($0) }
        messages = Array(messages.dropFirst(overflow))
        hasTrimmedChatHistory = true
    }

    @discardableResult
    private func enforceQANoteLimit() -> Bool {
        let qaNotes = notes
            .filter { $0.category == .qa }
            .sorted { $0.createdAt > $1.createdAt }
        guard qaNotes.count > qaNoteLimit else { return false }

        let removedIDs = Set(qaNotes.dropFirst(qaNoteLimit).map(\.id))
        let removedNotes = notes.filter { removedIDs.contains($0.id) }
        removedNotes.forEach { rememberDeletedNote($0) }
        notes.removeAll { removedIDs.contains($0.id) }
        return true
    }

    private func rescheduleFutureReminders() async {
        for note in notes where note.category == .todo && (note.reminderAt ?? .distantPast) > .now {
            if shouldUseLocalReminders {
                await notificationScheduler.scheduleReminder(for: note)
            } else {
                notificationScheduler.cancelReminder(for: note.id)
            }
            if note.reminderNotificationTitle.trimmedNonEmpty == nil ||
                note.reminderNotificationBody.trimmedNonEmpty == nil {
                Task { await prepareReminderNotificationText(for: note.id) }
            }
        }
    }

    private func scheduleReminderAndPrepareText(for note: ThoughtNote, forceRefresh: Bool = false) {
        guard note.category == .todo, (note.reminderAt ?? .distantPast) > .now else { return }
        Task {
            if shouldUseLocalReminders {
                await notificationScheduler.scheduleReminder(for: note)
            } else {
                notificationScheduler.cancelReminder(for: note.id)
            }
            await prepareReminderNotificationText(for: note.id, forceRefresh: forceRefresh)
        }
    }

    private var shouldUseLocalReminders: Bool {
        session != .authenticated || PushNotificationService.shared.deviceToken == nil
    }

    private func cancelFutureLocalReminders() {
        for note in notes where note.category == .todo && (note.reminderAt ?? .distantPast) > .now {
            notificationScheduler.cancelReminder(for: note.id)
        }
    }

    private func prepareReminderNotificationText(for noteID: UUID, forceRefresh: Bool = false) async {
        guard let note = notes.first(where: { $0.id == noteID && $0.category == .todo }),
              let reminderAt = note.reminderAt,
              reminderAt > .now else {
            return
        }

        if !forceRefresh,
           note.reminderNotificationTitle.trimmedNonEmpty != nil,
           note.reminderNotificationBody.trimmedNonEmpty != nil {
            return
        }

        do {
            let title = note.title
            let content = note.content
            let notificationText = try await aiService.generateReminderNotification(for: note)
            guard let index = notes.firstIndex(where: { $0.id == noteID && $0.category == .todo }),
                  notes[index].reminderAt == reminderAt,
                  notes[index].title == title,
                  notes[index].content == content else {
                return
            }
            notes[index].reminderNotificationTitle = notificationText.title
            notes[index].reminderNotificationBody = notificationText.body
            notes[index].updatedAt = .now
            notes[index].deletedAt = nil
            if shouldUseLocalReminders {
                await notificationScheduler.scheduleReminder(for: notes[index])
            } else {
                notificationScheduler.cancelReminder(for: notes[index].id)
            }
        } catch {
            print("Mindrop reminder notification generation failed: \(error)")
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toast == message {
                toast = nil
            }
        }
    }

    private func beginAIThinking() {
        pendingAIRequestCount += 1
        isAIThinking = pendingAIRequestCount > 0
    }

    private func endAIThinking() {
        pendingAIRequestCount = max(0, pendingAIRequestCount - 1)
        isAIThinking = pendingAIRequestCount > 0
    }

    private func recentAIContext() -> [ChatMessage] {
        Array(messages.suffix(10))
    }

    private func reminderCandidates() -> [ThoughtNote] {
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

    private func qaCandidates(for context: [ChatMessage]) -> [ThoughtNote] {
        guard let noteID = previousQANoteID(in: context),
              let previousQANote = notes.first(where: { $0.id == noteID && $0.category == .qa }) else {
            return []
        }

        return [previousQANote]
    }

    private func previousQANoteID(in context: [ChatMessage]) -> UUID? {
        guard let previousMessage = context.last,
              previousMessage.role == .assistant,
              previousMessage.category == .qa else {
            return nil
        }
        return previousMessage.noteID
    }

    private func classify(_ text: String) -> ThoughtCategory {
        let qaWords = ["谁", "怎么", "如何", "为什么", "方案", "?", "？"]
        let todoWords = ["提醒", "需要", "记得", "明天", "下午", "开会", "买"]
        let billWords = ["花了", "元", "块", "借给", "收入", "支出", "买衣服"]

        if qaWords.contains(where: text.contains) { return .qa }
        if billWords.contains(where: text.contains), text.containsNumber { return .bill }
        if todoWords.contains(where: text.contains) { return .todo }
        return .idea
    }

    private func localAnalysis(for text: String) -> AIAnalysisResult {
        let category = classify(text)
        let note = makeNote(from: text, category: category)
        let reply: String
        switch category {
        case .qa:
            reply = "我先给你一个可执行答案，并可以把这次问答保存至灵感沉淀。"
        case .todo:
            reply = "已总结并收纳至“待办提醒”板块"
        case .bill:
            reply = "已识别金额与账目类型，并收纳至“账单记录”板块"
        case .idea:
            reply = "已总结并收纳至“灵感沉淀”板块"
        case .recycleBin:
            reply = "已收纳"
        }

        return AIAnalysisResult(
            action: .createNote,
            targetNoteID: nil,
            category: category,
            reply: reply,
            title: note.title,
            content: note.content,
            reminderAt: note.reminderAt,
            expenseAmount: note.expenseAmount,
            expenseCategory: note.expenseCategory
        )
    }

    private func fallbackResult(after error: Error, fallback: AIAnalysisResult) -> AIAnalysisResult {
        return AIAnalysisResult(
            action: .createNote,
            targetNoteID: nil,
            category: .todo,
            reply: "小落暂时连接不上服务，先帮你把它放到待办里记录下啦~",
            title: fallback.title,
            content: fallback.content,
            reminderAt: nil,
            expenseAmount: nil,
            expenseCategory: nil
        )
    }

    private func makeNote(from result: AIAnalysisResult) -> ThoughtNote {
        ThoughtNote(
            title: String(result.title.prefix(10)),
            content: result.content,
            category: result.category,
            reminderAt: result.category == .todo ? result.reminderAt : nil,
            expenseAmount: result.category == .bill ? result.expenseAmount : nil,
            expenseCategory: result.category == .bill ? (result.expenseCategory ?? .other) : nil
        )
    }

    private func makeNote(from text: String, category: ThoughtCategory) -> ThoughtNote {
        switch category {
        case .todo:
            return ThoughtNote(
                title: title(from: text, fallback: "待办提醒"),
                content: summarize(text),
                category: .todo,
                reminderAt: text.contains("三点") ? Calendar.current.date(byAdding: .day, value: 1, to: Date.at(hour: 15)) : nil
            )
        case .bill:
            let expenseCategory = localExpenseCategory(for: text)
            let categoryLabel = expenseCategory.rawValue
            return ThoughtNote(
                title: billTitle(from: text, categoryLabel: categoryLabel),
                content: billContent(from: text, categoryLabel: categoryLabel),
                category: .bill,
                expenseAmount: Decimal(text.firstNumber ?? 0),
                expenseCategory: expenseCategory
            )
        case .qa:
            return ThoughtNote(title: title(from: text, fallback: "知识问答"), content: text, category: .qa)
        case .idea:
            return ThoughtNote(title: title(from: text, fallback: "灵感沉淀"), content: summarize(text), category: .idea)
        case .recycleBin:
            return ThoughtNote(title: title(from: text, fallback: "念头"), content: text, category: .recycleBin)
        }
    }

    private func title(from text: String, fallback: String) -> String {
        let trimmed = text.replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: "。", with: " ")
            .replacingOccurrences(of: "？", with: " ")
            .split(separator: " ")
            .first
            .map(String.init) ?? fallback
        return String(trimmed.prefix(10))
    }

    private func summarize(_ text: String) -> String {
        text.count > 44 ? String(text.prefix(44)) + "..." : text
    }

    private func localExpenseCategory(for text: String) -> ExpenseCategory {
        if ["饭", "餐", "咖啡", "奶茶", "吃", "喝", "外卖"].contains(where: text.contains) { return .food }
        if ["地铁", "打车", "公交", "车票", "机票", "高铁", "加油"].contains(where: text.contains) { return .transit }
        if ["衣服", "鞋", "包", "买"].contains(where: text.contains) { return .shopping }
        if ["电影", "游戏", "演唱会", "娱乐"].contains(where: text.contains) { return .entertainment }
        if ["药", "医院", "课程", "学习", "书"].contains(where: text.contains) { return .education }
        if ["房租", "水电", "物业", "家", "厨房"].contains(where: text.contains) { return .home }
        if ["红包", "礼物", "请客", "借给"].contains(where: text.contains) { return .relationship }
        return .other
    }

    private func billContent(from text: String, categoryLabel: String) -> String {
        "\(categoryLabel)分类，\(summarize(text))"
    }

    private func billTitle(from text: String, categoryLabel: String) -> String {
        var subject = text
        let patterns = [
            #"\d+(\.\d+)?\s*(元|块|人民币|¥)?"#,
            #"今天|昨天|刚刚|刚才|这次|本次|我|给|了|一下|一笔|总共|共|大概|大约|早上|上午|中午|下午|晚上"#,
            #"花费|花了|花|消费|支出|支付|付了|付款|买了|购买|买|用了|花掉|开销|花销|记录|帮我记|记一笔|记账"#,
            #"^(餐饮|交通|购物|娱乐|医教|居家|人情|其他)(分类|支出)?"#,
            #"[，,。.！!？?\s：:；;、]+"#
        ]

        for pattern in patterns {
            subject = subject.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? categoryLabel : trimmed
        return "\(String(fallback.prefix(8)))支出"
    }

    private func seed() {
        notes = []
        messages = []
    }

    private static let builtInSampleNotes: [ThoughtNote] = {
        let now = Date()
        return [
            ThoughtNote(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000101") ?? UUID(),
                title: "买垃圾桶",
                content: "给家里买一个带盖垃圾桶，优先看厨房尺寸。",
                category: .todo,
                createdAt: now.addingTimeInterval(-60)
            ),
            ThoughtNote(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000102") ?? UUID(),
                title: "会议提醒",
                content: "开会前准备周报数据。",
                category: .todo,
                createdAt: now.addingTimeInterval(-120)
            ),
            ThoughtNote(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000103") ?? UUID(),
                title: "水支出",
                content: "餐饮分类，买了一瓶水花了 1 块钱。",
                category: .bill,
                createdAt: now.addingTimeInterval(-180),
                expenseAmount: 1,
                expenseCategory: .food
            ),
            ThoughtNote(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000104") ?? UUID(),
                title: "语音记录 App",
                content: "面向碎片念头的语音收件箱，自动总结并归档。",
                category: .idea,
                createdAt: now.addingTimeInterval(-240),
                isPinned: true
            ),
            ThoughtNote(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000105") ?? UUID(),
                title: "iPhone 截长图",
                content: "在 Safari 截图后切换到整页，并保存为 PDF。",
                category: .qa,
                createdAt: now.addingTimeInterval(-300)
            ),
            ThoughtNote(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000106") ?? UUID(),
                title: "旧会议提醒",
                content: "已超过提醒时间 24 小时，自动进入回收站。",
                category: .recycleBin,
                createdAt: now.addingTimeInterval(-360),
                recycledAt: now.addingTimeInterval(-180),
                categoryBeforeRecycle: .todo
            )
        ]
    }()

    private static let builtInSampleNoteIDs = Set(builtInSampleNotes.map(\.id))

    private static let builtInSampleMessages: [ChatMessage] = {
        let now = Date()
        return [
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000201") ?? UUID(),
                role: .user,
                text: "明天下午三点提醒我开会，并准备周报数据",
                category: nil,
                createdAt: now.addingTimeInterval(-240)
            ),
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000202") ?? UUID(),
                role: .assistant,
                text: "已总结并收纳至“待办提醒”板块",
                category: .todo,
                createdAt: now.addingTimeInterval(-230)
            ),
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000203") ?? UUID(),
                role: .user,
                text: "iPhone 怎么截长图？",
                category: nil,
                createdAt: now.addingTimeInterval(-120)
            ),
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000204") ?? UUID(),
                role: .assistant,
                text: "可以在 Safari 或支持滚动截图的页面截图后，切换到“整页”并保存为 PDF。",
                category: .qa,
                createdAt: now.addingTimeInterval(-110)
            )
        ]
    }()

    private static let builtInSampleDisplayMessageIDs = Set(builtInSampleMessages.map(\.id))

    @discardableResult
    private func migrateDefaultMeetingSampleReminder() -> Bool {
        var didMigrate = false

        for index in notes.indices where notes[index].title == "会议提醒" && notes[index].content == "开会前准备周报数据。" {
            notificationScheduler.cancelReminder(for: notes[index].id)
            if notes[index].reminderAt != nil ||
                notes[index].reminderNotificationTitle != nil ||
                notes[index].reminderNotificationBody != nil {
                notes[index].reminderAt = nil
                notes[index].reminderNotificationTitle = nil
                notes[index].reminderNotificationBody = nil
                notes[index].updatedAt = .now
                didMigrate = true
            }
        }

        return didMigrate
    }

    private static func isBuiltInSampleNote(_ note: ThoughtNote) -> Bool {
        switch (note.title, note.content, note.category) {
        case ("买垃圾桶", "给家里买一个带盖垃圾桶，优先看厨房尺寸。", .todo),
             ("会议提醒", "开会前准备周报数据。", .todo),
             ("水支出", "餐饮分类，买了一瓶水花了 1 块钱。", .bill),
             ("语音记录 App", "面向碎片念头的语音收件箱，自动总结并归档。", .idea),
             ("iPhone 截长图", "在 Safari 截图后切换到整页，并保存为 PDF。", .qa),
             ("旧会议提醒", "已超过提醒时间 48 小时，自动进入回收站。", .recycleBin),
             ("旧会议提醒", "已超过提醒时间 24 小时，自动进入回收站。", .recycleBin):
            return true
        default:
            return false
        }
    }

    private static func builtInSampleMessageIDs(in messages: [ChatMessage]) -> Set<UUID> {
        // Only remove the seeded onboarding chat when the whole template appears together.
        let candidates = messages
            .filter { $0.deletedAt == nil }
            .compactMap { message -> (message: ChatMessage, templateIndex: Int)? in
                guard let templateIndex = builtInSampleMessageTemplateIndex(for: message) else { return nil }
                return (message, templateIndex)
            }
            .sorted { lhs, rhs in
                if lhs.message.createdAt != rhs.message.createdAt {
                    return lhs.message.createdAt < rhs.message.createdAt
                }
                return lhs.templateIndex < rhs.templateIndex
            }

        for startIndex in candidates.indices where candidates[startIndex].templateIndex == 0 {
            let start = candidates[startIndex]
            var selected: [Int: ChatMessage] = [0: start.message]

            for candidate in candidates.dropFirst(startIndex + 1) {
                guard candidate.message.createdAt.timeIntervalSince(start.message.createdAt) <= 10 else { break }
                guard candidate.templateIndex == selected.count else { continue }

                selected[candidate.templateIndex] = candidate.message
                if selected.count == builtInSampleMessageTemplateCount {
                    return Set(selected.values.map(\.id))
                }
            }
        }

        return []
    }

    private static var builtInSampleMessageTemplateCount: Int { 4 }

    private static func builtInSampleMessageTemplateIndex(for message: ChatMessage) -> Int? {
        switch (message.role, message.text, message.category) {
        case (.user, "明天下午三点提醒我开会，并准备周报数据", nil):
            return 0
        case (.assistant, "已总结并收纳至“待办提醒”板块", .todo):
            return 1
        case (.user, "iPhone 怎么截长图？", nil):
            return 2
        case (.assistant, "可以在 Safari 或支持滚动截图的页面截图后，切换到“整页”并保存为 PDF。", .qa):
            return 3
        default:
            return nil
        }
    }

    private static func deletedBuiltInSampleNote(_ note: ThoughtNote, deletedAt: Date) -> ThoughtNote {
        var tombstone = note
        tombstone.reminderAt = nil
        tombstone.reminderNotificationTitle = nil
        tombstone.reminderNotificationBody = nil
        tombstone.deletedAt = deletedAt
        tombstone.updatedAt = deletedAt
        return tombstone
    }

    private static func deletedBuiltInSampleMessage(_ message: ChatMessage, deletedAt: Date) -> ChatMessage {
        var tombstone = message
        tombstone.deletedAt = deletedAt
        tombstone.updatedAt = deletedAt
        return tombstone
    }
}

private enum FeishuConfigurationField {
    case appID
    case appSecret
    case verificationToken
    case encryptKey

    var displayName: String {
        switch self {
        case .appID: return "App ID"
        case .appSecret: return "App Secret"
        case .verificationToken: return "Verification Token"
        case .encryptKey: return "Encrypt Key"
        }
    }
}

private struct FeishuConfigurationDraft {
    var appID = ""
    var appSecret = ""
    var verificationToken = ""
    var encryptKey = ""

    var currentField: FeishuConfigurationField? {
        if appID.isEmpty { return .appID }
        if appSecret.isEmpty { return .appSecret }
        if verificationToken.isEmpty { return .verificationToken }
        if encryptKey.isEmpty { return .encryptKey }
        return nil
    }

    var hasAnyValue: Bool {
        !appID.isEmpty || !appSecret.isEmpty || !verificationToken.isEmpty || !encryptKey.isEmpty
    }

    var credentials: FeishuBotCredentials? {
        guard !appID.isEmpty, !appSecret.isEmpty, !verificationToken.isEmpty, !encryptKey.isEmpty else {
            return nil
        }
        return FeishuBotCredentials(
            appID: appID,
            appSecret: appSecret,
            verificationToken: verificationToken,
            encryptKey: encryptKey
        )
    }

    var missingFields: [String] {
        var fields: [String] = []
        if appID.isEmpty { fields.append("App ID") }
        if appSecret.isEmpty { fields.append("App Secret") }
        if verificationToken.isEmpty { fields.append("Verification Token") }
        if encryptKey.isEmpty { fields.append("Encrypt Key") }
        return fields
    }

    func value(for field: FeishuConfigurationField) -> String? {
        switch field {
        case .appID: return appID
        case .appSecret: return appSecret
        case .verificationToken: return verificationToken
        case .encryptKey: return encryptKey
        }
    }

    mutating func set(_ value: String, for field: FeishuConfigurationField) {
        switch field {
        case .appID:
            appID = value
        case .appSecret:
            appSecret = value
        case .verificationToken:
            verificationToken = value
        case .encryptKey:
            encryptKey = value
        }
    }

    mutating func merge(_ other: FeishuConfigurationDraft) {
        if !other.appID.isEmpty { appID = other.appID }
        if !other.appSecret.isEmpty { appSecret = other.appSecret }
        if !other.verificationToken.isEmpty { verificationToken = other.verificationToken }
        if !other.encryptKey.isEmpty { encryptKey = other.encryptKey }
    }
}

private extension ThoughtNote {
    var syncTimestamp: Date {
        deletedAt ?? updatedAt
    }

    func isNewerSyncRecord(than other: ThoughtNote) -> Bool {
        if syncTimestamp != other.syncTimestamp {
            return syncTimestamp > other.syncTimestamp
        }
        if deletedAt != nil, other.deletedAt == nil { return true }
        if deletedAt == nil, other.deletedAt != nil { return false }
        return createdAt > other.createdAt
    }
}

private extension ChatMessage {
    var syncTimestamp: Date {
        deletedAt ?? updatedAt
    }

    func isNewerSyncRecord(than other: ChatMessage) -> Bool {
        if syncTimestamp != other.syncTimestamp {
            return syncTimestamp > other.syncTimestamp
        }
        if deletedAt != nil, other.deletedAt == nil { return true }
        if deletedAt == nil, other.deletedAt != nil { return false }
        return createdAt > other.createdAt
    }
}

private extension String {
    var isValidPhoneOrEmail: Bool {
        let phone = range(of: #"^\d{11}$"#, options: .regularExpression) != nil
        return phone || isValidEmail
    }

    var isValidEmail: Bool {
        range(of: #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    var isValidPassword: Bool {
        count >= 8 &&
        range(of: #"[A-Za-z]"#, options: .regularExpression) != nil &&
        range(of: #"\d"#, options: .regularExpression) != nil
    }

    var containsNumber: Bool {
        range(of: #"\d+"#, options: .regularExpression) != nil
    }

    var firstNumber: Double? {
        guard let range = range(of: #"\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(self[range])
    }

    var isValidMindropID: Bool {
        range(of: #"^[A-Za-z0-9]{3,20}$"#, options: .regularExpression) != nil
    }
}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? {
        guard let value = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Date {
    static func at(hour: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.hour = hour
        components.minute = 0
        return Calendar.current.date(from: components) ?? .now
    }

    static func yesterdayAt(hour: Int) -> Date {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        var components = Calendar.current.dateComponents([.year, .month, .day], from: yesterday)
        components.hour = hour
        components.minute = 0
        return Calendar.current.date(from: components) ?? yesterday
    }
}
