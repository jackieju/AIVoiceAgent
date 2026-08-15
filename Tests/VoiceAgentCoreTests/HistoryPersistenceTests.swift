import XCTest
@testable import VoiceAgentCore

final class HistoryPersistenceTests: XCTestCase {

    func testTextRoundTrip() throws {
        let msgs = [
            ChatMessage(role: .user, text: "你好"),
            ChatMessage(role: .assistant, text: "你好，有什么可以帮你？"),
        ]
        let data = try JSONEncoder().encode(msgs)
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].role, .user)
        XCTAssertEqual(decoded[0].text, "你好")
        XCTAssertEqual(decoded[1].role, .assistant)
        XCTAssertEqual(decoded[1].text, "你好，有什么可以帮你？")
    }

    func testToolUseInputSurvivesJSONBridge() throws {
        let input: [String: Any] = ["command": "ls -la", "timeout": 5000]
        let msg = ChatMessage(role: .assistant, content: [
            .toolUse(id: "tu_1", name: "bash", input: input)
        ])
        let data = try JSONEncoder().encode([msg])
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: data)
        guard case .toolUse(let id, let name, let restored) = decoded[0].content[0] else {
            return XCTFail("expected toolUse block")
        }
        XCTAssertEqual(id, "tu_1")
        XCTAssertEqual(name, "bash")
        XCTAssertEqual(restored["command"] as? String, "ls -la")
        XCTAssertEqual(restored["timeout"] as? Int, 5000)
    }

    func testToolResultImageIsDropped() throws {
        let msg = ChatMessage(role: .user, content: [
            .toolResult(toolUseId: "tu_1", content: "done", isError: false, imageBase64: "AAAA")
        ])
        let data = try JSONEncoder().encode([msg])
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: data)
        guard case .toolResult(let toolUseId, let content, let isError, let img) = decoded[0].content[0] else {
            return XCTFail("expected toolResult block")
        }
        XCTAssertEqual(toolUseId, "tu_1")
        XCTAssertEqual(content, "done")
        XCTAssertFalse(isError)
        XCTAssertNil(img)
    }

    func testStoreSaveThenLoad() throws {
        let path = NSTemporaryDirectory() + "voiceagent-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HistoryStore(path: path)

        XCTAssertTrue(store.load().isEmpty)

        let msgs = [
            ChatMessage(role: .user, text: "记住我叫阿明"),
            ChatMessage(role: .assistant, text: "好的，阿明。"),
        ]
        store.save(msgs)

        let expectation = XCTestExpectation(description: "async save flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].text, "记住我叫阿明")
        XCTAssertEqual(loaded[1].text, "好的，阿明。")
    }

    func testCorruptFileYieldsEmpty() throws {
        let path = NSTemporaryDirectory() + "voiceagent-corrupt-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "{ not valid json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = HistoryStore(path: path)
        XCTAssertTrue(store.load().isEmpty)
    }
}
