import Foundation

/// 通过子进程运行 NVP server（ai-agent-local-memory 的 Bun 编译二进制），
/// 走 NDJSON JSON-RPC over stdin/stdout。用于把语音对话的历史压缩后再喂给 LLM。
///
/// 设计要点（依 Oracle 策略 bg_91ba5d7d）：
/// - 单个长驻子进程，VoiceSession 初始化时拉起。
/// - ingest 走增量（只喂新的一轮 user+assistant），fire-and-forget，不阻塞语音线程。
/// - renderContext 同步调用但带硬超时；超时/出错/子进程死亡一律降级回原始历史。
/// - 子进程 EOF/崩溃标记 unhealthy，后台尝试重启一次；unhealthy 期间跳过压缩。
public final class NVPClient {
    public struct Config {
        public var binaryPath: String
        public var dbPath: String
        public var projectId: String
        public init(binaryPath: String, dbPath: String, projectId: String = "voice") {
            self.binaryPath = binaryPath
            self.dbPath = dbPath
            self.projectId = projectId
        }
    }

    public struct RenderedMessage {
        public let role: String
        public let content: String
    }

    private let config: Config
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var readBuffer = Data()

    private let ioQueue = DispatchQueue(label: "nvp.io")
    private(set) public var isHealthy = false
    private var respawnAttempted = false

    public init(config: Config) {
        self.config = config
    }

    // MARK: - 生命周期

    /// 拉起子进程。失败不抛错——直接标记 unhealthy，语音循环照常用原始历史。
    public func start() {
        lock.lock(); defer { lock.unlock() }
        spawnLocked()
    }

    private func spawnLocked() {
        let expanded = (config.binaryPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expanded) else {
            NSLog("[NVP] 二进制不可执行或不存在: \(expanded) — 压缩已禁用")
            isHealthy = false
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: expanded)
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.handleTermination()
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingestReadData(data)
        }

        do {
            try proc.run()
        } catch {
            NSLog("[NVP] 子进程启动失败: \(error) — 压缩已禁用")
            isHealthy = false
            return
        }

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.isHealthy = true
        NSLog("[NVP] 子进程已启动 pid=\(proc.processIdentifier) db=\(config.dbPath)")
    }

    private func handleTermination() {
        lock.lock()
        isHealthy = false
        // 拒绝所有在途请求，触发降级。
        let inflight = pending
        pending.removeAll()
        let shouldRespawn = !respawnAttempted
        respawnAttempted = true
        lock.unlock()

        for (_, cb) in inflight {
            cb(.failure(NVPError.subprocessDied))
        }

        if shouldRespawn {
            NSLog("[NVP] 子进程退出，1s 后尝试重启一次")
            ioQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.lock.lock(); self.spawnLocked(); self.lock.unlock()
            }
        } else {
            NSLog("[NVP] 子进程再次退出，放弃重启 — 压缩永久禁用（本 session）")
        }
    }

    public func shutdown() {
        lock.lock()
        let proc = process
        process = nil
        isHealthy = false
        lock.unlock()
        proc?.terminate()
    }

    // MARK: - 读取 / 分帧

    private func ingestReadData(_ data: Data) {
        lock.lock()
        readBuffer.append(data)
        var lines: [Data] = []
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()

        for line in lines { handleResponseLine(line) }
    }

    private func handleResponseLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = obj["id"] as? Int else {
            return
        }
        lock.lock()
        let cb = pending.removeValue(forKey: id)
        lock.unlock()
        guard let cb = cb else { return }

        if let err = obj["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "unknown rpc error"
            cb(.failure(NVPError.rpc(msg)))
        } else {
            cb(.success(obj["result"] ?? NSNull()))
        }
    }

    // MARK: - 发送

    private func send(method: String, params: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        lock.lock()
        guard isHealthy, let stdin = stdinPipe else {
            lock.unlock()
            completion(.failure(NVPError.notHealthy))
            return
        }
        let id = nextId; nextId += 1
        pending[id] = completion
        lock.unlock()

        var rpcParams = params
        rpcParams["dbPath"] = config.dbPath
        rpcParams["projectId"] = config.projectId

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": rpcParams,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            completion(.failure(NVPError.encodeFailed))
            return
        }
        var framed = data
        framed.append(0x0A)

        ioQueue.async {
            do {
                try stdin.fileHandleForWriting.write(contentsOf: framed)
            } catch {
                self.lock.lock(); let cb = self.pending.removeValue(forKey: id); self.lock.unlock()
                cb?(.failure(error))
            }
        }
    }

    // MARK: - 公开 RPC

    /// 增量喂入一轮对话。fire-and-forget，不等结果。
    public func ingest(sessionId: String, turn: [(role: String, content: String)]) {
        guard isHealthy else { return }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let messages = turn.map { ["role": $0.role, "content": $0.content, "timestamp": now] as [String: Any] }
        let session: [String: Any] = ["id": sessionId, "messages": messages]
        send(method: "ingest", params: ["session": session]) { result in
            if case .failure(let e) = result {
                NSLog("[NVP] ingest 失败（已忽略）: \(e)")
            }
        }
    }

    /// 同步获取压缩后的历史，带硬超时。超时/出错/不健康返回 nil（调用方降级到原始历史）。
    public func renderContext(
        sessionId: String,
        contextWindowTokens: Int,
        budgetRatio: Double,
        recentFullTextTurns: Int,
        timeout: TimeInterval = 0.15
    ) -> [RenderedMessage]? {
        guard isHealthy else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var captured: [RenderedMessage]?

        send(
            method: "renderContext",
            params: [
                "sessionId": sessionId,
                "contextWindowTokens": contextWindowTokens,
                "budgetRatio": budgetRatio,
                "recentFullTextTurns": recentFullTextTurns,
                "seeds": [],
            ]
        ) { result in
            defer { sem.signal() }
            guard case .success(let value) = result,
                  let dict = value as? [String: Any],
                  let msgs = dict["messages"] as? [[String: Any]] else {
                return
            }
            captured = msgs.compactMap { m in
                guard let role = m["role"] as? String,
                      let content = m["content"] as? String else { return nil }
                return RenderedMessage(role: role, content: content)
            }
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("[NVP] renderContext 超时 \(Int(timeout * 1000))ms — 降级到原始历史")
            return nil
        }
        return captured
    }
}

public enum NVPError: Error, CustomStringConvertible {
    case notHealthy
    case subprocessDied
    case encodeFailed
    case rpc(String)

    public var description: String {
        switch self {
        case .notHealthy: return "NVP 子进程不健康"
        case .subprocessDied: return "NVP 子进程已退出"
        case .encodeFailed: return "NVP 请求序列化失败"
        case .rpc(let m): return "NVP RPC 错误: \(m)"
        }
    }
}
