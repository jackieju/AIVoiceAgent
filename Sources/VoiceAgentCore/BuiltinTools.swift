import Foundation

public struct ReadTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "read",
            description: "Read a file from the local filesystem. Output lines are prefixed with '<line>: '. Supports offset/limit for large files.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "filePath": ["type": "string", "description": "The absolute path to the file to read"],
                    "offset": ["type": "number", "description": "The line number to start reading from (1-indexed)"],
                    "limit": ["type": "number", "description": "The maximum number of lines to read (defaults to 2000)"],
                ],
                "required": ["filePath"],
            ]
        )
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let filePath = input["filePath"] as? String, !filePath.isEmpty else {
            return .failure("read: missing required parameter 'filePath'")
        }
        let offset = (input["offset"] as? NSNumber)?.intValue ?? 0
        let limit = (input["limit"] as? NSNumber)?.intValue ?? 2000

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return .failure("read: file not found: \(filePath)")
        }
        if isDir.boolValue {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: filePath) else {
                return .failure("read: cannot list directory: \(filePath)")
            }
            let lines = entries.sorted().map { name -> String in
                var sub: ObjCBool = false
                let full = (filePath as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: full, isDirectory: &sub)
                return sub.boolValue ? name + "/" : name
            }
            return .ok(lines.joined(separator: "\n"))
        }

        guard let raw = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return .failure("read: cannot read file as UTF-8: \(filePath)")
        }
        let allLines = raw.components(separatedBy: "\n")
        let start = offset > 0 ? offset - 1 : 0
        guard start < allLines.count else {
            return .ok("")
        }
        let end = min(start + limit, allLines.count)
        let maxLineLen = 2000
        var out: [String] = []
        for i in start..<end {
            var line = allLines[i]
            if line.count > maxLineLen {
                line = String(line.prefix(maxLineLen)) + "... (line truncated to \(maxLineLen) chars)"
            }
            out.append("\(i + 1): \(line)")
        }
        return .ok(out.joined(separator: "\n"))
    }
}

public struct WriteTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "write",
            description: "Write content to a file, overwriting if it exists. If editing an existing file, read it first.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "filePath": ["type": "string", "description": "The absolute path to the file to write (must be absolute, not relative)"],
                    "content": ["type": "string", "description": "The content to write to the file"],
                ],
                "required": ["filePath", "content"],
            ]
        )
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let filePath = input["filePath"] as? String, !filePath.isEmpty else {
            return .failure("write: missing required parameter 'filePath'")
        }
        guard let content = input["content"] as? String else {
            return .failure("write: missing required parameter 'content'")
        }
        let dir = (filePath as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return .ok("Wrote \(content.utf8.count) bytes to \(filePath)")
        } catch {
            return .failure("write: \(error.localizedDescription)")
        }
    }
}

public struct BashTool: Tool {
    private let defaultTimeoutMs: Int
    public init(defaultTimeoutMs: Int = 120_000) {
        self.defaultTimeoutMs = defaultTimeoutMs
    }
    public var spec: ToolSpec {
        ToolSpec(
            name: "bash",
            description: "Execute a shell command. Use 'workdir' instead of 'cd'. Prefer the dedicated read/grep/glob tools over cat/grep/find.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The command to execute"],
                    "timeout": ["type": "number", "description": "Optional timeout in milliseconds"],
                    "workdir": ["type": "string", "description": "The working directory to run the command in. Defaults to the current directory. Use this instead of 'cd' commands."],
                ],
                "required": ["command"],
            ]
        )
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let command = input["command"] as? String, !command.isEmpty else {
            return .failure("bash: missing required parameter 'command'")
        }
        let timeoutMs = (input["timeout"] as? NSNumber)?.intValue ?? defaultTimeoutMs
        let workdir = input["workdir"] as? String

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        if let workdir, !workdir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workdir)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return .failure("bash: failed to launch: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                return .failure("bash: cancelled")
            }
            if Date() > deadline {
                process.terminate()
                return .failure("bash: timed out after \(timeoutMs)ms")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let maxBytes = 30_000
        let clipped = output.utf8.count > maxBytes
            ? String(output.prefix(maxBytes)) + "\n... (output truncated at \(maxBytes) bytes)"
            : output
        if process.terminationStatus != 0 {
            return .ok("(exit \(process.terminationStatus))\n" + clipped)
        }
        return .ok(clipped)
    }
}
