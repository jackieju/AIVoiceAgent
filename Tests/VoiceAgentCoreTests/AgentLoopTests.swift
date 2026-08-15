import XCTest
@testable import VoiceAgentCore

final class ScriptedProvider: LLMProvider {
    struct Round {
        var events: [StreamEvent]
    }

    private var rounds: [Round]
    private let lock = NSLock()
    private(set) var callCount = 0
    private(set) var seenMessages: [[ChatMessage]] = []
    private(set) var seenToolSpecs: [[ToolSpec]] = []

    init(_ rounds: [Round]) {
        self.rounds = rounds
    }

    func streamEvents(messages: [ChatMessage], tools: [ToolSpec], system: String?) -> AsyncStream<StreamEvent> {
        lock.lock()
        callCount += 1
        seenMessages.append(messages)
        seenToolSpecs.append(tools)
        let round = rounds.isEmpty ? Round(events: [.done(.endTurn)]) : rounds.removeFirst()
        lock.unlock()
        return AsyncStream { continuation in
            for ev in round.events { continuation.yield(ev) }
            continuation.finish()
        }
    }
}

final class SpyTool: Tool {
    let name: String
    private let output: ToolOutput
    private let lock = NSLock()
    private(set) var inputs: [[String: Any]] = []
    private(set) var executed = 0

    init(name: String, output: ToolOutput) {
        self.name = name
        self.output = output
    }

    var spec: ToolSpec {
        ToolSpec(name: name, description: "spy", inputSchema: ["type": "object", "properties": [:]])
    }

    func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        lock.lock()
        inputs.append(input)
        executed += 1
        lock.unlock()
        return output
    }
}

final class RunCollector {
    var textDeltas: [String] = []
    var toolStarts: [String] = []
    var assistantMessages: [ChatMessage] = []
    var toolResultMessages: [ChatMessage] = []
    var doneReason: AgentDoneReason?

    var mergedText: String { textDeltas.joined() }
}

final class AgentLoopTests: XCTestCase {

    private func run(
        provider: LLMProvider,
        registry: ToolRegistry,
        history: [ChatMessage] = [ChatMessage(role: .user, text: "hi")],
        maxRounds: Int = 5,
        isCurrent: @escaping () -> Bool = { true }
    ) async -> RunCollector {
        let loop = AgentLoop(provider: provider, registry: registry, system: nil, maxRounds: maxRounds)
        let collector = RunCollector()
        await loop.run(
            history: history,
            isCurrent: isCurrent,
            onTextDelta: { collector.textDeltas.append($0) },
            onToolStart: { collector.toolStarts.append($0) },
            onAssistantMessage: { collector.assistantMessages.append($0) },
            onToolResultMessage: { collector.toolResultMessages.append($0) },
            onDone: { collector.doneReason = $0 }
        )
        return collector
    }

    func testPlainTextReplyEndsTurn() async {
        let provider = ScriptedProvider([
            .init(events: [.textDelta("你好"), .textDelta("，世界"), .done(.endTurn)])
        ])
        let c = await run(provider: provider, registry: ToolRegistry())

        XCTAssertEqual(c.mergedText, "你好，世界")
        XCTAssertEqual(c.assistantMessages.count, 1)
        XCTAssertTrue(c.toolResultMessages.isEmpty)
        XCTAssertTrue(c.toolStarts.isEmpty)
        guard case .endTurn = c.doneReason else { return XCTFail("expected endTurn, got \(String(describing: c.doneReason))") }
        XCTAssertEqual(provider.callCount, 1)
    }

