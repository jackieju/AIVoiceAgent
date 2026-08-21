import Foundation

/// WebSocket wire protocol between the browser Dashboard and the Swift backend.
///
/// Frame shape mirrors OpenVoiceUI's proven design (`chat.send` in, `text_delta`
/// / `assistant_message` out) but uses a clean tagged-JSON envelope so both
/// directions decode with a single `type` switch.
///
/// Inbound (browser -> server):
///   {"type":"chat.send","text":"..."}         user turn
///   {"type":"abort"}                            cancel the in-flight reply (barge-in)
///
/// Outbound (server -> browser):
///   {"type":"state","state":"thinking"}        state machine transitions
///   {"type":"text_delta","text":"..."}         streamed assistant prose (feeds TTS)
///   {"type":"tool_start","name":"bash"}         a tool began (must NOT be spoken)
///   {"type":"assistant_message","text":"..."}   full assistant turn (final)
///   {"type":"done","reason":"endTurn"}          turn finished
///   {"type":"error","message":"..."}            fatal error for this turn

enum InboundFrame {
    case chatSend(text: String)
    case abort

    static func decode(_ raw: String) -> InboundFrame? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "chat.send":
            guard let text = obj["text"] as? String else { return nil }
            return .chatSend(text: text)
        case "abort":
            return .abort
        default:
            return nil
        }
    }
}

enum OutboundFrame {
    case state(String)
    case textDelta(String)
    case toolStart(name: String)
    case assistantMessage(text: String)
    case done(reason: String)
    case error(message: String)

    func encode() -> String {
        let obj: [String: Any]
        switch self {
        case .state(let s):
            obj = ["type": "state", "state": s]
        case .textDelta(let t):
            obj = ["type": "text_delta", "text": t]
        case .toolStart(let name):
            obj = ["type": "tool_start", "name": name]
        case .assistantMessage(let text):
            obj = ["type": "assistant_message", "text": text]
        case .done(let reason):
            obj = ["type": "done", "reason": reason]
        case .error(let message):
            obj = ["type": "error", "message": message]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"type\":\"error\",\"message\":\"encode failed\"}"
        }
        return s
    }
}
