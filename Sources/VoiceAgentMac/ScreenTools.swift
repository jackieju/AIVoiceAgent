import Foundation
import AppKit
import CoreGraphics
import VoiceAgentCore

public struct ScreenshotTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "screenshot",
            description: "Capture the current screen and return it as an image the model can see. Use to inspect what is on screen before clicking or typing.",
            inputSchema: [
                "type": "object",
                "properties": [:],
                "required": [],
            ]
        )
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        let tmp = NSTemporaryDirectory() + "aivoiceagent_shot_\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", tmp]
        do {
            try process.run()
        } catch {
            return .failure("screenshot: failed to launch screencapture: \(error.localizedDescription)")
        }
        while process.isRunning {
            if isCancelled() { process.terminate(); return .failure("screenshot: cancelled") }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard process.terminationStatus == 0, let data = FileManager.default.contents(atPath: tmp) else {
            return .failure("screenshot: capture failed (screen recording permission may be required)")
        }
        return .image(data.base64EncodedString(), note: "Screenshot captured (\(data.count) bytes)")
    }
}

public struct ScreenClickTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "screen_click",
            description: "Move the mouse to screen coordinates (x, y) and click. Origin is top-left.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "X coordinate in screen points (top-left origin)"],
                    "y": ["type": "number", "description": "Y coordinate in screen points (top-left origin)"],
                    "button": ["type": "string", "enum": ["left", "right"], "description": "Which mouse button (default left)"],
                ],
                "required": ["x", "y"],
            ]
        )
    }

    public var sideEffect: ToolSideEffect { .destructive }

    public func authorizationDescription(input: [String: Any]) -> String {
        let x = (input["x"] as? NSNumber)?.intValue ?? 0
        let y = (input["y"] as? NSNumber)?.intValue ?? 0
        return "screen_click: (\(x), \(y))"
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let x = (input["x"] as? NSNumber)?.doubleValue,
              let y = (input["y"] as? NSNumber)?.doubleValue else {
            return .failure("screen_click: missing required numeric parameters 'x' and 'y'")
        }
        let rightButton = (input["button"] as? String) == "right"
        let point = CGPoint(x: x, y: y)
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) = rightButton
            ? (.rightMouseDown, .rightMouseUp, .right)
            : (.leftMouseDown, .leftMouseUp, .left)

        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button),
              let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
            return .failure("screen_click: failed to create CGEvent (accessibility permission may be required)")
        }
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .ok("Clicked \(rightButton ? "right" : "left") at (\(Int(x)), \(Int(y)))")
    }
}

public struct ScreenTypeTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "screen_type",
            description: "Type text into the currently focused UI element via synthesized keystrokes.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The text to type"],
                ],
                "required": ["text"],
            ]
        )
    }

    public var sideEffect: ToolSideEffect { .destructive }

    public func authorizationDescription(input: [String: Any]) -> String {
        let text = (input["text"] as? String) ?? ""
        let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
        return "screen_type: \(preview)"
    }

    public func execute(input: [String: Any], isCancelled: @escaping () -> Bool) async -> ToolOutput {
        guard let text = input["text"] as? String, !text.isEmpty else {
            return .failure("screen_type: missing required parameter 'text'")
        }
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return .failure("screen_type: failed to create CGEvent (accessibility permission may be required)")
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .ok("Typed \(text.count) characters")
    }
}

public func makeScreenTools() -> [Tool] {
    [ScreenshotTool(), ScreenClickTool(), ScreenTypeTool()]
}
