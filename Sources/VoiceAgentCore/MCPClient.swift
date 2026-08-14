import Foundation

public struct MCPServerConfig {
    public let name: String
    public let command: String
    public let args: [String]
    public let env: [String: String]

    public init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}

public final class MCPClient {
    private let config: MCPServerConfig
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()
    private var buffer = Data()
    private var started = false

    public private(set) var toolSpecs: [ToolSpec] = []

    public init(_ config: MCPServerConfig) {
        self.config = config
    }

    public func start() async throws {
        guard !started else { return }
        process.executableURL = try resolveExecutable(config.command)
        process.arguments = config.args
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in config.env { environment[k] = v }
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.ingest(data) }
        }

        try process.run()
        started = true

        let initResult = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "AIVoiceAgent", "version": "1.0.0"],
        ])
        _ = initResult
        try notify("notifications/initialized", params: [:])

        let listResult = try await request("tools/list", params: [:])
        if let tools = listResult["tools"] as? [[String: Any]] {
            toolSpecs = tools.compactMap { t in
                guard let name = t["name"] as? String else { return nil }
                let desc = (t["description"] as? String) ?? ""
                let schema = (t["inputSchema"] as? [String: Any]) ?? ["type": "object"]
                return ToolSpec(name: name, description: desc, inputSchema: schema)
            }
        }
    }

    public func callTool(name: String, arguments: [String: Any]) async throws -> ToolOutput {
        let result = try await request("tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        let isError = (result["isError"] as? Bool) ?? false
        var text = ""
        if let content = result["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "text", let t = block["text"] as? String {
                    text += t
                }
            }
        }
        return ToolOutput(content: text.isEmpty ? "(no output)" : text, isError: isError)
    }

    public func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) else { continue }
            if let error = obj["error"] as? [String: Any] {
                let msg = (error["message"] as? String) ?? "unknown MCP error"
                cont.resume(throwing: MCPError.rpc(msg))
            } else {
                cont.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
            }
        }
        lock.unlock()
    }

    private func allocateId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    private func storePending(_ id: Int, _ cont: CheckedContinuation<[String: Any], Error>) {
        lock.lock()
        defer { lock.unlock() }
        pending[id] = cont
    }

    private func removePending(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeValue(forKey: id)
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = allocateId()
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try await withCheckedThrowingContinuation { cont in
            storePending(id, cont)
            do {
                try write(payload)
            } catch {
                removePending(id)
                cont.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String, params: [String: Any]) throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        stdinPipe.fileHandleForWriting.write(data)
    }

    private func resolveExecutable(_ command: String) throws -> URL {
        if command.contains("/") { return URL(fileURLWithPath: command) }
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw MCPError.executableNotFound(command)
    }
}

public enum MCPError: Error, CustomStringConvertible {
    case rpc(String)
    case executableNotFound(String)

    public var description: String {
        switch self {
        case .rpc(let m): return "MCP RPC error: \(m)"
        case .executableNotFound(let c): return "MCP executable not found: \(c)"
        }
    }
}

public struct MCPTool: Tool {
    public let spec: ToolSpec
    private let client: MCPClient

    public init(spec: ToolSpec, client: MCPClient) {
        self.spec = spec
        self.client = client
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        do {
            return try await client.callTool(name: spec.name, arguments: input)
        } catch {
            return .failure("\(spec.name): \(error)")
        }
    }
}

public func connectMCPServers(_ configs: [MCPServerConfig]) async -> (tools: [Tool], clients: [MCPClient]) {
    var tools: [Tool] = []
    var clients: [MCPClient] = []
    for cfg in configs {
        let client = MCPClient(cfg)
        do {
            try await client.start()
            for spec in client.toolSpecs {
                tools.append(MCPTool(spec: spec, client: client))
            }
            clients.append(client)
        } catch {
            FileHandle.standardError.write("MCP server '\(cfg.name)' failed to start: \(error)\n".data(using: .utf8)!)
        }
    }
    return (tools, clients)
}
