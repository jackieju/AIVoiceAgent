import Foundation
import AppKit
import AVFoundation
import Speech
import VoiceAgentCore

// MARK: - Permission helpers

enum PermissionResult {
    case granted
    case micDenied
    case sttDenied
}

func requestPermissions(_ completion: @escaping (PermissionResult) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { micOK in
        guard micOK else {
            DispatchQueue.main.async { completion(.micDenied) }
            return
        }
        MacStt.requestAuthorization { sttOK in
            DispatchQueue.main.async {
                completion(sttOK ? .granted : .sttDenied)
            }
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var toggleButton: NSButton!

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var toggleMenuItem: NSMenuItem!
    private var showHideMenuItem: NSMenuItem!
    private var toolsWindowController: ToolsWindowController?
    private var settingsWindowController: SettingsWindowController?

    private var session: VoiceSession?
    private var nvpClient: NVPClient?
    private var registry: ToolRegistry?
    private var loadedConfig: AgentConfig?
    private var configPath: String = "~/.config/aivoiceagent/config.json"

    private var isRunning: Bool = false
    private var currentState: VoiceState = .idle

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainWindow()
        buildStatusItem()
        updateStateUI(.idle)

        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--config"), idx + 1 < args.count {
            configPath = args[idx + 1]
        }

        let config: AgentConfig
        do {
            config = try AgentConfig.load(from: configPath)
        } catch {
            showFatalAlert(
                title: "配置加载失败",
                message: "错误：\(error)\n\n预期配置路径：\(configPath)\n可通过 --config <路径> 指定其它文件。"
            )
            return
        }

        requestPermissions { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .micDenied:
                self.showFatalAlert(
                    title: "麦克风权限被拒绝",
                    message: "请前往 系统设置 > 隐私与安全性 > 麦克风，允许 AI Voice Agent 访问麦克风后重新打开应用。"
                )
            case .sttDenied:
                self.showFatalAlert(
                    title: "语音识别权限被拒绝",
                    message: "请前往 系统设置 > 隐私与安全性 > 语音识别，允许 AI Voice Agent 使用语音识别后重新打开应用。"
                )
            case .granted:
                self.setupSession(with: config)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: Window construction

    private func buildMainWindow() {
        let rect = NSRect(x: 0, y: 0, width: 520, height: 640)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Voice Agent"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: rect)
        content.autoresizingMask = [.width, .height]

        statusLabel = NSTextField(labelWithString: "闲置")
        statusLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        textView = tv
        scrollView.documentView = tv
        content.addSubview(scrollView)

        toggleButton = NSButton(title: "开始聆听", target: self, action: #selector(handleToggle))
        toggleButton.bezelStyle = .rounded
        toggleButton.controlSize = .large
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toggleButton)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -80),

            toggleButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 16),
            toggleButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Status bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "⏸️"

        let menu = NSMenu()
        showHideMenuItem = NSMenuItem(title: "显示/隐藏窗口", action: #selector(handleToggleWindow), keyEquivalent: "w")
        showHideMenuItem.target = self
        menu.addItem(showHideMenuItem)

        toggleMenuItem = NSMenuItem(title: "开始聆听", action: #selector(handleToggle), keyEquivalent: "s")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        let toolsMenuItem = NSMenuItem(title: "工具与 MCP…", action: #selector(handleShowTools), keyEquivalent: "t")
        toolsMenuItem.target = self
        menu.addItem(toolsMenuItem)

        let settingsMenuItem = NSMenuItem(title: "设置…", action: #selector(handleShowSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusMenu = menu
    }

    // MARK: Session setup

    private func setupSession(with config: AgentConfig, autoStart: Bool = true) {
        let audio = MacAudioIO()
        let selectedEngine = UserDefaults.standard.string(forKey: SettingsWindowController.ttsEngineKey)
        let tts = MacTts(audio: audio,
                         voiceLanguage: config.voice?.ttsVoice,
                         ttsEngine: selectedEngine ?? config.voice?.ttsEngine,
                         edgePythonPath: config.voice?.edgePythonPath,
                         edgeVoiceZh: config.voice?.edgeVoiceZh,
                         edgeVoiceEn: config.voice?.edgeVoiceEn)
        let stt = WhisperStt(inputSampleRate: audio.sampleRate)
        let vad = EnergyVad()
        let llm = makeProvider(from: config)

        var nvpClient: NVPClient?
        if config.nvp?.enabled ?? true {
            let defaultBinary = "~/Desktop/ju/projects/AIAgentLocalMemory/packages/server/dist/nvp-server"
            let defaultDB = "~/Library/Application Support/AIVoiceAgent/voice-memory.db"
            let rawDB = config.nvp?.dbPath ?? defaultDB
            let nvpConfig = NVPClient.Config(
                binaryPath: config.nvp?.binaryPath ?? defaultBinary,
                dbPath: (rawDB as NSString).expandingTildeInPath,
                projectId: config.nvp?.projectId ?? "voice"
            )
            let dbDir = (nvpConfig.dbPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
            let client = NVPClient(config: nvpConfig)
            client.start()
            nvpClient = client.isHealthy ? client : nil
        }
        self.nvpClient = nvpClient

        let registry = ToolRegistry(makeBuiltinTools(opencode: config.opencode) + makeScreenTools())
        self.registry = registry
        self.loadedConfig = config
        registry.setAuthorizer { [weak self] toolName, description in
            await self?.requestToolAuthorization(toolName: toolName, description: description) ?? false
        }
        if let mcpServers = config.mcpServers, !mcpServers.isEmpty {
            let serverConfigs = mcpServers.map { name, cfg in
                MCPServerConfig(name: name, command: cfg.command, args: cfg.args ?? [], env: cfg.env ?? [:])
            }
            Task {
                let (tools, _) = await connectMCPServers(serverConfigs)
                registry.registerAll(tools)
                let count = tools.count
                if count > 0 {
                    await MainActor.run { [weak self] in
                        self?.appendLine("已连接 \(count) 个 MCP 工具")
                    }
                }
            }
        }

        let session = VoiceSession(
            audio: audio, vad: vad, stt: stt, tts: tts, llm: llm,
            registry: registry,
            system: config.systemPrompt,
            maxRounds: config.maxRounds ?? 5,
            nvp: nvpClient,
            store: HistoryStore(path: "~/Library/Application Support/AIVoiceAgent/history.json")
        )
        session.onState = { [weak self] state in
            DispatchQueue.main.async { self?.updateStateUI(state) }
        }
        session.onUserText = { [weak self] text in
            DispatchQueue.main.async { self?.appendLine("👤 你：\(text)") }
        }
        session.onAgentText = { [weak self] text in
            DispatchQueue.main.async { self?.appendLine("🤖 助手：\(text)") }
        }
        session.onToolActivity = { [weak self] name in
            DispatchQueue.main.async { self?.appendLine("🛠️ 调用工具：\(name)") }
        }
        self.session = session

        appendLine("=== AI Voice Agent v\(VoiceAgent.version) ===")
        appendLine("model=\(config.model)  provider=\(config.provider.type)")
        appendLine("开始说话，停顿后自动提交。说话可打断助手。\n")

        replayHistory(session.loadedHistory)

        if autoStart { startListening() }
    }

    private func replayHistory(_ history: [ChatMessage]) {
        guard !history.isEmpty else { return }
        appendLine("—— 上次对话 ——")
        for msg in history {
            let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch msg.role {
            case .user:      appendLine("👤 你：\(text)")
            case .assistant: appendLine("🤖 助手：\(text)")
            }
        }
        appendLine("—— 继续对话 ——\n")
    }

    // MARK: UI updates

    private func updateStateUI(_ state: VoiceState) {
        currentState = state
        let label: String
        let icon: String
        switch state {
        case .idle:      label = "闲置";        icon = "⏸️"
        case .listening: label = "🎙️ 聆听中…"; icon = "🎙️"
        case .thinking:  label = "🤔 思考中…"; icon = "🤔"
        case .working:   label = "🛠️ 执行工具…"; icon = "🛠️"
        case .speaking:  label = "🔊 说话中…"; icon = "🔊"
        }
        statusLabel?.stringValue = label
        statusItem?.button?.title = isRunning ? icon : "⏸️"
    }

    private func appendLine(_ line: String) {
        guard let tv = textView else { return }
        let toAppend = (tv.string.isEmpty ? "" : "\n") + line
        let ts = tv.textStorage
        ts?.append(NSAttributedString(
            string: toAppend,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        tv.scrollToEndOfDocument(nil)
    }

    // MARK: Actions

    @objc private func handleToggle() {
        if isRunning {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        guard let session = session else { return }
        guard !isRunning else { return }
        do {
            try session.start()
            isRunning = true
            toggleButton?.title = "停止聆听"
            toggleMenuItem?.title = "停止聆听"
            updateStateUI(currentState)
        } catch {
            let alert = NSAlert()
            alert.messageText = "启动失败"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func stopListening() {
        guard let session = session else { return }
        guard isRunning else { return }
        session.stop()
        isRunning = false
        toggleButton?.title = "开始聆听"
        toggleMenuItem?.title = "开始聆听"
        updateStateUI(.idle)
    }

    @objc private func handleToggleWindow() {
        guard let window = window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func handleShowTools() {
        let controller: ToolsWindowController
        if let existing = toolsWindowController {
            existing.update(registry: registry, config: loadedConfig)
            controller = existing
        } else {
            let created = ToolsWindowController(registry: registry, config: loadedConfig)
            toolsWindowController = created
            controller = created
        }
        controller.show()
    }

    @objc private func handleShowSettings() {
        let controller: SettingsWindowController
        if let existing = settingsWindowController {
            controller = existing
        } else {
            let created = SettingsWindowController()
            created.onSave = { [weak self] in
                self?.reloadSessionFromSettings()
            }
            settingsWindowController = created
            controller = created
        }
        controller.show()
    }

    /// Destroys and rebuilds the session so new whisper language / TTS engine
    /// apply; the rebuilt session reloads conversation history from disk.
    private func reloadSessionFromSettings() {
        guard let config = loadedConfig else { return }
        let wasRunning = isRunning
        if isRunning { stopListening() }
        session = nil
        appendLine("\n—— 已应用新设置，重建会话 ——")
        setupSession(with: config, autoStart: wasRunning)
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: Alerts

    /// Hops from Core's background task to the main thread for a modal NSAlert,
    /// suspending the tool until the user responds. Denial feeds an error back to
    /// the model, not a crash.
    private func requestToolAuthorization(toolName: String, description: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "允许执行操作？"
                alert.informativeText = "AI 助手请求执行一个可能修改系统的操作：\n\n\(description)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "允许")
                alert.addButton(withTitle: "拒绝")
                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func showFatalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let args = CommandLine.arguments

if args.contains("--probe") {
    let probe = AECProbe()
    DispatchQueue.global().async { probe.run() }
    RunLoop.main.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