    func testSingleToolRoundtrip() async {
        let tool = SpyTool(name: "read", output: .ok("file contents"))
        let registry = ToolRegistry([tool])
        let provider = ScriptedProvider([
            .init(events: [
                .textDelta("让我看看"),
                .toolUseComplete(id: "t1", name: "read", inputJSON: "{\"filePath\":\"/x\"}"),
                .done(.toolUse),
            ]),
            .init(events: [.textDelta("文件读好了"), .done(.endTurn)]),
        ])

        let c = await run(provider: provider, registry: registry)

        XCTAssertEqual(tool.executed, 1)
        XCTAssertEqual(tool.inputs.first?["filePath"] as? String, "/x")
        XCTAssertEqual(c.toolStarts, ["read"])
        XCTAssertEqual(c.assistantMessages.count, 2)
        XCTAssertEqual(c.toolResultMessages.count, 1)
        guard case .toolResult(let id, let content, let isErr, _)? = c.toolResultMessages.first?.content.first else {
            return XCTFail("expected tool_result block")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(content, "file contents")
        XCTAssertFalse(isErr)
        XCTAssertEqual(c.mergedText, "让我看看文件读好了")
        guard case .endTurn = c.doneReason else { return XCTFail("expected endTurn") }
        XCTAssertEqual(provider.callCount, 2)
        let secondCallMsgs = provider.seenMessages[1]
        XCTAssertTrue(secondCallMsgs.contains { m in
            m.content.contains { if case .toolResult = $0 { return true }; return false }
        })
    }

    func testMultipleToolsOrderedResults() async {
        let a = SpyTool(name: "alpha", output: .ok("A"))
        let b = SpyTool(name: "beta", output: .ok("B"))
        let registry = ToolRegistry([a, b])
        let provider = ScriptedProvider([
            .init(events: [
                .toolUseComplete(id: "id-a", name: "alpha", inputJSON: "{}"),
                .toolUseComplete(id: "id-b", name: "beta", inputJSON: "{}"),
                .done(.toolUse),
            ]),
            .init(events: [.textDelta("done"), .done(.endTurn)]),
        ])

        let c = await run(provider: provider, registry: registry)

        XCTAssertEqual(c.toolStarts, ["alpha", "beta"])
        let results = c.toolResultMessages.first?.content ?? []
        XCTAssertEqual(results.count, 2)
        guard case .toolResult(let id0, _, _, _) = results[0],
              case .toolResult(let id1, _, _, _) = results[1] else {
            return XCTFail("expected two tool_result blocks")
        }
        XCTAssertEqual(id0, "id-a")
        XCTAssertEqual(id1, "id-b")
    }

    func testCancellationStopsLoop() async {
        let alive = false
        let provider = ScriptedProvider([
            .init(events: [.textDelta("x"), .done(.endTurn)]),
        ])
        let c = await run(provider: provider, registry: ToolRegistry(), isCurrent: { alive })
        guard case .cancelled? = c.doneReason else {
            return XCTFail("expected cancelled, got \(String(describing: c.doneReason))")
        }
        XCTAssertTrue(c.assistantMessages.isEmpty)
    }

    func testMaxRoundsReached() async {
        let tool = SpyTool(name: "loopy", output: .ok("again"))
        let registry = ToolRegistry([tool])
        let rounds = (0..<10).map { _ in
            ScriptedProvider.Round(events: [
                .toolUseComplete(id: "t", name: "loopy", inputJSON: "{}"),
                .done(.toolUse),
            ])
        }
        let provider = ScriptedProvider(rounds)

        let c = await run(provider: provider, registry: registry, maxRounds: 3)

        guard case .maxRounds? = c.doneReason else {
            return XCTFail("expected maxRounds, got \(String(describing: c.doneReason))")
        }
        XCTAssertEqual(provider.callCount, 3)
        XCTAssertEqual(tool.executed, 3)
    }

    func testToolErrorFedBackAndContinues() async {
        let tool = SpyTool(name: "boom", output: .failure("kaboom"))
        let registry = ToolRegistry([tool])
        let provider = ScriptedProvider([
            .init(events: [
                .toolUseComplete(id: "t1", name: "boom", inputJSON: "{}"),
                .done(.toolUse),
            ]),
            .init(events: [.textDelta("recovered"), .done(.endTurn)]),
        ])

        let c = await run(provider: provider, registry: registry)

        guard case .toolResult(_, let content, let isErr, _)? = c.toolResultMessages.first?.content.first else {
            return XCTFail("expected tool_result block")
        }
        XCTAssertTrue(isErr)
        XCTAssertEqual(content, "kaboom")
        guard case .endTurn = c.doneReason else { return XCTFail("expected endTurn after recovery") }
        XCTAssertEqual(provider.callCount, 2)
    }

    func testUnknownToolReturnsFailure() async {
        let registry = ToolRegistry()
        let provider = ScriptedProvider([
            .init(events: [
                .toolUseComplete(id: "t1", name: "ghost", inputJSON: "{}"),
                .done(.toolUse),
            ]),
            .init(events: [.textDelta("ok"), .done(.endTurn)]),
        ])

        let c = await run(provider: provider, registry: registry)

        guard case .toolResult(_, let content, let isErr, _)? = c.toolResultMessages.first?.content.first else {
            return XCTFail("expected tool_result block")
        }
        XCTAssertTrue(isErr)
        XCTAssertTrue(content.contains("unknown tool"))
    }

    func testStreamErrorStopsLoop() async {
        struct Boom: Error {}
        let provider = ScriptedProvider([
            .init(events: [.textDelta("partial"), .error(Boom())])
        ])
        let c = await run(provider: provider, registry: ToolRegistry())
        guard case .error? = c.doneReason else {
            return XCTFail("expected error, got \(String(describing: c.doneReason))")
        }
        XCTAssertTrue(c.assistantMessages.isEmpty)
    }
}
