import Foundation

/// Anthropic-native content shape; OpenAICompatibleProvider translates to/from
/// this internally so upper layers stay uniform.
public enum ContentBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    /// `imageBase64` (PNG, no data: prefix) lets a tool return a screenshot the
    /// model can actually see. Anthropic encodes it as an image block inside the
    /// tool_result; OpenAI-compatible providers drop it (text only).
    case toolResult(toolUseId: String, content: String, isError: Bool, imageBase64: String? = nil)
}

public struct ToolSpec {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Outcome of executing a tool. Errors are returned (not thrown) so the agentic
/// loop can feed them back to the model as `tool_result` with isError=true.
public struct ToolOutput {
    public let content: String
    public let isError: Bool
    public let imageBase64: String?

    public init(content: String, isError: Bool = false, imageBase64: String? = nil) {
        self.content = content
        self.isError = isError
        self.imageBase64 = imageBase64
    }

    public static func ok(_ content: String) -> ToolOutput { ToolOutput(content: content, isError: false) }
    public static func failure(_ message: String) -> ToolOutput { ToolOutput(content: message, isError: true) }
    public static func image(_ base64: String, note: String) -> ToolOutput {
        ToolOutput(content: note, isError: false, imageBase64: base64)
    }
}

/// A tool the agent can execute. Implementations must be safe to call from a
/// background task and should honor `isCancelled` for long-running work.
public enum ToolSideEffect {
    case readOnly
    /// MUST be authorized by the user before running.
    case destructive
}

public protocol Tool {
    var spec: ToolSpec { get }
    var sideEffect: ToolSideEffect { get }
    /// Return `.failure` for expected errors instead of throwing, so the loop can
    /// feed them back as tool_result(isError:true). Honor `isCancelled` for
    /// long-running work so the user can barge in.
    func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput
    /// Per-invocation classification: bash inspects `input` so plain `ls` stays
    /// read-only while `rm -rf` is destructive. Defaults to `sideEffect`.
    func sideEffect(for input: [String: Any]) -> ToolSideEffect
    func authorizationDescription(input: [String: Any]) -> String
}

extension Tool {
    public var sideEffect: ToolSideEffect { .readOnly }
    public func sideEffect(for input: [String: Any]) -> ToolSideEffect { sideEffect }
    public func authorizationDescription(input: [String: Any]) -> String {
        let keys = ["command", "filePath", "path"]
        for k in keys {
            if let v = input[k] as? String, !v.isEmpty {
                return "\(spec.name): \(v)"
            }
        }
        return spec.name
    }
}

/// Bridges the destructive-tool gate to the host UI (Core stays AppKit-free).
/// Returns true to allow, false to deny. When nil, the registry DENIES all
/// destructive operations (fail-safe).
public typealias ToolAuthorizer = (_ toolName: String, _ description: String) async -> Bool

/// Holds built-in and MCP-provided tools, keyed by the name sent to the model.
/// Thread-safe: MCP tools may be registered from a background task after the
/// session has already started reading `specs` / calling `execute`.
public final class ToolRegistry {
    private var tools: [String: Tool] = [:]
    private let lock = NSLock()
    private var authorizer: ToolAuthorizer?

    public init(_ tools: [Tool] = []) {
        for t in tools { register(t) }
    }

    public func setAuthorizer(_ authorizer: @escaping ToolAuthorizer) {
        lock.lock(); defer { lock.unlock() }
        self.authorizer = authorizer
    }

    private func currentAuthorizer() -> ToolAuthorizer? {
        lock.lock(); defer { lock.unlock() }
        return authorizer
    }

    public func register(_ tool: Tool) {
        lock.lock(); defer { lock.unlock() }
        tools[tool.spec.name] = tool
    }

    public func registerAll(_ list: [Tool]) {
        lock.lock(); defer { lock.unlock() }
        for t in list { tools[t.spec.name] = t }
    }

    public var specs: [ToolSpec] {
        lock.lock(); defer { lock.unlock() }
        return tools.values.map { $0.spec }
    }

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return tools.isEmpty
    }

    private func lookup(_ name: String) -> Tool? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }

    public func sideEffect(of name: String) -> ToolSideEffect {
        lookup(name)?.sideEffect ?? .readOnly
    }

    public func execute(name: String, input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let tool = lookup(name) else {
            return .failure("unknown tool: \(name)")
        }
        if case .destructive = tool.sideEffect(for: input) {
            let desc = tool.authorizationDescription(input: input)
            guard let authorizer = currentAuthorizer() else {
                return .failure("\(name): destructive operation blocked (no authorizer configured)")
            }
            let approved = await authorizer(name, desc)
            guard approved else {
                return .failure("\(name): operation denied by user")
            }
        }
        return await tool.execute(input: input, isCancelled: isCancelled)
    }
}
