import Foundation
import FlyingFox
import VoiceAgentCore

struct ChatWSHandler: WSMessageHandler {
    let makeAgent: @Sendable () -> AgentLoop
    let store: HistoryStore?

    func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        AsyncStream { continuation in
            let session = TextSession(
                agent: makeAgent(),
                store: store,
                emit: { frame in continuation.yield(.text(frame.encode())) }
            )

            for msg in session.loadedHistory {
                let role = msg.role == .user ? "user" : "assistant"
                let prose = msg.text
                if prose.isEmpty { continue }
                let obj: [String: Any] = ["type": "history", "role": role, "text": prose]
                if let data = try? JSONSerialization.data(withJSONObject: obj),
                   let s = String(data: data, encoding: .utf8) {
                    continuation.yield(.text(s))
                }
            }
            continuation.yield(.text(OutboundFrame.state("idle").encode()))

            Task {
                for await message in client {
                    switch message {
                    case .text(let raw):
                        guard let frame = InboundFrame.decode(raw) else { continue }
                        switch frame {
                        case .chatSend(let text): session.handle(text: text)
                        case .abort: session.abort()
                        }
                    case .data:
                        continue
                    case .close:
                        session.abort()
                        continuation.finish()
                    }
                }
                continuation.finish()
            }
        }
    }
}
