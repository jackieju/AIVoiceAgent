import Foundation

public enum AgentDoneReason {
    case endTurn
    case maxRounds
    case cancelled
    case error(Error)
}

public final class AgentLoop {
    private let provider: LLMProvider
    private let registry: ToolRegistry
    private let system: String?
    private let maxRounds: Int

    public init(provider: LLMProvider, registry: ToolRegistry, system: String?, maxRounds: Int = 5) {
        self.provider = provider
        self.registry = registry
        self.system = system
        self.maxRounds = maxRounds
    }

    /// Drives the multi-round tool loop for one user turn.
    /// - onTextDelta: prose only (never tool_use/tool_result) — feeds TTS.
    /// - onToolStart: UI hint that a tool began; must NOT be spoken.
    /// - onAssistantMessage / onToolResultMessage: emitted so the caller can
    ///   persist the full content-block history (required for follow-up requests).
    /// - isCurrent: the generation guard; returning false aborts ASAP.
    public func run(
        history: [ChatMessage],
        isCurrent: @escaping () -> Bool,
        onTextDelta: @escaping (String) -> Void,
        onToolStart: @escaping (_ name: String) -> Void,
        onAssistantMessage: @escaping (ChatMessage) -> Void,
        onToolResultMessage: @escaping (ChatMessage) -> Void,
        onDone: @escaping (AgentDoneReason) -> Void
    ) async {
        var messages = history

        for _ in 0..<maxRounds {
            guard isCurrent() else { onDone(.cancelled); return }

            var textParts: [String] = []
            var pendingToolUses: [(id: String, name: String, input: [String: Any])] = []
            var stopReason: StopReason = .endTurn
            var streamError: Error?

            for await ev in provider.streamEvents(messages: messages, tools: registry.specs, system: system) {
                guard isCurrent() else { onDone(.cancelled); return }
                switch ev {
                case .textDelta(let s):
                    onTextDelta(s)
                    textParts.append(s)
                case .toolUseComplete(let id, let name, let json):
                    pendingToolUses.append((id, name, parseJSONObject(json)))
                case .done(let r):
                    stopReason = r
                case .error(let e):
                    streamError = e
                }
            }

            if let streamError { onDone(.error(streamError)); return }

            var assistantBlocks: [ContentBlock] = []
            let mergedText = textParts.joined()
            if !mergedText.isEmpty { assistantBlocks.append(.text(mergedText)) }
            for tu in pendingToolUses {
                assistantBlocks.append(.toolUse(id: tu.id, name: tu.name, input: tu.input))
            }
            let assistantMsg = ChatMessage(role: .assistant, content: assistantBlocks)
            messages.append(assistantMsg)
            onAssistantMessage(assistantMsg)

            if stopReason != .toolUse || pendingToolUses.isEmpty {
                onDone(.endTurn); return
            }

            for tu in pendingToolUses { onToolStart(tu.name) }

            let results = await executeTools(pendingToolUses, isCurrent: isCurrent)
            guard isCurrent() else { onDone(.cancelled); return }

            let toolResultMsg = ChatMessage(role: .user, content: results)
            messages.append(toolResultMsg)
            onToolResultMessage(toolResultMsg)
        }

        onDone(.maxRounds)
    }

    private func executeTools(
        _ toolUses: [(id: String, name: String, input: [String: Any])],
        isCurrent: @escaping () -> Bool
    ) async -> [ContentBlock] {
        await withTaskGroup(of: (Int, ContentBlock).self) { group in
            for (i, tu) in toolUses.enumerated() {
                let registry = self.registry
                group.addTask {
                    let out = await registry.execute(name: tu.name, input: tu.input, isCancelled: { !isCurrent() })
                    return (i, .toolResult(toolUseId: tu.id, content: out.content, isError: out.isError, imageBase64: out.imageBase64))
                }
            }
            var collected: [(Int, ContentBlock)] = []
            for await pair in group { collected.append(pair) }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}

func parseJSONObject(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return obj
}
