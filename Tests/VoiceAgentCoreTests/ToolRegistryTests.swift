import XCTest
@testable import VoiceAgentCore

final class ToolRegistryTests: XCTestCase {

    func testExecuteRegisteredTool() async {
        let tool = SpyTool(name: "read", output: .ok("hello"))
        let registry = ToolRegistry([tool])
        let out = await registry.execute(name: "read", input: [:], isCancelled: { false })
        XCTAssertEqual(out.content, "hello")
        XCTAssertFalse(out.isError)
        XCTAssertEqual(tool.executed, 1)
    }

    func testUnknownToolReturnsFailure() async {
        let registry = ToolRegistry()
        let out = await registry.execute(name: "nope", input: [:], isCancelled: { false })
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.content.contains("unknown tool"))
        XCTAssertTrue(out.content.contains("nope"))
    }

    func testLateRegistrationVisibleToSpecs() {
        let registry = ToolRegistry()
        XCTAssertTrue(registry.isEmpty)
        registry.register(SpyTool(name: "late", output: .ok("x")))
        XCTAssertFalse(registry.isEmpty)
        XCTAssertEqual(registry.specs.map { $0.name }, ["late"])
    }

    func testRegisterAllReplacesByName() {
        let registry = ToolRegistry([SpyTool(name: "dup", output: .ok("v1"))])
        registry.registerAll([SpyTool(name: "dup", output: .ok("v2"))])
        XCTAssertEqual(registry.specs.count, 1)
    }

    func testBuiltinToolNamesMatchOpencode() {
        let registry = ToolRegistry([
            ReadTool(), WriteTool(), BashTool(),
        ])
        let names = Set(registry.specs.map { $0.name })
        XCTAssertEqual(names, ["read", "write", "bash"])
    }
}
