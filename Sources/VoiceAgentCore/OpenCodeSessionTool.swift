import Foundation

public struct OpenCodeSessionTool: Tool {
    private let config: OpenCodeConfig
    private let sendTimeout: TimeInterval = 180

    public init(config: OpenCodeConfig) {
        self.config = config
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "opencode",
            description: """
            Interact with a running OpenCode server. \
            action=list lists sessions (id + title). \
            action=read returns the last assistant reply of a session. \
            action=send posts a prompt to a session and returns OpenCode's reply. \
            If sessionID is omitted, the configured default session is used.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["list", "read", "send"],
                        "description": "Which operation to perform.",
                    ],
                    "sessionID": [
                        "type": "string",
                        "description": "Target session id (e.g. ses_xxx). Optional; falls back to the default session.",
                    ],
                    "text": [
                        "type": "string",
                        "description": "The prompt text to send. Required for action=send.",
                    ],
                ],
                "required": ["action"],
            ]
        )
    }

    public func sideEffect(for input: [String: Any]) -> ToolSideEffect {
        (input["action"] as? String) == "send" ? .destructive : .readOnly
    }

    public func authorizationDescription(input: [String: Any]) -> String {
        let sid = (input["sessionID"] as? String) ?? config.defaultSessionID ?? "(default)"
        let text = (input["text"] as? String) ?? ""
        let preview = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return "opencode.send → session=\(sid): \(preview)"
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let action = input["action"] as? String, !action.isEmpty else {
            return .failure("opencode: missing required parameter 'action'")
        }
        guard URL(string: config.baseURL) != nil else {
            return .failure("opencode: invalid baseURL: \(config.baseURL)")
        }

        switch action {
        case "list":
            return await listSessions()
        case "read":
            guard let sid = resolveSessionID(input) else {
                return .failure("opencode: no sessionID provided and no default configured")
            }
            return await readLastReply(sessionID: sid)
        case "send":
            guard let sid = resolveSessionID(input) else {
                return .failure("opencode: no sessionID provided and no default configured")
            }
            guard let text = input["text"] as? String, !text.isEmpty else {
                return .failure("opencode: missing required parameter 'text' for action=send")
            }
            return await sendPrompt(sessionID: sid, text: text, isCancelled: isCancelled)
        default:
            return .failure("opencode: unknown action '\(action)' (expected list/read/send)")
        }
    }

    // MARK: Actions

    private func listSessions() async -> ToolOutput {
        let req = makeRequest(path: "/session", method: "GET")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                return .failure("opencode: list failed with HTTP \(http.statusCode)")
            }
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .failure("opencode: list returned unexpected shape")
            }
            if arr.isEmpty { return .ok("(no sessions)") }
            let lines = arr.map { s -> String in
                let id = (s["id"] as? String) ?? "?"
                let title = (s["title"] as? String) ?? "(untitled)"
                return "\(id)  \(title)"
            }
            return .ok(lines.joined(separator: "\n"))
        } catch {
            return .failure("opencode: list error: \(error.localizedDescription)")
        }
    }

    private func readLastReply(sessionID: String) async -> ToolOutput {
        let req = makeRequest(path: "/session/\(sessionID)/message", method: "GET")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                return .failure("opencode: read failed with HTTP \(http.statusCode)")
            }
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .failure("opencode: read returned unexpected shape")
            }
            for item in arr.reversed() {
                guard let info = item["info"] as? [String: Any],
                      (info["type"] as? String) == "assistant" else { continue }
                let text = Self.assistantText(info: info, parts: item["parts"] as? [[String: Any]])
                return .ok(text.isEmpty ? "(assistant reply had no text)" : text)
            }
            return .ok("(no assistant reply yet)")
        } catch {
            return .failure("opencode: read error: \(error.localizedDescription)")
        }
    }

    private func sendPrompt(sessionID: String, text: String, isCancelled: @escaping () -> Bool) async -> ToolOutput {
        var req = makeRequest(path: "/session/\(sessionID)/message", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure("opencode: send failed with HTTP \(http.statusCode)")
            }
        } catch {
            return .failure("opencode: send error: \(error.localizedDescription)")
        }

        if isCancelled() { return .failure("opencode: cancelled") }

        let deadline = Date().addingTimeInterval(sendTimeout)
        var lastText = ""
        while Date() < deadline {
            if isCancelled() { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let poll = makeRequest(path: "/session/\(sessionID)/message", method: "GET")
            guard let (data, _) = try? await URLSession.shared.data(for: poll),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { continue }
            for item in arr.reversed() {
                guard let info = item["info"] as? [String: Any],
                      (info["type"] as? String) == "assistant" else { continue }
                let t = Self.assistantText(info: info, parts: item["parts"] as? [[String: Any]])
                if !t.isEmpty { lastText = t }
                if let time = info["time"] as? [String: Any], time["completed"] != nil, !t.isEmpty {
                    return .ok(t)
                }
                break
            }
        }
        if !lastText.isEmpty { return .ok(lastText) }
        return .failure("opencode: no reply received within \(Int(sendTimeout))s")
    }

    // MARK: Helpers

    private func resolveSessionID(_ input: [String: Any]) -> String? {
        if let sid = input["sessionID"] as? String, !sid.isEmpty { return sid }
        if let def = config.defaultSessionID, !def.isEmpty { return def }
        return nil
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let password = config.password, !password.isEmpty {
            let user = config.username ?? "opencode"
            if let creds = "\(user):\(password)".data(using: .utf8) {
                req.setValue("Basic \(creds.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        return req
    }

    static func assistantText(info: [String: Any], parts: [[String: Any]]?) -> String {
        var chunks: [String] = []
        if let content = info["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String, !t.isEmpty { chunks.append(t) }
            }
        }
        if chunks.isEmpty, let parts = parts {
            for p in parts where (p["type"] as? String) == "text" {
                if let t = p["text"] as? String, !t.isEmpty { chunks.append(t) }
            }
        }
        return chunks.joined(separator: "\n")
    }
}
