import Foundation

struct MindropQuickThoughtProcessingResult: Equatable {
    var input: String
    var reply: String
    var category: ThoughtCategory?
    var noteID: UUID?
    var didUseFallback: Bool
}

struct MindropQuickThoughtProcessor {
    private let aiService = AIService()
    private let chatHistoryLimit = 100
    private let qaNoteLimit = 100

    func apply(
        transcript rawText: String,
        result: AIAnalysisResult,
        didUseFallback: Bool = false
    ) -> MindropQuickThoughtProcessingResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return MindropQuickThoughtProcessingResult(
                input: rawText,
                reply: "我还没听清，可以再说一次。",
                category: nil,
                noteID: nil,
                didUseFallback: true
            )
        }

        var snapshot = Self.currentSnapshot()
        Self.appendMessage(ChatMessage(role: .user, text: text, category: nil), to: &snapshot, limit: chatHistoryLimit)
        let applied = Self.apply(result, to: &snapshot, qaNoteLimit: qaNoteLimit)
        snapshot.hasPendingCloudChanges = true
        PersistenceStore.saveAndFlush(snapshot)
        NotificationCenter.default.post(name: .mindropQuickCaptureDidSave, object: nil)

        return MindropQuickThoughtProcessingResult(
            input: text,
            reply: applied.reply,
            category: applied.category,
            noteID: applied.noteID,
            didUseFallback: didUseFallback
        )
    }

    func process(transcript rawText: String) async -> MindropQuickThoughtProcessingResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return MindropQuickThoughtProcessingResult(
                input: rawText,
                reply: "我还没听清，可以再说一次。",
                category: nil,
                noteID: nil,
                didUseFallback: true
            )
        }

        var snapshot = Self.currentSnapshot()
        let context = Array(snapshot.messages.suffix(10))
        let reminders = Self.reminderCandidates(in: snapshot.notes)
        let qaNotes = Self.qaCandidates(in: snapshot.notes, context: context)
        Self.appendMessage(ChatMessage(role: .user, text: text, category: nil), to: &snapshot, limit: chatHistoryLimit)

        let fallback = Self.localAnalysis(for: text)
        let result: AIAnalysisResult
        let didUseFallback: Bool
        do {
            result = try await aiService.analyze(
                text: text,
                context: context,
                reminderCandidates: reminders,
                qaCandidates: qaNotes,
                thinkingEnabled: false
            )
            didUseFallback = false
        } catch {
            print("Mindrop quick voice AI request failed: \(error)")
            result = Self.fallbackResult(from: fallback)
            didUseFallback = true
        }

        let applied = Self.apply(result, to: &snapshot, qaNoteLimit: qaNoteLimit)
        snapshot.hasPendingCloudChanges = true
        PersistenceStore.saveAndFlush(snapshot)
        NotificationCenter.default.post(name: .mindropQuickCaptureDidSave, object: nil)

        return MindropQuickThoughtProcessingResult(
            input: text,
            reply: applied.reply,
            category: applied.category,
            noteID: applied.noteID,
            didUseFallback: didUseFallback
        )
    }
}

private extension MindropQuickThoughtProcessor {
    static func currentSnapshot() -> AppSnapshot {
        PersistenceStore.load() ?? AppSnapshot(
            session: .offline,
            notes: [],
            messages: [],
            profile: .loggedOut
        )
    }

