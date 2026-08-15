import Foundation

public struct WebFetchTool: Tool {
    private let defaultTimeout: TimeInterval = 30
    private let maxTimeout: TimeInterval = 120
    private let maxResponseSize = 5 * 1024 * 1024
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "webfetch",
            description: "Fetch content from a URL. Returns text, markdown, or html. URL must start with http:// or https://.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The URL to fetch content from"],
                    "format": [
                        "type": "string",
                        "enum": ["text", "markdown", "html"],
                        "description": "The format to return the content in (text, markdown, or html). Defaults to markdown.",
                    ],
                    "timeout": ["type": "number", "description": "Optional timeout in seconds (max 120)"],
                ],
                "required": ["url"],
            ]
        )
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let urlStr = input["url"] as? String, !urlStr.isEmpty else {
            return .failure("webfetch: missing required parameter 'url'")
        }
        guard urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://") else {
            return .failure("webfetch: URL must start with http:// or https://")
        }
        guard let url = URL(string: urlStr) else {
            return .failure("webfetch: invalid URL: \(urlStr)")
        }
        let format = (input["format"] as? String) ?? "markdown"
        var timeout = (input["timeout"] as? NSNumber)?.doubleValue ?? defaultTimeout
        timeout = min(timeout, maxTimeout)

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(acceptHeader(for: format), forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if isCancelled() { return .failure("webfetch: cancelled") }
            if data.count > maxResponseSize {
                return .failure("webfetch: Response too large (exceeds 5MB limit)")
            }
            let mime = (response as? HTTPURLResponse)?.mimeType ?? ""
            if mime.hasPrefix("image/") {
                return .ok("Image fetched successfully")
            }
            guard let bodyRaw = String(data: data, encoding: .utf8) else {
                return .failure("webfetch: response is not UTF-8 text")
            }
            let body = format == "html" ? bodyRaw : stripHTML(bodyRaw)
            return .ok(body)
        } catch {
            return .failure("webfetch: \(error.localizedDescription)")
        }
    }

    private func acceptHeader(for format: String) -> String {
        switch format {
        case "markdown":
            return "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1"
        case "text":
            return "text/plain;q=1.0, text/html;q=0.8, */*;q=0.1"
        default:
            return "text/html;q=1.0, */*;q=0.1"
        }
    }

    private func stripHTML(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "iframe", "head"] {
            text = removeTagBlocks(text, tag: tag)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private func removeTagBlocks(_ input: String, tag: String) -> String {
        input.replacingOccurrences(
            of: "<\(tag)[^>]*>.*?</\(tag)>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

public func makeBuiltinTools(bashTimeoutMs: Int = 120_000, opencode: OpenCodeConfig? = nil) -> [Tool] {
    var tools: [Tool] = [
        ReadTool(),
        WriteTool(),
        EditTool(),
        ListTool(),
        BashTool(defaultTimeoutMs: bashTimeoutMs),
        GrepTool(),
        GlobTool(),
        WebFetchTool(),
    ]
    if let opencode {
        tools.append(OpenCodeSessionTool(config: opencode))
    }
    return tools
}
