import Foundation
import FlyingFox
import VoiceAgentCore

/// 路线B 的控制通道（/ws-realtime-control）。
///
/// 浏览器用 ephemeral key 直连 OpenAI Realtime 走 WebRTC 收发音频；当 Realtime
/// 模型触发 `ask_agent` / `hang_up` 这类 function_call 时，前端把
/// `function_call_arguments.done` 拦下，通过这条 WS 把调用转给后端的
/// `RealtimeBridgeSession`。桥跑完无状态 AgentLoop 后，经 `reply` 回写一条
/// `tool_reply` 帧；前端再把它包成 `function_call_output` + `response.create`
/// 回喂给 Realtime，让接待员用语音把结果说出来。
///
/// 与 ChatWSHandler 结构对称，但协议独立：
///   Inbound (browser -> server):
///     {"type":"function_call","call_id":"...","name":"ask_agent","arguments":"{...}"}
///     {"type":"cancel","call_id":"..."}                 打断某次委托
///   Outbound (server -> browser):
///     {"type":"tool_reply","call_id":"...","output":"..."}  委托结果
///     {"type":"ready"}                                   桥就绪
struct RealtimeControlWSHandler: WSMessageHandler {
    let makeAgent: @Sendable () -> AgentLoop

    func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        AsyncStream { continuation in
            let bridge = RealtimeBridgeSession(
                makeAgent: makeAgent,
                reply: { reply in
                    let obj: [String: Any] = [
                        "type": "tool_reply",
                        "call_id": reply.callId,
                        "output": reply.output,
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: obj),
                       let s = String(data: data, encoding: .utf8) {
                        continuation.yield(.text(s))
                    }
                }
            )

            continuation.yield(.text("{\"type\":\"ready\"}"))

            Task {
                for await message in client {
                    switch message {
                    case .text(let raw):
                        guard let frame = decodeControl(raw) else { continue }
                        switch frame {
                        case .functionCall(let callId, let name, let arguments):
                            await bridge.handleToolCall(
                                RealtimeBridgeSession.ToolCall(
                                    callId: callId, name: name, arguments: arguments
                                )
                            )
                        case .cancel(let callId):
                            await bridge.cancel(callId: callId)
                        }
                    case .data:
                        continue
                    case .close:
                        await bridge.cancelAll()
                        continuation.finish()
                    }
                }
                await bridge.cancelAll()
                continuation.finish()
            }
        }
    }
}

private enum ControlInbound {
    case functionCall(callId: String, name: String, arguments: String)
    case cancel(callId: String)
}

private func decodeControl(_ raw: String) -> ControlInbound? {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = obj["type"] as? String else { return nil }
    switch type {
    case "function_call":
        guard let callId = obj["call_id"] as? String,
              let name = obj["name"] as? String else { return nil }
        let arguments = (obj["arguments"] as? String) ?? "{}"
        return .functionCall(callId: callId, name: name, arguments: arguments)
    case "cancel":
        guard let callId = obj["call_id"] as? String else { return nil }
        return .cancel(callId: callId)
    default:
        return nil
    }
}
