import Foundation

/// Anthropic-native content shape; OpenAICompatibleProvider translates to/from
/// this internally so upper layers stay uniform.
public enum ContentBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(toolUseId: String, content: String, isError: Bool)
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

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func ok(_ content: String) -> ToolOutput { ToolOutput(content: content, isError: false) }
    public static func failure(_ message: String) -> ToolOutput { ToolOutput(content: message, isError: true) }
}

/// A tool the agent can execute. Implementations must be safe to call from a
/// background task and should honor `isCancelled` for long-running work.
public protocol Tool {
    var spec: ToolSpec { get }
    /// Execute with the model-provided input object. Return output (never throw
    /// for expected failures — return `.failure`). `isCancelled` lets long ops
    /// (bash/webfetch) bail cooperatively when the user barges in.
    func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput
}

/// Holds built-in and MCP-provided tools, keyed by the name sent to the model.
/// Thread-safe: MCP tools may be registered from a background task after the
/// session has already started reading `specs` / calling `execute`.
public final class ToolRegistry {
    private var tools: [String: Tool] = [:]
    private let lock = NSLock()

    public init(_ tools: [Tool] = []) {
        for t in tools { register(t) }
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

    public func execute(name: String, input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let tool = lookup(name) else {
            return .failure("unknown tool: \(name)")
        }
        return await tool.execute(input: input, isCancelled: isCancelled)
    }
}
