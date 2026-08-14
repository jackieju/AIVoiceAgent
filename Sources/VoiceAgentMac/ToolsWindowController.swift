import AppKit
import VoiceAgentCore

/// 只读的「工具与 MCP」窗口：左侧列表分两组显示已注册工具与已配置的 MCP 服务器，
/// 右侧展示所选项的详情。数据源在每次 show() 时重新从 ToolRegistry / AgentConfig
/// 拉取，因为 MCP 工具是异步注册的（app 启动后后台连接）。
final class ToolsWindowController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {

    // MARK: Data model

    private struct ToolEntry {
        let name: String
        let description: String
        let sideEffect: ToolSideEffect
    }

    private struct MCPEntry {
        let name: String
        let command: String
        let args: [String]
        let envKeys: [String]
    }

    private final class Group {
        let title: String
        var children: [Any] = []
        init(_ title: String) { self.title = title }
    }

    // MARK: State

    private let window: NSWindow
    private weak var registry: ToolRegistry?
    private var config: AgentConfig?

    private let toolsGroup = Group("工具")
    private let mcpGroup = Group("MCP 服务器")

    private var outlineView: NSOutlineView!
    private var detailContainer: NSView!

    // MARK: Init

    init(registry: ToolRegistry?, config: AgentConfig?) {
        self.registry = registry
        self.config = config

        let rect = NSRect(x: 0, y: 0, width: 720, height: 480)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "工具与 MCP"
        window.isReleasedWhenClosed = false
        window.center()

        super.init()
        window.delegate = self
        buildUI()
    }

    // MARK: Public API

    /// 更新数据源引用。菜单点击前调用，保证使用最新的 registry / config。
    func update(registry: ToolRegistry?, config: AgentConfig?) {
        self.registry = registry
        self.config = config
    }

    /// 从 registry / config 重新读取数据并刷新左列。
    func reload() {
        toolsGroup.children.removeAll()
        mcpGroup.children.removeAll()

        if let reg = registry {
            let specs = reg.specs.sorted { $0.name < $1.name }
            for spec in specs {
                let se = reg.sideEffect(of: spec.name)
                toolsGroup.children.append(
                    ToolEntry(name: spec.name, description: spec.description, sideEffect: se)
                )
            }
        }

        if let servers = config?.mcpServers {
            let sorted = servers.sorted { $0.key < $1.key }
            for (name, cfg) in sorted {
                let keys = (cfg.env ?? [:]).keys.sorted()
                mcpGroup.children.append(
                    MCPEntry(
                        name: name,
                        command: cfg.command,
                        args: cfg.args ?? [],
                        envKeys: keys
                    )
                )
            }
        }

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        showPlaceholder()
    }

