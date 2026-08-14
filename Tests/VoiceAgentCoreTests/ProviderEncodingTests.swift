import XCTest
@testable import VoiceAgentCore

final class ProviderEncodingTests: XCTestCase {

    func testAnthropicEncodesTextMessage() {
        let m = ChatMessage(role: .user, text: "hi")
        let enc = AnthropicProvider.encodeMessage(m)
        XCTAssertEqual(enc["role"] as? String, "user")
        let blocks = enc["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertEqual(blocks?.first?["type"] as? String, "text")
        XCTAssertEqual(blocks?.first?["text"] as? String, "hi")
    }

    func testAnthropicEncodesToolUseAndResult() {
        let m = ChatMessage(role: .assistant, content: [
            .text("calling"),
            .toolUse(id: "t1", name: "read", input: ["filePath": "/x"]),
        ])
        let enc = AnthropicProvider.encodeMessage(m)
        let blocks = enc["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 2)
        XCTAssertEqual(blocks?[1]["type"] as? String, "tool_use")
        XCTAssertEqual(blocks?[1]["id"] as? String, "t1")
        XCTAssertEqual(blocks?[1]["name"] as? String, "read")

        let r = ChatMessage(role: .user, content: [
            .toolResult(toolUseId: "t1", content: "data", isError: false),
        ])
        let rEnc = AnthropicProvider.encodeMessage(r)
        let rBlocks = rEnc["content"] as? [[String: Any]]
        XCTAssertEqual(rBlocks?.first?["type"] as? String, "tool_result")
        XCTAssertEqual(rBlocks?.first?["tool_use_id"] as? String, "t1")
        XCTAssertEqual(rBlocks?.first?["is_error"] as? Bool, false)
    }

    func testOpenAISplitsToolResultIntoSeparateMessage() {
        let m = ChatMessage(role: .assistant, content: [
            .text("calling"),
            .toolUse(id: "t1", name: "read", input: ["filePath": "/x"]),
        ])
        let out = OpenAICompatibleProvider.encodeMessages(m)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["role"] as? String, "assistant")
        let calls = out[0]["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(calls?.count, 1)
        XCTAssertEqual(calls?.first?["id"] as? String, "t1")
        let fn = calls?.first?["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "read")
    }

    func testOpenAIToolResultBecomesToolRole() {
        let m = ChatMessage(role: .user, content: [
            .toolResult(toolUseId: "t1", content: "data", isError: false),
        ])
        let out = OpenAICompatibleProvider.encodeMessages(m)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["role"] as? String, "tool")
        XCTAssertEqual(out[0]["tool_call_id"] as? String, "t1")
        XCTAssertEqual(out[0]["content"] as? String, "data")
    }

    func testChatMessageTextIgnoresNonTextBlocks() {
        let m = ChatMessage(role: .assistant, content: [
            .text("hello "),
            .toolUse(id: "t1", name: "x", input: [:]),
            .text("world"),
        ])
        XCTAssertEqual(m.text, "hello world")
    }
}
