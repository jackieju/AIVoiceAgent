import Foundation
import FlyingFox
import VoiceAgentCore

func resolveConfigPath() -> String {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--config"), idx + 1 < args.count {
        return args[idx + 1]
    }
    return "~/.config/aivoiceagent/config.json"
}

func resolvePort() -> UInt16 {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--port"), idx + 1 < args.count,
       let p = UInt16(args[idx + 1]) {
        return p
    }
    return 8765
}

func realtimeToolsJSON() -> [[String: Any]] {
    RealtimeBridgeSession.toolSpecs.map { spec in
        [
            "type": "function",
            "name": spec.name,
            "description": spec.description,
            "parameters": spec.inputSchema,
        ]
    }
}

func signEphemeral(realtime: RealtimeConfig) async throws -> Data {
    let base = realtime.baseURL ?? "https://api.openai.com"
    guard let url = URL(string: "\(base)/v1/realtime/sessions") else {
        throw ConfigError.parse("invalid realtime baseURL")
    }
    var body: [String: Any] = [
        "model": realtime.model,
        "modalities": ["audio", "text"],
        "tools": realtimeToolsJSON(),
        "tool_choice": "auto",
    ]
    if let voice = realtime.voice { body["voice"] = voice }
    body["instructions"] = realtime.instructions ?? RealtimeBridgeSession.receptionistInstructions

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(realtime.apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? ""
        throw ConfigError.parse("ephemeral session mint failed (\(code)): \(text)")
    }
    guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return data
    }
    obj["sdp_url"] = "\(base)/v1/realtime?model=\(realtime.model)"
    return try JSONSerialization.data(withJSONObject: obj)
}

func publicRootURL() -> URL {
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
    let candidates = [
        exeDir.appendingPathComponent("AIVoiceAgent_VoiceAgentWeb.bundle/Public"),
        Bundle.module.resourceURL?.appendingPathComponent("Public"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Public"),
    ].compactMap { $0 }
    for c in candidates {
        if FileManager.default.fileExists(atPath: c.appendingPathComponent("index.html").path) {
            return c
        }
    }
    return candidates[0]
}

let configPath = resolveConfigPath()
let config: AgentConfig
do {
    config = try AgentConfig.load(from: configPath)
} catch {
    FileHandle.standardError.write("配置加载失败：\(error)\n预期路径：\(configPath)\n".data(using: .utf8)!)
    exit(1)
}

let store = HistoryStore(path: "~/Library/Application Support/AIVoiceAgent/history.json")

let registry = ToolRegistry(makeBuiltinTools(opencode: config.opencode))
registry.setAuthorizer { _, _ in false }

let system = config.systemPrompt
let maxRounds = config.maxRounds ?? 5

let handler = ChatWSHandler(
    makeAgent: {
        AgentLoop(provider: makeProvider(from: config), registry: registry, system: system, maxRounds: maxRounds)
    },
    store: store
)

let port = resolvePort()
let server = HTTPServer(address: try .inet(ip4: "127.0.0.1", port: port), timeout: 30)

let publicRoot = publicRootURL()
let indexURL = publicRoot.appendingPathComponent("index.html")

await server.appendRoute("GET /ws", to: .webSocket(handler))

if let realtime = config.realtime {
    await server.appendRoute("GET /ws-realtime-control", to: .webSocket(RealtimeControlWSHandler(makeAgent: {
        AgentLoop(provider: makeProvider(from: config), registry: registry, system: system, maxRounds: maxRounds)
    })))
    await server.appendRoute("POST /realtime/session", to: ClosureHTTPHandler { _ in
        do {
            let data = try await signEphemeral(realtime: realtime)
            return HTTPResponse(statusCode: .ok,
                                headers: [.contentType: "application/json"],
                                body: data)
        } catch {
            let msg = "{\"error\":\"\(error)\"}".data(using: .utf8) ?? Data()
            return HTTPResponse(statusCode: .internalServerError,
                                headers: [.contentType: "application/json"],
                                body: msg)
        }
    })
    print("路线B（Realtime）已启用：model=\(realtime.model)")
}

await server.appendRoute("GET /", to: FileHTTPHandler(path: indexURL, contentType: "text/html"))
await server.appendRoute("GET /*", to: DirectoryHTTPHandler(root: publicRoot, serverPath: "/"))

print("AI Voice Agent Web Dashboard: http://127.0.0.1:\(port)")
print("model=\(config.model)  provider=\(config.provider.type)")

try await server.run()