    static func apply(
        _ result: AIAnalysisResult,
        to snapshot: inout AppSnapshot,
        qaNoteLimit: Int
    ) -> (reply: String, category: ThoughtCategory?, noteID: UUID?) {
        if result.action == .updateReminder {
            if applyReminderUpdate(result, to: &snapshot) {
                appendMessage(
                    ChatMessage(role: .assistant, text: result.reply, category: .todo, noteID: result.targetNoteID),
                    to: &snapshot
                )
                return (result.reply, .todo, result.targetNoteID)
            }

            let reply = "小落没找到要修改的提醒，可以再说具体一点~"
            appendMessage(ChatMessage(role: .assistant, text: reply, category: .todo), to: &snapshot)
            return (reply, .todo, nil)
        }

        if result.action == .deleteReminder {
            if let deletedNote = applyReminderDelete(result, to: &snapshot) {
                appendMessage(
                    ChatMessage(role: .assistant, text: result.reply, category: .todo, noteID: deletedNote.id),
                    to: &snapshot
                )
                return (result.reply, .todo, deletedNote.id)
            }

            let reply = "小落没找到要删除的提醒，可以再说具体一点~"
            appendMessage(ChatMessage(role: .assistant, text: reply, category: .todo), to: &snapshot)
            return (reply, .todo, nil)
        }

        if result.action == .updateQA {
            if applyQAUpdate(result, to: &snapshot) {
                appendMessage(
                    ChatMessage(role: .assistant, text: result.reply, category: .qa, noteID: result.targetNoteID),
                    to: &snapshot
                )
                return (result.reply, .qa, result.targetNoteID)
            }
        }

        let note = makeNote(from: result)
        snapshot.notes.insert(note, at: 0)
        recordNoteForStats(note, in: &snapshot.profileStats)
        enforceQANoteLimit(in: &snapshot, limit: qaNoteLimit)
        appendMessage(
            ChatMessage(role: .assistant, text: result.reply, category: result.category, noteID: note.id),
            to: &snapshot
        )
        return (result.reply, result.category, note.id)
    }

    static func applyReminderUpdate(_ result: AIAnalysisResult, to snapshot: inout AppSnapshot) -> Bool {
        guard result.category == .todo,
              let reminderAt = result.reminderAt,
              let index = targetReminderIndex(for: result, in: snapshot.notes) else {
            return false
        }

        var note = snapshot.notes[index]
        note.title = reminderUpdateText(result.title, fallback: note.title)
        note.content = reminderUpdateText(result.content, fallback: note.content)
        note.reminderAt = reminderAt
        note.reminderNotificationTitle = nil
        note.reminderNotificationBody = nil
        note.expenseAmount = nil
        note.expenseCategory = nil
        note.updatedAt = .now
        note.deletedAt = nil
        snapshot.notes[index] = note
        recordNoteForStats(note, in: &snapshot.profileStats)
        return true
    }

    static func applyReminderDelete(_ result: AIAnalysisResult, to snapshot: inout AppSnapshot) -> ThoughtNote? {
        guard result.category == .todo,
              let index = targetReminderIndex(for: result, in: snapshot.notes) else {
            return nil
        }

        var note = snapshot.notes[index]
        note.categoryBeforeRecycle = .todo
        note.recycledAt = .now
        note.category = .recycleBin
        note.updatedAt = .now
        note.deletedAt = nil
        snapshot.notes[index] = note
        recordNoteForStats(note, in: &snapshot.profileStats)
        return note
    }

    static func applyQAUpdate(_ result: AIAnalysisResult, to snapshot: inout AppSnapshot) -> Bool {
        guard result.category == .qa,
              let targetNoteID = result.targetNoteID,
              let index = snapshot.notes.firstIndex(where: { $0.id == targetNoteID && $0.category == .qa }) else {
            return false
        }

        var note = snapshot.notes[index]
        note.title = qaUpdateText(result.title, fallback: note.title)
        note.content = qaUpdateText(result.content, fallback: note.content)
        note.reminderAt = nil
        note.expenseAmount = nil
        note.expenseCategory = nil
        note.updatedAt = .now
        note.deletedAt = nil
        snapshot.notes[index] = note
        recordNoteForStats(note, in: &snapshot.profileStats)
        enforceQANoteLimit(in: &snapshot, limit: 100)
        return true
    }

    static func targetReminderIndex(for result: AIAnalysisResult, in notes: [ThoughtNote]) -> Int? {
        if let targetNoteID = result.targetNoteID,
           let index = notes.firstIndex(where: { $0.id == targetNoteID && $0.category == .todo }) {
            return index
        }

        let candidates = notes.enumerated().filter { _, note in
            note.category == .todo && note.reminderAt != nil
        }
        return candidates.count == 1 ? candidates[0].offset : nil
    }

