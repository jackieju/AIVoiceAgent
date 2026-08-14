import Foundation

public struct ChatMessage {
    public enum Role: String { case user, assistant }
    public let role: Role
    public let content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public init(role: Role, text: String) {
        self.role = role
        self.content = [.text(text)]
    }

    /// Concatenated text blocks only; tool_use / tool_result blocks are ignored.
    /// Legacy call sites that treated a message as plain prose keep working.
    public var text: String {
        content.compactMap {
            if case .text(let s) = $0 { return s }
            return nil
        }.joined()
    }
}

public enum StopReason {
    case endTurn
    case toolUse
    case maxTokens
    case error
}

public enum StreamEvent {
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case done(StopReason)
    case error(Error)
}

public protocol LLMProvider {
    func streamEvents(
        messages: [ChatMessage],
        tools: [ToolSpec],
        system: String?
    ) -> AsyncStream<StreamEvent>
}

extension LLMProvider {
    /// Legacy prose-only shim so callers written against the old 3-callback API
    /// keep working while the AgentLoop migration lands. Drops tool events.
    public func stream(
        messages: [ChatMessage],
        onDelta: @escaping (String) -> Void,
        onDone: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        Task {
            for await ev in streamEvents(messages: messages, tools: [], system: nil) {
                switch ev {
                case .textDelta(let s): onDelta(s)
                case .done: onDone()
                case .error(let e): onError(e)
                case .toolUseComplete: break
                }
            }
        }
    }
}

public enum LLMError: Error, CustomStringConvertible {
    case badURL(String)
    case http(Int, String)

    public var description: String {
        switch self {
        case .badURL(let u): return "bad URL: \(u)"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}

public final class AnthropicProvider: LLMProvider {
    private let apiKey: String
    private let model: String
    private let baseURL: String
    private let systemPrompt: String?
    private let maxTokens: Int

    public init(apiKey: String, model: String, baseURL: String = "https://api.anthropic.com", systemPrompt: String? = nil, maxTokens: Int = 4096) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
    }

    public func streamEvents(messages: [ChatMessage], tools: [ToolSpec], system: String?) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            guard let url = URL(string: baseURL + "/v1/messages") else {
                continuation.yield(.error(LLMError.badURL(baseURL + "/v1/messages")))
                continuation.finish()
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            var body: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "stream": true,
                "messages": messages.map { Self.encodeMessage($0) },
            ]
            let sys = system ?? systemPrompt
            if let sys { body["system"] = sys }
            if !tools.isEmpty {
                body["tools"] = tools.map { spec in
                    ["name": spec.name, "description": spec.description, "input_schema": spec.inputSchema]
                }
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line }
                        continuation.yield(.error(LLMError.http(http.statusCode, errBody)))
                        continuation.finish()
                        return
                    }
                    var toolByIndex: [Int: (id: String, name: String)] = [:]
                    var jsonByIndex: [Int: String] = [:]
                    var stopReason: StopReason = .endTurn
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        switch type {
                        case "content_block_start":
                            let index = obj["index"] as? Int ?? 0
                            if let block = obj["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use",
                               let id = block["id"] as? String,
                               let name = block["name"] as? String {
                                toolByIndex[index] = (id, name)
                                jsonByIndex[index] = ""
                            }
                        case "content_block_delta":
                            let index = obj["index"] as? Int ?? 0
                            guard let delta = obj["delta"] as? [String: Any] else { break }
                            if let text = delta["text"] as? String {
                                continuation.yield(.textDelta(text))
                            } else if let partial = delta["partial_json"] as? String {
                                jsonByIndex[index, default: ""] += partial
                            }
                        case "content_block_stop":
                            let index = obj["index"] as? Int ?? 0
                            if let tool = toolByIndex[index] {
                                continuation.yield(.toolUseComplete(id: tool.id, name: tool.name, inputJSON: jsonByIndex[index] ?? "{}"))
                            }
                        case "message_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               let reason = delta["stop_reason"] as? String, reason == "tool_use" {
                                stopReason = .toolUse
                            }
                        case "message_stop":
                            continuation.yield(.done(stopReason))
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.yield(.done(stopReason))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func encodeMessage(_ m: ChatMessage) -> [String: Any] {
        let blocks: [[String: Any]] = m.content.map { block in
            switch block {
            case .text(let s):
                return ["type": "text", "text": s]
            case .toolUse(let id, let name, let input):
                return ["type": "tool_use", "id": id, "name": name, "input": input]
            case .toolResult(let toolUseId, let content, let isError):
                return ["type": "tool_result", "tool_use_id": toolUseId, "content": content, "is_error": isError]
            }
        }
        return ["role": m.role.rawValue, "content": blocks]
    }
}

public final class OpenAICompatibleProvider: LLMProvider {
    private let apiKey: String
    private let model: String
    private let baseURL: String
    private let systemPrompt: String?