    /// 打开或前置窗口。每次都先刷新数据。
    func show() {
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: UI construction

    private func buildUI() {
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        // 左：分组列表
        let leftScroll = NSScrollView()
        leftScroll.hasVerticalScroller = true
        leftScroll.hasHorizontalScroller = false
        leftScroll.autohidesScrollers = true
        leftScroll.borderType = .noBorder

        let outline = NSOutlineView()
        outline.headerView = nil
        outline.indentationPerLevel = 12
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.autoresizesOutlineColumn = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = 220
        col.minWidth = 120
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(handleSelection)
        outlineView = outline
        leftScroll.documentView = outline

        // 右：详情
        let detail = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer = detail

        split.addArrangedSubview(leftScroll)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window.contentView = content

        DispatchQueue.main.async { [weak split] in
            split?.setPosition(240, ofDividerAt: 0)
        }

        showPlaceholder()
    }

    // MARK: Detail views

    private func showPlaceholder() {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let text: String
        if registry == nil {
            text = "尚未初始化——完成权限授权后再打开此窗口。"
        } else {
            text = "在左侧选择一个工具或 MCP 服务器查看详情。"
        }
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: detailContainer.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor, constant: -20),
        ])
    }

    private func showToolDetail(_ tool: ToolEntry) {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: tool.name)
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let badge = makeBadge(sideEffect: tool.sideEffect)
        badge.translatesAutoresizingMaskIntoConstraints = false

        let descHeader = NSTextField(labelWithString: "描述")
        descHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        descHeader.textColor = .secondaryLabelColor
        descHeader.translatesAutoresizingMaskIntoConstraints = false

        let descScroll = NSScrollView()
        descScroll.hasVerticalScroller = true
        descScroll.hasHorizontalScroller = false
        descScroll.autohidesScrollers = true
        descScroll.borderType = .bezelBorder
        descScroll.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = tool.description.isEmpty ? "（无描述）" : tool.description
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        descScroll.documentView = tv

        detailContainer.addSubview(title)
        detailContainer.addSubview(badge)
        detailContainer.addSubview(descHeader)
        detailContainer.addSubview(descScroll)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),

            badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),

            descHeader.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
            descHeader.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),

            descScroll.topAnchor.constraint(equalTo: descHeader.bottomAnchor, constant: 6),
            descScroll.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            descScroll.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            descScroll.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -20),
        ])
    }

    private func showMCPDetail(_ mcp: MCPEntry) {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: mcp.name)
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let kind = NSTextField(labelWithString: "MCP 服务器")
        kind.font = NSFont.systemFont(ofSize: 12)
        kind.textColor = .secondaryLabelColor
        kind.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeField(header: "命令", value: mcp.command, monospace: true))
        stack.addArrangedSubview(
            makeField(
                header: "参数",
                value: mcp.args.isEmpty ? "（无）" : mcp.args.joined(separator: " "),
                monospace: true
            )
        )
        stack.addArrangedSubview(
            makeField(
                header: "环境变量（仅键名）",
                value: mcp.envKeys.isEmpty ? "（无）" : mcp.envKeys.joined(separator: ", "),
                monospace: true
            )
        )

        detailContainer.addSubview(title)
        detailContainer.addSubview(kind)
        detailContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),

            kind.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            kind.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),

            stack.topAnchor.constraint(equalTo: kind.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: detailContainer.bottomAnchor, constant: -20),
        ])
    }

    private func makeField(header: String, value: String, monospace: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let h = NSTextField(labelWithString: header)
        h.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        h.textColor = .secondaryLabelColor
        h.translatesAutoresizingMaskIntoConstraints = false

        let v = NSTextField(wrappingLabelWithString: value)
        v.font = monospace
            ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
        v.isSelectable = true
        v.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(h)
        container.addSubview(v)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: container.topAnchor),
            h.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            h.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            v.topAnchor.constraint(equalTo: h.bottomAnchor, constant: 4),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeBadge(sideEffect: ToolSideEffect) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false

        switch sideEffect {
        case .readOnly:
            label.stringValue = "只读"
            label.textColor = .white
            container.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .destructive:
            label.stringValue = "需授权"
            label.textColor = .white
            container.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])
        return container
    }

    // MARK: Actions

    @objc private func handleSelection() {
        let row = outlineView.selectedRow
        guard row >= 0 else {
            showPlaceholder()
            return
        }
        let item = outlineView.item(atRow: row)
        if let tool = item as? ToolEntry {
            showToolDetail(tool)
        } else if let mcp = item as? MCPEntry {
            showMCPDetail(mcp)
        } else {
            showPlaceholder()
        }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return 2 }
        if let g = item as? Group { return g.children.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return index == 0 ? toolsGroup : mcpGroup
        }
        if let g = item as? Group { return g.children[index] }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is Group
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return item is Group
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return !(item is Group)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let text: String
        let isGroup: Bool
        if let g = item as? Group {
            let countLabel = g.children.isEmpty ? "（空）" : "\(g.children.count)"
            text = "\(g.title)  \(countLabel)"
            isGroup = true
        } else if let t = item as? ToolEntry {
            text = t.name
            isGroup = false
        } else if let m = item as? MCPEntry {
            text = m.name
            isGroup = false
        } else {
            text = ""
            isGroup = false
        }

        let id = NSUserInterfaceItemIdentifier(isGroup ? "group" : "row")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.drawsBackground = false
            field.isBezeled = false
            field.isEditable = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        if isGroup {
            cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
        } else {
            cell.textField?.font = NSFont.systemFont(ofSize: 13)
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
