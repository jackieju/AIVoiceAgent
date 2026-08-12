import Foundation

public struct ChatMessage {
    public enum Role: String { case user, assistant }
    public let role: Role
    public let text: String
    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public protocol LLMProvider {
    func stream(
        messages: [ChatMessage],
        onDelta: @escaping (String) -> Void,
        onDone: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    )
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

    public func stream(messages: [ChatMessage], onDelta: @escaping (String) -> Void, onDone: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        guard let url = URL(string: baseURL + "/v1/messages") else {
            onError(LLMError.badURL(baseURL + "/v1/messages")); return
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
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if let systemPrompt { body["system"] = systemPrompt }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var errBody = ""
                    for try await line in bytes.lines { errBody += line }
                    onError(LLMError.http(http.statusCode, errBody)); return
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let type = obj["type"] as? String else { continue }
                    if type == "content_block_delta",
                       let delta = obj["delta"] as? [String: Any],
                       let text = delta["text"] as? String {
                        onDelta(text)
                    } else if type == "message_stop" {
                        break
                    }
                }
                onDone()
            } catch {
                onError(error)
            }
        }
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

    public func stream(messages: [ChatMessage], onDelta: @escaping (String) -> Void, onDone: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            onError(LLMError.badURL(baseURL + "/chat/completions")); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var msgs: [[String: Any]] = []
        if let systemPrompt { msgs.append(["role": "system", "content": systemPrompt]) }
        msgs += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = ["model": model, "stream": true, "messages": msgs]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var errBody = ""
                    for try await line in bytes.lines { errBody += line }
                    onError(LLMError.http(http.statusCode, errBody)); return
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = obj["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let text = delta["content"] as? String else { continue }
                    onDelta(text)
                }
                onDone()
            } catch {
                onError(error)
            }
        }
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
