import Foundation
import SwiftUI

enum SessionState: String, Codable, Equatable {
    case welcome
    case authenticated
    case offline
}

enum AppTab: String, CaseIterable, Codable {
    case history = "历史"
    case input = "念落"
    case profile = "我的"
}

enum ThoughtCategory: String, CaseIterable, Codable, Identifiable {
    case todo = "待办提醒"
    case bill = "账单记录"
    case qa = "知识问答"
    case idea = "灵感沉淀"
    case recycleBin = "回收站"

    var id: String { rawValue }

    var noteColor: Color {
        switch self {
        case .todo: Color(red: 0.90, green: 0.73, blue: 0.34)
        case .bill: Color(red: 0.84, green: 0.54, blue: 0.61)
        case .qa: Color(red: 0.45, green: 0.66, blue: 0.63)
        case .idea: Color(red: 0.48, green: 0.65, blue: 0.84)
        case .recycleBin: Color(red: 0.67, green: 0.70, blue: 0.73)
        }
    }
}

enum ExpenseCategory: String, CaseIterable, Codable, Identifiable {
    case food = "餐饮"
    case transit = "交通"
    case shopping = "购物"
    case entertainment = "娱乐"
    case education = "医教"
    case home = "居家"
    case relationship = "人情"
    case other = "其他"

    var id: String { rawValue }
}

struct ThoughtNote: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var category: ThoughtCategory
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var reminderAt: Date?
    var reminderNotificationTitle: String?
    var reminderNotificationBody: String?
    var expenseAmount: Decimal?
    var expenseCategory: ExpenseCategory?
    var isPinned: Bool
    var recycledAt: Date?
    var categoryBeforeRecycle: ThoughtCategory?

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        category: ThoughtCategory,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        reminderAt: Date? = nil,
        reminderNotificationTitle: String? = nil,
        reminderNotificationBody: String? = nil,
        expenseAmount: Decimal? = nil,
        expenseCategory: ExpenseCategory? = nil,
        isPinned: Bool = false,
        recycledAt: Date? = nil,
        categoryBeforeRecycle: ThoughtCategory? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
        self.reminderAt = reminderAt
        self.reminderNotificationTitle = reminderNotificationTitle
        self.reminderNotificationBody = reminderNotificationBody
        self.expenseAmount = expenseAmount
        self.expenseCategory = expenseCategory
        self.isPinned = isPinned
        self.recycledAt = recycledAt
        self.categoryBeforeRecycle = categoryBeforeRecycle
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case category
        case createdAt
        case updatedAt
        case deletedAt
        case reminderAt
        case reminderNotificationTitle
        case reminderNotificationBody
        case expenseAmount
        case expenseCategory
        case isPinned
        case recycledAt
        case categoryBeforeRecycle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        category = try container.decode(ThoughtCategory.self, forKey: .category)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        reminderAt = try container.decodeIfPresent(Date.self, forKey: .reminderAt)
        reminderNotificationTitle = try container.decodeIfPresent(String.self, forKey: .reminderNotificationTitle)
        reminderNotificationBody = try container.decodeIfPresent(String.self, forKey: .reminderNotificationBody)
        expenseAmount = try container.decodeIfPresent(Decimal.self, forKey: .expenseAmount)
        expenseCategory = try container.decodeIfPresent(ExpenseCategory.self, forKey: .expenseCategory)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        recycledAt = try container.decodeIfPresent(Date.self, forKey: .recycledAt)
        categoryBeforeRecycle = try container.decodeIfPresent(ThoughtCategory.self, forKey: .categoryBeforeRecycle)
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    var role: Role
    var text: String
    var category: ThoughtCategory?
    var noteID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        category: ThoughtCategory?,
        noteID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.category = category
        self.noteID = noteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case category
        case noteID
        case createdAt
        case updatedAt
        case deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        category = try container.decodeIfPresent(ThoughtCategory.self, forKey: .category)
        noteID = try container.decodeIfPresent(UUID.self, forKey: .noteID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

struct ProfileStats: Codable, Equatable {
    static let empty = ProfileStats()

    var noteRecords: [NoteStatRecord]
    var messageRecords: [MessageStatRecord]

    init(
        noteRecords: [NoteStatRecord] = [],
        messageRecords: [MessageStatRecord] = []
    ) {
        self.noteRecords = noteRecords
        self.messageRecords = messageRecords
    }
}

struct NoteStatRecord: Identifiable, Codable, Equatable {
    let noteID: UUID
    var createdAt: Date
    var updatedAt: Date
    var category: ThoughtCategory
    var expenseAmount: Decimal?
    var expenseCategory: ExpenseCategory?

    var id: UUID { noteID }

    init(
        noteID: UUID,
        createdAt: Date,
        updatedAt: Date,
        category: ThoughtCategory,
        expenseAmount: Decimal? = nil,
        expenseCategory: ExpenseCategory? = nil
    ) {
        self.noteID = noteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.category = category
        self.expenseAmount = expenseAmount
        self.expenseCategory = expenseCategory
    }
}

struct MessageStatRecord: Identifiable, Codable, Equatable {
    let messageID: UUID
    var createdAt: Date
    var updatedAt: Date

    var id: UUID { messageID }

    init(messageID: UUID, createdAt: Date, updatedAt: Date) {
        self.messageID = messageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct UserProfile: Codable, Equatable {
    static let defaultAvatarName = "DefaultAvatar"
    static let loggedOut = UserProfile(nickname: "小念", userID: "mindrop01", avatarName: UserProfile.defaultAvatarName)

    var nickname: String
    var userID: String
    var avatarName: String
    var avatarURL: String? = nil
    var avatarDataBase64: String? = nil
}

extension String {
    func mindropTitlePrefix(fallback: String, maxWidth: Int = 24) -> String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return fallback }

        var width = 0
        var result = ""
        for character in value {
            let characterWidth = character.isMindropHalfWidth ? 1 : 2
            guard width + characterWidth <= maxWidth else { break }
            result.append(character)
            width += characterWidth
        }
        return result.isEmpty ? fallback : result
    }
}

private extension Character {
    var isMindropHalfWidth: Bool {
        unicodeScalars.allSatisfy { $0.value <= 0x7F }
    }
}

enum TimeRange: String, CaseIterable, Codable, Identifiable {
    case seven = "7天"
    case ninety = "90天"
    case year = "365天"

    var id: String { rawValue }

    var dayCount: Int {
        switch self {
        case .seven:
            7
        case .ninety:
            90
        case .year:
            365
        }
    }
}
