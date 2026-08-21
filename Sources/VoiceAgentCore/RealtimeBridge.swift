import Foundation

/// 路线B 的工具委托桥。语音接待员（OpenAI Realtime 模型）调 `ask_agent` 时，
/// 前端把 function_call 通过控制 WS 转到这里；桥立即派一个 Task 跑一次无状态
/// AgentLoop（history=[question]），跑完把最终文本经 `reply` 回写前端，前端再
/// 用 function_call_output 回喂给 Realtime 让它说出来。
///
/// actor 隔离保证 `inflight` 与 `reply` 的写入串行化；`handleToolCall` 绝不
/// await AgentLoop，事件泵派完 Task 立即返回，长任务不阻塞后续音频/打断。
public actor RealtimeBridgeSession {
    public struct ToolCall: Sendable {
        public let callId: String
        public let name: String
        public let arguments: String
        public init(callId: String, name: String, arguments: String) {
            self.callId = callId
            self.name = name
            self.arguments = arguments
        }
    }

    public struct ToolReply: Sendable {
        public let callId: String
        public let output: String
        public init(callId: String, output: String) {
            self.callId = callId
            self.output = output
        }
    }

    public static let askAgentToolName = "ask_agent"
    public static let hangUpToolName = "hang_up"

    public static let receptionistInstructions = """
    你是一个语音接待员，用自然、简短的口语跟用户对话。用户说什么语言你就用什么语言回答，默认中文。
    你自己只处理寒暄、澄清和转述。凡是需要工具、实时信息、文件/代码操作、深度推理或你不确定的问题，
    一律调用 ask_agent 把完整诉求委托给后台文本 agent，拿到结果后用口语转述给用户，不要照读原文。
    调用 ask_agent 前可以先说一句「稍等，我查一下」之类的话，避免冷场。
    当用户明确表示结束通话时，先说完最后一句告别语，再调用 hang_up。
    """

    private let makeAgent: @Sendable () -> AgentLoop
    private let reply: @Sendable (ToolReply) async -> Void
    private var inflight: [String: Task<Void, Never>] = [:]

    public init(
        makeAgent: @escaping @Sendable () -> AgentLoop,
        reply: @escaping @Sendable (ToolReply) async -> Void
    ) {
        self.makeAgent = makeAgent
        self.reply = reply
    }

    public static var toolSpecs: [ToolSpec] {
        [
            ToolSpec(
                name: askAgentToolName,
                description: "把需要工具、实时信息、深度推理或代码/文件操作的问题委托给后台文本 agent。它拥有完整工具集（bash/read/write/搜索/网页等）。语音接待员自己回答不了的一律调用它，拿到结果后用口语转述给用户。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "question": [
                            "type": "string",
                            "description": "要委托给文本 agent 的完整问题，用第三人称完整描述用户诉求。",
                        ],
                        "context": [
                            "type": "string",
                            "description": "可选。本轮语音对话里与该问题相关的背景摘要。",
                        ],
                    ],
                    "required": ["question"],
                ]
            ),
            ToolSpec(
                name: hangUpToolName,
                description: "结束当前语音通话。调用前先把要对用户说的最后一句话说完，因为调用后通话立即结束、不再有语音回复。",
                inputSchema: ["type": "object", "properties": [:]]
            ),
        ]
    }

    /// 事件泵调用点：立即派 Task 不阻塞，只处理 ask_agent。
    public func handleToolCall(_ call: ToolCall) {
        guard call.name == Self.askAgentToolName else { return }
        let existing = inflight[call.callId]
        existing?.cancel()
        inflight[call.callId] = Task { [weak self] in
            await self?.runAgentAndReply(call)
        }
    }

    public func cancel(callId: String) {
        inflight[callId]?.cancel()
        inflight[callId] = nil
    }

    public func cancelAll() {
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
    }

    private func runAgentAndReply(_ call: ToolCall) async {
        let args = parseJSONObject(call.arguments)
        let question = (args["question"] as? String) ?? ""
        let contextNote = args["context"] as? String
        var prompt = question
        if let contextNote, !contextNote.isEmpty {
            prompt = "背景：\(contextNote)\n\n问题：\(question)"
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await finish(callId: call.callId, output: "（ask_agent 收到空问题，未执行）")
            return
        }

        let cancel = CancelBox()
        let collector = TextCollector()
        let agent = makeAgent()

        await withTaskCancellationHandler {
            await agent.run(
                history: [ChatMessage(role: .user, text: prompt)],
                isCurrent: { !cancel.isCancelled },
                onTextDelta: { collector.append($0) },
                onToolStart: { _ in },
                onAssistantMessage: { _ in },
                onToolResultMessage: { _ in },
                onDone: { _ in }
            )
        } onCancel: {
            cancel.markCancelled()
        }

        if Task.isCancelled { inflight[call.callId] = nil; return }

        let text = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
        await finish(callId: call.callId, output: text.isEmpty ? "（无结果）" : text)
    }

    private func finish(callId: String, output: String) async {
        inflight[callId] = nil
        await reply(ToolReply(callId: callId, output: output))
    }
}

/// nonisolated 同步取消标志，桥 AgentLoop 的同步 `isCurrent` 闭包与 actor 的
/// 结构化取消。用 NSLock 与项目其余部分保持一致。
final class CancelBox: @unchecked Sendable {
    private var cancelled = false
    private let lock = NSLock()
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func markCancelled() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// nonisolated 文本累加器，收 AgentLoop 的同步 onTextDelta 回调。
final class TextCollector: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()
    func append(_ s: String) {
        lock.lock(); buffer += s; lock.unlock()
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
