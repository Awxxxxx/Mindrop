import Foundation

struct MindropQuickVoiceDiagnosticEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let source: String
    let message: String

    init(id: UUID = UUID(), timestamp: Date = .now, source: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.message = message
    }
}

enum MindropQuickVoiceDiagnostics {
    private static let key = "mindrop.quickVoiceDiagnostics.entries"
    private static let maxEntries = 120

    static func append(_ message: String, source: String = Bundle.main.bundleIdentifier ?? "unknown") {
        var currentEntries = entries()
        currentEntries.append(MindropQuickVoiceDiagnosticEntry(source: source, message: message))
        if currentEntries.count > maxEntries {
            currentEntries.removeFirst(currentEntries.count - maxEntries)
        }
        save(currentEntries)
    }

    static func entries() -> [MindropQuickVoiceDiagnosticEntry] {
        guard let data = MindropSharedStorage.defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([MindropQuickVoiceDiagnosticEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func clear() {
        MindropSharedStorage.set(nil, forKey: key)
        MindropSharedStorage.synchronize()
    }

    private static func save(_ entries: [MindropQuickVoiceDiagnosticEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        MindropSharedStorage.set(data, forKey: key)
        MindropSharedStorage.synchronize()
    }
}
