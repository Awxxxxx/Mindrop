import Foundation

struct AIAnalysisResult: Equatable {
    var action: AIAnalysisAction
    var targetNoteID: UUID?
    var category: ThoughtCategory
    var reply: String
    var title: String
    var content: String
    var reminderAt: Date?
    var expenseAmount: Decimal?
    var expenseCategory: ExpenseCategory?
}

struct ReminderNotificationText: Equatable {
    var title: String
    var body: String
}

enum AIAnalysisAction: Equatable {
    case createNote
    case updateReminder
    case deleteReminder
    case updateQA
}

final class AIService {
    private static let productionEndpoint = URL(string: "https://www.mindrop.chat/api/mindrop-ai")

    private let endpoint: URL?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    init(
        endpoint: URL? = AIService.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.mindrop.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(value)"
            )
        }
    }

    func analyze(
        text: String,
        context: [ChatMessage] = [],
        reminderCandidates: [ThoughtNote] = [],
        qaCandidates: [ThoughtNote] = [],
        now: Date = .now,
        thinkingEnabled: Bool = false
    ) async throws -> AIAnalysisResult {
        guard let endpoint else { throw AIServiceError.endpointNotConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 28
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            AIAnalyzeRequest(
                text: text,
                context: context.suffix(10).map(AIContextMessage.init),
                reminders: reminderCandidates.prefix(20).map { AIReminderCandidate(note: $0) },
                qaNotes: qaCandidates.prefix(1).map { AINoteCandidate(note: $0) },
                now: ISO8601DateFormatter.mindrop.string(from: now),
                timeZone: TimeZone.current.identifier,
                thinkingEnabled: thinkingEnabled
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIServiceError.serverError(httpResponse.statusCode)
        }

        let payload = try decoder.decode(AIAnalyzeResponse.self, from: data)
        let category = payload.category.thoughtCategory
        let action: AIAnalysisAction
        let normalizedAction = payload.action?.replacingOccurrences(of: "_", with: "").lowercased()
        if normalizedAction == "updatereminder", category == .todo {
            action = .updateReminder
        } else if normalizedAction == "deletereminder", category == .todo {
            action = .deleteReminder
        } else if normalizedAction == "updateqa", category == .qa {
            action = .updateQA
        } else {
            action = .createNote
        }
        return AIAnalysisResult(
            action: action,
            targetNoteID: payload.targetNoteId.flatMap(UUID.init(uuidString:)),
            category: category,
            reply: payload.reply.trimmedNonEmpty ?? payload.category.defaultReply,
            title: payload.note.title.mindropTitlePrefix(fallback: payload.category.thoughtCategory.rawValue),
            content: payload.note.content.trimmedNonEmpty ?? text,
            reminderAt: payload.note.reminderAt,
            expenseAmount: payload.note.expenseAmount,
            expenseCategory: payload.note.expenseCategory?.expenseCategory
        )
    }

    func generateReminderNotification(for note: ThoughtNote, now: Date = .now) async throws -> ReminderNotificationText {
        guard let endpoint else { throw AIServiceError.endpointNotConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            AIReminderNotificationRequest(
                task: "reminderNotification",
                note: AIReminderCandidate(note: note),
                now: ISO8601DateFormatter.mindrop.string(from: now),
                timeZone: TimeZone.current.identifier
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIServiceError.serverError(httpResponse.statusCode)
        }

        let payload = try decoder.decode(AIReminderNotificationResponse.self, from: data)
        return ReminderNotificationText(
            title: payload.title.trimmedPrefix(12, fallback: "待办时间到啦"),
            body: payload.body.trimmedPrefix(36, fallback: String(note.content.prefix(36)))
        )
    }

    private static var defaultEndpoint: URL? {
        if let value = Bundle.main.object(forInfoDictionaryKey: "MindropAIEndpoint") as? String,
           let url = URL.mindropEndpoint(from: value),
           !value.isEmpty {
            return url
        }
        if let value = ProcessInfo.processInfo.environment["MINDROP_AI_ENDPOINT"],
           let url = URL.mindropEndpoint(from: value),
           !value.isEmpty {
            return url
        }
        return productionEndpoint
    }
}

private struct AIAnalyzeRequest: Encodable {
    let text: String
    let context: [AIContextMessage]
    let reminders: [AIReminderCandidate]
    let qaNotes: [AINoteCandidate]
    let now: String
    let timeZone: String
    let thinkingEnabled: Bool
}

private struct AIReminderNotificationRequest: Encodable {
    let task: String
    let note: AIReminderCandidate
    let now: String
    let timeZone: String
}

private struct AIContextMessage: Encodable {
    let role: String
    let text: String
    let category: String?

    init(message: ChatMessage) {
        role = message.role.rawValue
        text = message.text
        category = message.category?.rawValue
    }
}

private struct AIReminderCandidate: Encodable {
    let id: String
    let title: String
    let content: String
    let reminderAt: String
    let createdAt: String

    init(note: ThoughtNote) {
        id = note.id.uuidString
        title = note.title
        content = note.content
        reminderAt = note.reminderAt.map { ISO8601DateFormatter.mindrop.string(from: $0) } ?? ""
        createdAt = ISO8601DateFormatter.mindrop.string(from: note.createdAt)
    }
}

private struct AINoteCandidate: Encodable {
    let id: String
    let title: String
    let content: String
    let createdAt: String

    init(note: ThoughtNote) {
        id = note.id.uuidString
        title = note.title
        content = note.content
        createdAt = ISO8601DateFormatter.mindrop.string(from: note.createdAt)
    }
}

private struct AIAnalyzeResponse: Decodable {
    let action: String?
    let targetNoteId: String?
    let category: AICategory
    let reply: String
    let note: AINote
}

private struct AIReminderNotificationResponse: Decodable {
    let title: String
    let body: String
}

private struct AINote: Decodable {
    let title: String
    let content: String
    let reminderAt: Date?
    let expenseAmount: Decimal?
    let expenseCategory: AIExpenseCategory?
}

private enum AICategory: String, Decodable {
    case todo
    case bill
    case qa
    case idea

    var thoughtCategory: ThoughtCategory {
        switch self {
        case .todo: .todo
        case .bill: .bill
        case .qa: .qa
        case .idea: .idea
        }
    }

    var defaultReply: String {
        switch self {
        case .todo: "已总结并收纳至“待办提醒”板块"
        case .bill: "已识别金额与账目类型，并收纳至“账单记录”板块"
        case .qa: "我先给你一个可执行答案，并可以把这次问答保存至灵感沉淀。"
        case .idea: "已总结并收纳至“灵感沉淀”板块"
        }
    }
}

private enum AIExpenseCategory: String, Decodable {
    case food
    case transit
    case shopping
    case entertainment
    case education
    case home
    case relationship
    case other

    var expenseCategory: ExpenseCategory {
        switch self {
        case .food: .food
        case .transit: .transit
        case .shopping: .shopping
        case .entertainment: .entertainment
        case .education: .education
        case .home: .home
        case .relationship: .relationship
        case .other: .other
        }
    }
}

enum AIServiceError: Error {
    case endpointNotConfigured
    case invalidResponse
    case serverError(Int)
}

private extension ISO8601DateFormatter {
    static let mindrop: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func trimmedPrefix(_ maxLength: Int, fallback: String) -> String {
        guard let value = trimmedNonEmpty else { return fallback }
        return String(value.prefix(maxLength))
    }
}

private extension URL {
    static func mindropEndpoint(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme) else {
            return nil
        }
        return url
    }
}
