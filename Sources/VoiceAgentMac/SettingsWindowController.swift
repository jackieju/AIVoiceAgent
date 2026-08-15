import AppKit
import VoiceAgentCore

final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let languagesKey = "selectedLanguages"
    static let ttsEngineKey = "ttsEngine"

    private let languageCodes = ["zh", "en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "ar", "hi", "th", "vi"]
    private let languageNames = ["中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Italiano", "Português", "Русский", "العربية", "हिन्दी", "ไทย", "Tiếng Việt"]

    private let window: NSWindow
    private var languageCheckboxes: [NSButton] = []
    private var edgeRadio: NSButton!
    private var systemRadio: NSButton!

    var onSave: (() -> Void)?

    override init() {
        let rect = NSRect(x: 0, y: 0, width: 460, height: 560)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        window.delegate = self
        buildUI()
    }

    func show() {
        loadFromDefaults()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        let content = NSView(frame: window.contentView?.bounds ?? .zero)

        let langTitle = NSTextField(labelWithString: "识别语言（whisper）")
        langTitle.font = NSFont.boldSystemFont(ofSize: 13)
        langTitle.frame = NSRect(x: 20, y: 520, width: 420, height: 20)
        content.addSubview(langTitle)

        let langHint = NSTextField(labelWithString: "选一个 = 锁定该语言；多选或不选 = 自动检测。")
        langHint.font = NSFont.systemFont(ofSize: 11)
        langHint.textColor = .secondaryLabelColor
        langHint.frame = NSRect(x: 20, y: 500, width: 420, height: 16)
        content.addSubview(langHint)

        let langScroll = NSScrollView(frame: NSRect(x: 20, y: 270, width: 420, height: 220))
        langScroll.hasVerticalScroller = true
        langScroll.borderType = .bezelBorder
        langScroll.autohidesScrollers = true

        let rowHeight: CGFloat = 26
        let listHeight = CGFloat(languageCodes.count) * rowHeight
        let langList = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: listHeight))
        for (i, name) in languageNames.enumerated() {
            let cb = NSButton(checkboxWithTitle: name, target: self, action: #selector(languageToggled(_:)))
            cb.tag = i
            cb.frame = NSRect(x: 8, y: listHeight - CGFloat(i + 1) * rowHeight, width: 380, height: rowHeight - 4)
            langList.addSubview(cb)
            languageCheckboxes.append(cb)
        }
        langScroll.documentView = langList
        content.addSubview(langScroll)

        let ttsTitle = NSTextField(labelWithString: "语音输出引擎（TTS）")
        ttsTitle.font = NSFont.boldSystemFont(ofSize: 13)
        ttsTitle.frame = NSRect(x: 20, y: 230, width: 420, height: 20)
        content.addSubview(ttsTitle)

        edgeRadio = NSButton(radioButtonWithTitle: "微软 Edge（在线，音质更自然）", target: self, action: #selector(engineToggled(_:)))
        edgeRadio.frame = NSRect(x: 20, y: 200, width: 420, height: 22)
        content.addSubview(edgeRadio)

        systemRadio = NSButton(radioButtonWithTitle: "本地系统（离线，无需联网）", target: self, action: #selector(engineToggled(_:)))
        systemRadio.frame = NSRect(x: 20, y: 174, width: 420, height: 22)
        content.addSubview(systemRadio)

        let note = NSTextField(wrappingLabelWithString: "保存后会用新设置重启对话会话（历史对话保留）。")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 110, width: 420, height: 40)
        content.addSubview(note)

        let saveButton = NSButton(title: "保存并应用", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 320, y: 20, width: 120, height: 32)
        content.addSubview(saveButton)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 210, y: 20, width: 100, height: 32)
        content.addSubview(cancelButton)

        window.contentView = content
    }

    private func loadFromDefaults() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.languagesKey) ?? []
        for (i, code) in languageCodes.enumerated() {
            languageCheckboxes[i].state = saved.contains(code) ? .on : .off
        }
        let engine = UserDefaults.standard.string(forKey: Self.ttsEngineKey) ?? "edge"
        edgeRadio.state = (engine == "edge") ? .on : .off
        systemRadio.state = (engine == "system") ? .on : .off
    }

    @objc private func languageToggled(_ sender: NSButton) {}

    @objc private func engineToggled(_ sender: NSButton) {}

    @objc private func saveTapped() {
        var selected: [String] = []
        for (i, cb) in languageCheckboxes.enumerated() where cb.state == .on {
            selected.append(languageCodes[i])
        }
        UserDefaults.standard.set(selected, forKey: Self.languagesKey)
        let engine = systemRadio.state == .on ? "system" : "edge"
        UserDefaults.standard.set(engine, forKey: Self.ttsEngineKey)
        window.orderOut(nil)
        onSave?()
    }

    @objc private func cancelTapped() {
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