    public init(apiKey: String, model: String, baseURL: String, systemPrompt: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.systemPrompt = systemPrompt
    }

    public func streamEvents(messages: [ChatMessage], tools: [ToolSpec], system: String?) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            guard let url = URL(string: baseURL + "/chat/completions") else {
                continuation.yield(.error(LLMError.badURL(baseURL + "/chat/completions")))
                continuation.finish()
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            var msgs: [[String: Any]] = []
            let sys = system ?? systemPrompt
            if let sys { msgs.append(["role": "system", "content": sys]) }
            msgs += messages.flatMap { Self.encodeMessages($0) }
            var body: [String: Any] = ["model": model, "stream": true, "messages": msgs]
            if !tools.isEmpty {
                body["tools"] = tools.map { spec in
                    ["type": "function", "function": ["name": spec.name, "description": spec.description, "parameters": spec.inputSchema]]
                }
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line }
                        continuation.yield(.error(LLMError.http(http.statusCode, errBody)))
                        continuation.finish()
                        return
                    }
                    var callByIndex: [Int: (id: String, name: String, args: String)] = [:]
                    var stopReason: StopReason = .endTurn
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let first = choices.first else { continue }
                        if let delta = first["delta"] as? [String: Any] {
                            if let text = delta["content"] as? String, !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                                for call in toolCalls {
                                    let index = call["index"] as? Int ?? 0
                                    var entry = callByIndex[index] ?? (id: "", name: "", args: "")
                                    if let id = call["id"] as? String { entry.id = id }
                                    if let fn = call["function"] as? [String: Any] {
                                        if let name = fn["name"] as? String { entry.name = name }
                                        if let args = fn["arguments"] as? String { entry.args += args }
                                    }
                                    callByIndex[index] = entry
                                }
                            }
                        }
                        if let reason = first["finish_reason"] as? String, reason == "tool_calls" {
                            stopReason = .toolUse
                        }
                    }
                    for index in callByIndex.keys.sorted() {
                        let call = callByIndex[index]!
                        continuation.yield(.toolUseComplete(id: call.id, name: call.name, inputJSON: call.args.isEmpty ? "{}" : call.args))
                    }
                    continuation.yield(.done(stopReason))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One ChatMessage may expand into several OpenAI messages: tool_result
    /// blocks become separate `role:tool` messages, and an assistant turn with
    /// tool_use becomes one assistant message carrying a `tool_calls` array.
    static func encodeMessages(_ m: ChatMessage) -> [[String: Any]] {
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []
        var toolResults: [[String: Any]] = []
        for block in m.content {
            switch block {
            case .text(let s):
                textParts.append(s)
            case .toolUse(let id, let name, let input):
                let argString = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append(["id": id, "type": "function", "function": ["name": name, "arguments": argString]])
            case .toolResult(let toolUseId, let content, _):
                toolResults.append(["role": "tool", "tool_call_id": toolUseId, "content": content])
            }
        }
        var out: [[String: Any]] = []
        if !textParts.isEmpty || !toolCalls.isEmpty {
            var msg: [String: Any] = ["role": m.role.rawValue]
            msg["content"] = textParts.joined()
            if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
            out.append(msg)
        }
        out += toolResults
        return out
    }
}

public func makeProvider(from config: AgentConfig) -> LLMProvider {
    switch config.provider.type.lowercased() {
    case "openai", "openai-compatible":
        return OpenAICompatibleProvider(
            apiKey: config.provider.apiKey,
            model: config.model,
            baseURL: config.provider.baseURL ?? "https://api.openai.com/v1",
            systemPrompt: config.systemPrompt
        )
    default:
        return AnthropicProvider(
            apiKey: config.provider.apiKey,
            model: config.model,
            baseURL: config.provider.baseURL ?? "https://api.anthropic.com",
            systemPrompt: config.systemPrompt
        )
    }
}
