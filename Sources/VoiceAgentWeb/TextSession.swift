import Foundation
import VoiceAgentCore

/// Bridges one browser WebSocket connection to the shared AgentLoop.
///
/// Public API contract: `handle(text:)` starts a turn, `abort()` cancels the
/// in-flight reply. AgentLoop callbacks are translated to OutboundFrame and
/// pushed through `emit`. History is shared with the desktop app via the same
/// HistoryStore so both surfaces see one conversation.
final class TextSession {
    private let agent: AgentLoop
    private let store: HistoryStore?
    private let emit: (OutboundFrame) -> Void

    private var history: [ChatMessage]
    private var generation = 0
    private let lock = NSLock()

    init(agent: AgentLoop, store: HistoryStore?, emit: @escaping (OutboundFrame) -> Void) {
        self.agent = agent
        self.store = store
        self.emit = emit
        self.history = store?.load() ?? []
    }

    var loadedHistory: [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return history
    }

    func abort() {
        lock.lock(); generation += 1; lock.unlock()
        emit(.state("idle"))
    }

    func handle(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        generation += 1
        let myGen = generation
        history.append(ChatMessage(role: .user, text: trimmed))
        let snapshot = history
        lock.unlock()

        emit(.state("thinking"))

        Task {
            await agent.run(
                history: snapshot,
                isCurrent: { [weak self] in
                    guard let self = self else { return false }
                    self.lock.lock(); defer { self.lock.unlock() }
                    return self.generation == myGen
                },
                onTextDelta: { [weak self] delta in
                    self?.emit(.textDelta(delta))
                },
                onToolStart: { [weak self] name in
                    self?.emit(.state("working"))
                    self?.emit(.toolStart(name: name))
                },
                onAssistantMessage: { [weak self] msg in
                    guard let self = self else { return }
                    self.lock.lock(); self.history.append(msg); let snap = self.history; self.lock.unlock()
                    let prose = msg.text
                    if !prose.isEmpty { self.emit(.assistantMessage(text: prose)) }
                    self.store?.save(snap)
                },
                onToolResultMessage: { [weak self] msg in
                    guard let self = self else { return }
                    self.lock.lock(); self.history.append(msg); let snap = self.history; self.lock.unlock()
                    self.store?.save(snap)
                },
                onDone: { [weak self] reason in
                    guard let self = self else { return }
                    switch reason {
                    case .error(let e):
                        self.emit(.error(message: "\(e)"))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                    self.emit(.done(reason: Self.reasonString(reason)))
                    self.emit(.state("idle"))
                }
            )
        }
    }

    private static func reasonString(_ r: AgentDoneReason) -> String {
        switch r {
        case .endTurn: return "endTurn"
        case .maxRounds: return "maxRounds"
        case .cancelled: return "cancelled"
        case .error: return "error"
        }
    }
}
