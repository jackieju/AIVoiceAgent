import XCTest
@testable import VoiceAgentCore

final class RealtimeBridgeTests: XCTestCase {

    private func makeBridge(
        provider: LLMProvider,
        registry: ToolRegistry,
        onReply: @escaping @Sendable (RealtimeBridgeSession.ToolReply) -> Void
    ) -> RealtimeBridgeSession {
        RealtimeBridgeSession(
            makeAgent: { AgentLoop(provider: provider, registry: registry, system: nil, maxRounds: 5) },
            reply: { reply in onReply(reply) }
        )
    }

    func testAskAgentPlainTextRoundtrip() async {
        let provider = ScriptedProvider([
            .init(events: [.textDelta("巴黎"), .textDelta("是法国首都"), .done(.endTurn)])
        ])
        let box = ReplyBox()
        let bridge = makeBridge(provider: provider, registry: ToolRegistry()) { box.set($0) }

        await bridge.handleToolCall(.init(callId: "c1", name: "ask_agent",
            arguments: "{\"question\":\"法国首都是哪\"}"))

        let reply = await box.wait()
        XCTAssertEqual(reply.callId, "c1")
        XCTAssertEqual(reply.output, "巴黎是法国首都")
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(provider.seenMessages.first?.first?.text, "法国首都是哪")
    }

    func testAskAgentDrivesFullToolLoop() async {
        let tool = SpyTool(name: "read", output: .ok("42"))
        let registry = ToolRegistry([tool])
        let provider = ScriptedProvider([
            .init(events: [
                .toolUseComplete(id: "t1", name: "read", inputJSON: "{\"filePath\":\"/x\"}"),
                .done(.toolUse),
            ]),
            .init(events: [.textDelta("答案是42"), .done(.endTurn)]),
        ])
        let box = ReplyBox()
        let bridge = makeBridge(provider: provider, registry: registry) { box.set($0) }

        await bridge.handleToolCall(.init(callId: "c2", name: "ask_agent",
            arguments: "{\"question\":\"读文件\"}"))

        let reply = await box.wait()
        XCTAssertEqual(reply.output, "答案是42")
        XCTAssertEqual(tool.executed, 1)
        XCTAssertEqual(provider.callCount, 2)
    }

    func testContextPrependedToQuestion() async {
        let provider = ScriptedProvider([
            .init(events: [.textDelta("ok"), .done(.endTurn)])
        ])
        let box = ReplyBox()
        let bridge = makeBridge(provider: provider, registry: ToolRegistry()) { box.set($0) }

        await bridge.handleToolCall(.init(callId: "c3", name: "ask_agent",
            arguments: "{\"question\":\"继续\",\"context\":\"刚在聊天气\"}"))

        _ = await box.wait()
        let prompt = provider.seenMessages.first?.first?.text ?? ""
        XCTAssertTrue(prompt.contains("刚在聊天气"))
        XCTAssertTrue(prompt.contains("继续"))
    }

    func testEmptyQuestionShortCircuits() async {
        let provider = ScriptedProvider([
            .init(events: [.textDelta("不该被调"), .done(.endTurn)])
        ])
        let box = ReplyBox()
        let bridge = makeBridge(provider: provider, registry: ToolRegistry()) { box.set($0) }

        await bridge.handleToolCall(.init(callId: "c4", name: "ask_agent",
            arguments: "{\"question\":\"\"}"))

        let reply = await box.wait()
        XCTAssertEqual(reply.callId, "c4")
        XCTAssertTrue(reply.output.contains("空问题"))
        XCTAssertEqual(provider.callCount, 0)
    }

    func testNonAskAgentToolIgnored() async {
        let provider = ScriptedProvider([
            .init(events: [.textDelta("x"), .done(.endTurn)])
        ])
        let box = ReplyBox()
        let bridge = makeBridge(provider: provider, registry: ToolRegistry()) { box.set($0) }

        await bridge.handleToolCall(.init(callId: "c5", name: "hang_up", arguments: "{}"))

        let got = await box.waitBriefly()
        XCTAssertNil(got)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testToolSpecsExposeExactlyTwoTools() {
        let names = Set(RealtimeBridgeSession.toolSpecs.map { $0.name })
        XCTAssertEqual(names, ["ask_agent", "hang_up"])
    }
}

/// 异步 reply 汇合点：桥的 reply 闭包在派出的 Task 里被调用，测试主体 await 它。
final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RealtimeBridgeSession.ToolReply?
    private var waiters: [CheckedContinuation<RealtimeBridgeSession.ToolReply, Never>] = []

    func set(_ r: RealtimeBridgeSession.ToolReply) {
        lock.lock()
        value = r
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pending { w.resume(returning: r) }
    }

    func wait() async -> RealtimeBridgeSession.ToolReply {
        await withCheckedContinuation { cont in
            lock.lock()
            if let v = value {
                lock.unlock()
                cont.resume(returning: v)
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func waitBriefly() async -> RealtimeBridgeSession.ToolReply? {
        try? await Task.sleep(nanoseconds: 200_000_000)
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
