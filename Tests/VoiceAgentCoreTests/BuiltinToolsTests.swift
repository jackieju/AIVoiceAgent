import XCTest
@testable import VoiceAgentCore

final class BuiltinToolsTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "aivoiceagent-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    func testWriteThenRead() async {
        let path = tmp + "/hello.txt"
        let w = await WriteTool().execute(input: ["filePath": path, "content": "line1\nline2\nline3"], isCancelled: { false })
        XCTAssertFalse(w.isError, w.content)

        let r = await ReadTool().execute(input: ["filePath": path], isCancelled: { false })
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.content, "1: line1\n2: line2\n3: line3")
    }

    func testReadWithOffsetLimit() async {
        let path = tmp + "/nums.txt"
        _ = await WriteTool().execute(input: ["filePath": path, "content": "a\nb\nc\nd\ne"], isCancelled: { false })
        let r = await ReadTool().execute(input: ["filePath": path, "offset": 2, "limit": 2], isCancelled: { false })
        XCTAssertEqual(r.content, "2: b\n3: c")
    }

    func testReadMissingFileIsError() async {
        let r = await ReadTool().execute(input: ["filePath": tmp + "/nope.txt"], isCancelled: { false })
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.contains("not found"))
    }

    func testReadMissingParamIsError() async {
        let r = await ReadTool().execute(input: [:], isCancelled: { false })
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.contains("filePath"))
    }

    func testReadDirectoryListsEntries() async {
        _ = await WriteTool().execute(input: ["filePath": tmp + "/a.txt", "content": "x"], isCancelled: { false })
        try? FileManager.default.createDirectory(atPath: tmp + "/sub", withIntermediateDirectories: true)
        let r = await ReadTool().execute(input: ["filePath": tmp!], isCancelled: { false })
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.content.contains("a.txt"))
        XCTAssertTrue(r.content.contains("sub/"))
    }

    func testBashEchoesStdout() async {
        let r = await BashTool().execute(input: ["command": "echo AIVA_MARKER_42"], isCancelled: { false })
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.content.contains("AIVA_MARKER_42"))
    }

    func testBashNonZeroExitReportsStatus() async {
        let r = await BashTool().execute(input: ["command": "exit 3"], isCancelled: { false })
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.content.contains("exit 3"))
    }

    func testBashWorkdir() async {
        let r = await BashTool().execute(input: ["command": "pwd", "workdir": tmp!], isCancelled: { false })
        XCTAssertTrue(r.content.contains(tmp.components(separatedBy: "/").last!))
    }

    func testBashMissingCommandIsError() async {
        let r = await BashTool().execute(input: [:], isCancelled: { false })
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.contains("command"))
    }

    func testGrepFindsMatch() async throws {
        guard rgAvailable() else { throw XCTSkip("ripgrep not installed") }
        _ = await WriteTool().execute(input: ["filePath": tmp + "/f.txt", "content": "alpha\nNEEDLE here\nbeta"], isCancelled: { false })
        let r = await GrepTool().execute(input: ["pattern": "NEEDLE", "path": tmp!], isCancelled: { false })
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.content.contains("NEEDLE"))
        XCTAssertTrue(r.content.contains("Found 1 matches"))
    }

    func testGrepNoMatch() async throws {
        guard rgAvailable() else { throw XCTSkip("ripgrep not installed") }
        _ = await WriteTool().execute(input: ["filePath": tmp + "/f.txt", "content": "alpha\nbeta"], isCancelled: { false })
        let r = await GrepTool().execute(input: ["pattern": "ZZZZ", "path": tmp!], isCancelled: { false })
        XCTAssertEqual(r.content, "No matches found")
    }

    func testGlobFindsFiles() async throws {
        guard rgAvailable() else { throw XCTSkip("ripgrep not installed") }
        _ = await WriteTool().execute(input: ["filePath": tmp + "/x.swift", "content": "x"], isCancelled: { false })
        _ = await WriteTool().execute(input: ["filePath": tmp + "/y.txt", "content": "y"], isCancelled: { false })
        let r = await GlobTool().execute(input: ["pattern": "*.swift", "path": tmp!], isCancelled: { false })
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.content.contains("x.swift"))
        XCTAssertFalse(r.content.contains("y.txt"))
    }

    private func rgAvailable() -> Bool {
        ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
