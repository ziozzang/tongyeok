import Foundation

/// Crash safety: the live session is mirrored to Application Support while it changes.
/// A normal quit deletes the file (after saving the transcript as Markdown), so a file found at
/// launch means the app did not exit cleanly -> offer to restore it.
struct SavedSession: Codable {
    var savedAt: Date
    var sessionStamp: String?
    var sessionStart: Date?
    var sourceCode: String
    var targetCode: String
    var segments: [Segment]
}

enum SessionStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tongyeok/session.json")
    }

    static func load() -> SavedSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(SavedSession.self, from: data)
    }

    static func save(_ s: SavedSession) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(s) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}