    static func appendMessage(_ message: ChatMessage, to snapshot: inout AppSnapshot, limit: Int = 100) {
        recordMessageForStats(message, in: &snapshot.profileStats)
        snapshot.messages.append(message)
        guard snapshot.messages.count > limit else { return }

        let overflow = snapshot.messages.count - limit
        for message in snapshot.messages.prefix(overflow) {
            rememberDeletedMessage(message, in: &snapshot)
        }
        snapshot.messages.removeFirst(overflow)
        snapshot.hasTrimmedChatHistory = true
    }

    static func rememberDeletedMessage(_ message: ChatMessage, in snapshot: inout AppSnapshot) {
        recordMessageForStats(message, in: &snapshot.profileStats)
        var tombstone = message
        let deletedAt = Date()
        tombstone.deletedAt = deletedAt
        tombstone.updatedAt = deletedAt
        snapshot.deletedMessages.append(tombstone)
    }

    static func enforceQANoteLimit(in snapshot: inout AppSnapshot, limit: Int) {
        let qaNotes = snapshot.notes
            .filter { $0.category == .qa }
            .sorted { $0.createdAt > $1.createdAt }
        guard qaNotes.count > limit else { return }

        let removedIDs = Set(qaNotes.dropFirst(limit).map(\.id))
        let removedNotes = snapshot.notes.filter { removedIDs.contains($0.id) }
        for note in removedNotes {
            rememberDeletedNote(note, in: &snapshot)
        }
        snapshot.notes.removeAll { removedIDs.contains($0.id) }
    }

    static func rememberDeletedNote(_ note: ThoughtNote, in snapshot: inout AppSnapshot) {
        recordNoteForStats(note, in: &snapshot.profileStats)
        var tombstone = note
        let deletedAt = Date()
        tombstone.deletedAt = deletedAt
        tombstone.updatedAt = deletedAt
        snapshot.deletedNotes.append(tombstone)
    }

    static func recordNoteForStats(_ note: ThoughtNote, in stats: inout ProfileStats) {
        guard let category = statsCategory(for: note) else { return }
        let record = NoteStatRecord(
            noteID: note.id,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            category: category,
            expenseAmount: category == .bill ? note.expenseAmount : nil,
            expenseCategory: category == .bill ? (note.expenseCategory ?? .other) : nil
        )
        upsertNoteStat(record, into: &stats)
        stats = normalizedProfileStats(stats)
    }

    static func recordMessageForStats(_ message: ChatMessage, in stats: inout ProfileStats) {
        guard message.role == .user else { return }
        let record = MessageStatRecord(
            messageID: message.id,
            createdAt: message.createdAt,
            updatedAt: message.updatedAt
        )
        upsertMessageStat(record, into: &stats)
        stats = normalizedProfileStats(stats)
    }

