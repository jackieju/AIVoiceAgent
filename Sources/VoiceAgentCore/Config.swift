import Foundation

public enum ConfigError: Error, CustomStringConvertible {
    case notFound(String)
    case missingEnv(String)
    case parse(String)

    public var description: String {
        switch self {
        case .notFound(let p): return "config not found: \(p)"
        case .missingEnv(let n): return "environment variable not set: \(n)"
        case .parse(let e): return "config parse error: \(e)"
        }
    }
}

public struct ProviderConfig: Codable, Sendable {
    public var type: String
    public var baseURL: String?
    public var apiKey: String
}

public struct VoiceConfig: Codable, Sendable {
    public var ttsVoice: String?
    public var sttLocale: String?
    /// "edge" (Microsoft neural, needs edgePythonPath) or "system" (AVSpeechSynthesizer, offline).
    public var ttsEngine: String?
    public var edgePythonPath: String?
    public var edgeVoiceZh: String?
    public var edgeVoiceEn: String?
    /// whisper initial prompt to bias recognition of domain terms (e.g. "OpenCode, Claude").
    /// If nil, WhisperStt falls back to terms from TranscriptCorrector.defaultRules.
    public var whisperPrompt: String?
}

public struct NVPConfig: Codable, Sendable {
    public var enabled: Bool?
    public var binaryPath: String?
    public var dbPath: String?
    public var projectId: String?
}

public struct MCPServerConfigJSON: Codable, Sendable {
    public var command: String
    public var args: [String]?
    public var env: [String: String]?
}

/// 路线B（OpenAI Realtime）配置。为 nil 时该路线整体禁用。
public struct RealtimeConfig: Codable, Sendable {
    public var model: String
    /// 支持 "{env:OPENAI_API_KEY}" 注入。
    public var apiKey: String
    /// 默认 https://api.openai.com。
    public var baseURL: String?
    public var voice: String?
    /// nil 时用内置桥接接待员提示。
    public var instructions: String?
}

public struct OpenCodeConfig: Codable, Sendable {
    /// e.g. "http://127.0.0.1:4096"
    public var baseURL: String
    /// HTTP Basic username; OpenCode server defaults to "opencode".
    public var username: String?
    /// Use "{env:OPENCODE_SERVER_PASSWORD}" to inject from the environment.
    public var password: String?
    public var defaultSessionID: String?
}

public struct AgentConfig: Codable, Sendable {
    public var model: String
    public var provider: ProviderConfig
    public var systemPrompt: String?
    public var voice: VoiceConfig?
    public var nvp: NVPConfig?
    public var maxRounds: Int?
    public var mcpServers: [String: MCPServerConfigJSON]?
    public var opencode: OpenCodeConfig?
    public var realtime: RealtimeConfig?

    public static func load(from path: String) throws -> AgentConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfigError.notFound(url.path)
        }
        let expanded = try expandEnv(raw)
        guard let data = expanded.data(using: .utf8) else {
            throw ConfigError.parse("not valid utf8")
        }
        do {
            return try JSONDecoder().decode(AgentConfig.self, from: data)
        } catch {
            throw ConfigError.parse("\(error)")
        }
    }

    static func expandEnv(_ text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: "\\{env:([A-Za-z_][A-Za-z0-9_]*)\\}")
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else { continue }
            let name = String(result[nameRange])
            guard let value = ProcessInfo.processInfo.environment[name] else {
                throw ConfigError.missingEnv(name)
            }
            result.replaceSubrange(fullRange, with: value)
        }
        return result
    }
}
