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

public struct ProviderConfig: Codable {
    public var type: String
    public var baseURL: String?
    public var apiKey: String
}

public struct VoiceConfig: Codable {
    public var ttsVoice: String?
    public var sttLocale: String?
}

public struct NVPConfig: Codable {
    public var enabled: Bool?
    public var binaryPath: String?
    public var dbPath: String?
    public var projectId: String?
}

public struct MCPServerConfigJSON: Codable {
    public var command: String
    public var args: [String]?
    public var env: [String: String]?
}

public struct AgentConfig: Codable {
    public var model: String
    public var provider: ProviderConfig
    public var systemPrompt: String?
    public var voice: VoiceConfig?
    public var nvp: NVPConfig?
    public var maxRounds: Int?
    public var mcpServers: [String: MCPServerConfigJSON]?

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