    static func statsCategory(for note: ThoughtNote) -> ThoughtCategory? {
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

    static func upsertNoteStat(_ record: NoteStatRecord, into stats: inout ProfileStats) {
        if let index = stats.noteRecords.firstIndex(where: { $0.noteID == record.noteID }) {
            if record.updatedAt >= stats.noteRecords[index].updatedAt {
                stats.noteRecords[index] = record
            }
        } else {
            stats.noteRecords.append(record)
        }
    }

    static func upsertMessageStat(_ record: MessageStatRecord, into stats: inout ProfileStats) {
        if let index = stats.messageRecords.firstIndex(where: { $0.messageID == record.messageID }) {
            if record.updatedAt >= stats.messageRecords[index].updatedAt {
                stats.messageRecords[index] = record
            }
        } else {
            stats.messageRecords.append(record)
        }
    }

    static func normalizedProfileStats(_ stats: ProfileStats) -> ProfileStats {
        ProfileStats(
            noteRecords: stats.noteRecords.sorted { $0.createdAt > $1.createdAt },
            messageRecords: stats.messageRecords.sorted { $0.createdAt < $1.createdAt }
        )
    }

    static func reminderCandidates(in notes: [ThoughtNote]) -> [ThoughtNote] {
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

    static func qaCandidates(in notes: [ThoughtNote], context: [ChatMessage]) -> [ThoughtNote] {
        guard let previousMessage = context.last,
              previousMessage.role == .assistant,
              previousMessage.category == .qa,
              let noteID = previousMessage.noteID,
              let previousQANote = notes.first(where: { $0.id == noteID && $0.category == .qa }) else {
            return []
        }
        return [previousQANote]
    }

    static func localAnalysis(for text: String) -> AIAnalysisResult {
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

    static func fallbackResult(from fallback: AIAnalysisResult) -> AIAnalysisResult {
        AIAnalysisResult(
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

    static func makeNote(from result: AIAnalysisResult) -> ThoughtNote {
        ThoughtNote(
            title: String(result.title.prefix(10)),
            content: result.content,
            category: result.category,
            reminderAt: result.category == .todo ? result.reminderAt : nil,
            expenseAmount: result.category == .bill ? result.expenseAmount : nil,
            expenseCategory: result.category == .bill ? (result.expenseCategory ?? .other) : nil
        )
    }

    static func makeNote(from text: String, category: ThoughtCategory) -> ThoughtNote {
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
                content: "\(categoryLabel)分类，\(summarize(text))",
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

    static func classify(_ text: String) -> ThoughtCategory {
        let qaWords = ["谁", "怎么", "如何", "为什么", "方案", "?", "？"]
        let todoWords = ["提醒", "需要", "记得", "明天", "下午", "开会", "买"]
        let billWords = ["花了", "元", "块", "借给", "收入", "支出", "买衣服"]

        if qaWords.contains(where: text.contains) { return .qa }
        if billWords.contains(where: text.contains), text.containsNumber { return .bill }
        if todoWords.contains(where: text.contains) { return .todo }
        return .idea
    }

    static func reminderUpdateText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "待办提醒" else { return fallback }
        return trimmed
    }

    static func qaUpdateText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "知识问答" else { return fallback }
        return trimmed
    }

    static func title(from text: String, fallback: String) -> String {
        let trimmed = text.replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: "。", with: " ")
            .replacingOccurrences(of: "？", with: " ")
            .split(separator: " ")
            .first
            .map(String.init) ?? fallback
        return String(trimmed.prefix(10))
    }

    static func summarize(_ text: String) -> String {
        text.count > 44 ? String(text.prefix(44)) + "..." : text
    }

    static func localExpenseCategory(for text: String) -> ExpenseCategory {
        if ["饭", "餐", "咖啡", "奶茶", "吃", "喝", "外卖"].contains(where: text.contains) { return .food }
        if ["地铁", "打车", "公交", "车票", "机票", "高铁", "加油"].contains(where: text.contains) { return .transit }
        if ["衣服", "鞋", "包", "买"].contains(where: text.contains) { return .shopping }
        if ["电影", "游戏", "演唱会", "娱乐"].contains(where: text.contains) { return .entertainment }
        if ["药", "医院", "课程", "学习", "书"].contains(where: text.contains) { return .education }
        if ["房租", "水电", "物业", "家", "厨房"].contains(where: text.contains) { return .home }
        if ["红包", "礼物", "请客", "借给"].contains(where: text.contains) { return .relationship }
        return .other
    }

    static func billTitle(from text: String, categoryLabel: String) -> String {
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
}

private extension String {
    var containsNumber: Bool {
        range(of: #"\d+"#, options: .regularExpression) != nil
    }

    var firstNumber: Double? {
        guard let range = range(of: #"\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(self[range])
    }
}

private extension Date {
    static func at(hour: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.hour = hour
        components.minute = 0
        return Calendar.current.date(from: components) ?? .now
    }
}
