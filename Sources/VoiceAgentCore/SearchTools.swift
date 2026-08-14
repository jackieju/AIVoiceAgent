import Foundation

private func resolveRipgrep() -> String? {
    for p in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"] {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

private func runProcess(_ launchPath: String, _ args: [String], cwd: String?, isCancelled: @escaping () -> Bool) async -> (status: Int32, out: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    while process.isRunning {
        if isCancelled() { process.terminate(); return (status: -1, out: "") }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (status: process.terminationStatus, out: String(data: data, encoding: .utf8) ?? "")
}

public struct GrepTool: Tool {
    private let limit = 100
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "grep",
            description: "Search file contents with a regex pattern. Returns matching lines grouped by file.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "The regex pattern to search for in file contents"],
                    "path": ["type": "string", "description": "The directory to search in. Defaults to the current working directory."],
                    "include": ["type": "string", "description": "File pattern to include in the search (e.g. \"*.js\", \"*.{ts,tsx}\")"],
                ],
                "required": ["pattern"],
            ]
        )
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let pattern = input["pattern"] as? String, !pattern.isEmpty else {
            return .failure("grep: missing required parameter 'pattern'")
        }
        let searchPath = (input["path"] as? String) ?? FileManager.default.currentDirectoryPath
        let include = input["include"] as? String

        guard let rg = resolveRipgrep() else {
            return .failure("grep: ripgrep (rg) not found; install via 'brew install ripgrep'")
        }
        var args = ["--line-number", "--no-heading", "--color", "never", "-e", pattern]
        if let include { args += ["--glob", include] }
        args.append(searchPath)

        guard let result = await runProcess(rg, args, cwd: nil, isCancelled: isCancelled) else {
            return .failure("grep: failed to launch ripgrep")
        }
        if result.status == -1 { return .failure("grep: cancelled") }
        if result.out.isEmpty { return .ok("No matches found") }

        var byFile: [(file: String, line: Int, text: String)] = []
        for row in result.out.components(separatedBy: "\n") where !row.isEmpty {
            let parts = row.components(separatedBy: ":")
            guard parts.count >= 3, let lineNo = Int(parts[1]) else { continue }
            let file = parts[0]
            let text = parts[2...].joined(separator: ":")
            byFile.append((file: file, line: lineNo, text: text))
        }
        let truncated = byFile.count > limit
        if truncated { byFile = Array(byFile.prefix(limit)) }

        var grouped: [String: [(Int, String)]] = [:]
        var order: [String] = []
        for m in byFile {
            if grouped[m.file] == nil { order.append(m.file) }
            grouped[m.file, default: []].append((m.line, m.text))
        }
        var out = "Found \(byFile.count) matches\(truncated ? " (more matches available)" : "")\n"
        for file in order {
            out += "\n\(file):\n"
            for (lineNo, text) in grouped[file] ?? [] {
                out += "  Line \(lineNo): \(text)\n"
            }
        }
        if truncated {
            out += "\n(Results truncated. Consider using a more specific path or pattern.)"
        }
        return .ok(out)
    }
}

public struct GlobTool: Tool {
    private let limit = 100
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "glob",
            description: "Find files matching a glob pattern (e.g. \"**/*.swift\"). Returns absolute paths.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "The glob pattern to match files against"],
                    "path": ["type": "string", "description": "The directory to search in. If not specified, the current working directory will be used. IMPORTANT: Omit this field to use the default directory. DO NOT enter \"undefined\" or \"null\" - simply omit it for the default behavior. Must be a valid directory path if provided."],
                ],
                "required": ["pattern"],
            ]
        )
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let pattern = input["pattern"] as? String, !pattern.isEmpty else {
            return .failure("glob: missing required parameter 'pattern'")
        }
        let searchPath = (input["path"] as? String) ?? FileManager.default.currentDirectoryPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchPath, isDirectory: &isDir), isDir.boolValue else {
            return .failure("glob: path must be a directory: \(searchPath)")
        }

        guard let rg = resolveRipgrep() else {
            return .failure("glob: ripgrep (rg) not found; install via 'brew install ripgrep'")
        }
        let args = ["--files", "--glob", pattern, searchPath]
        guard let result = await runProcess(rg, args, cwd: nil, isCancelled: isCancelled) else {
            return .failure("glob: failed to launch ripgrep")
        }
        if result.status == -1 { return .failure("glob: cancelled") }

        var files = result.out.components(separatedBy: "\n").filter { !$0.isEmpty }
        if files.isEmpty { return .ok("No files found") }
        let truncated = files.count > limit
        if truncated { files = Array(files.prefix(limit)) }
        var out = files.joined(separator: "\n")
        if truncated {
            out += "\n\n(Results are truncated: showing first \(limit) results. Consider using a more specific path or pattern.)"
        }
        return .ok(out)
    }
}
