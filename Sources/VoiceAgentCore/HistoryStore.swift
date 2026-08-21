import Foundation

/// Persists conversation history to a JSON file so context survives restarts.
/// All read/write failures are swallowed and degrade to an empty history —
/// losing a snapshot must never interrupt the conversation.
public final class HistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "voiceagent.history.store")

    public init(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        self.fileURL = URL(fileURLWithPath: expanded)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        return decoded
    }

    public func save(_ history: [ChatMessage]) {
        queue.async { [fileURL] in
            guard let data = try? JSONEncoder().encode(history) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
