import Foundation

public enum VoiceState: String {
    case idle
    case listening
    case thinking
    case working
    case speaking
}

/// Drives the full-duplex conversation loop: VAD gates speech, STT transcribes,
/// LLM streams a reply that is sentence-chunked into TTS as it arrives, and a
/// barge-in (user speaking during playback) aborts the reply and re-listens.
public final class VoiceSession {
    private let audio: AudioIO
    private let vad: Vad
    private let stt: Stt
    private let tts: Tts
    private let llm: LLMProvider
    private let nvp: NVPClient?
    private let agent: AgentLoop
    private let store: HistoryStore?
    private let dtd = DoubleTalkDetector()

    public var onState: ((VoiceState) -> Void)?
    public var onUserText: ((String) -> Void)?
    public var onAgentText: ((String) -> Void)?
    public var onToolActivity: ((String) -> Void)?

    private var state: VoiceState = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    private var history: [ChatMessage] = []
    private var latestPartial = ""
    private var pendingReply = ""
    private var replyGeneration = 0

    private let sessionId = "voice-main"
    private let compressionSwitchThresholdChars = 16_000
    private let contextWindowTokens = 128_000
    private let budgetRatio = 0.5
    private let recentFullTextTurns = 6

    private let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]

    /// Engine/player/STT control + all `state` writes hop here; never call
    /// AVAudioPlayerNode.stop() on the audio tap thread — it deadlock-traps.
    private let controlQueue = DispatchQueue(label: "voiceagent.session.control")

    public init(audio: AudioIO, vad: Vad, stt: Stt, tts: Tts, llm: LLMProvider, registry: ToolRegistry = ToolRegistry(), system: String? = nil, maxRounds: Int = 5, nvp: NVPClient? = nil, store: HistoryStore? = nil) {
        self.audio = audio
        self.vad = vad
        self.stt = stt
        self.tts = tts
        self.llm = llm
        self.nvp = nvp
        self.store = store
        self.agent = AgentLoop(provider: llm, registry: registry, system: system, maxRounds: maxRounds)
        self.history = store?.load() ?? []
        wire()
    }

    public var loadedHistory: [ChatMessage] { history }

    public func start() throws {
        try audio.start()
        controlQueue.async { self.state = .listening }
    }

    public func stop() {
        controlQueue.async {
            self.audio.stop()
            self.tts.stopImmediately()
            self.state = .idle
        }
    }

    private func wire() {
        var bufCount = 0
        audio.onBuffer = { [weak self] samples, time in
            guard let self = self else { return }
            let r = Self.rms(samples)
            bufCount += 1
            if bufCount % 20 == 0 { vaLog("buffer #\(bufCount) n=\(samples.count) rms=\(r)") }
            // While speaking, the energy VAD can't tell echo residue from a real
            // interrupting voice, so route mic frames to the double-talk detector
            // (gated by playback RMS) instead. Its noise floor is frozen (we stop
            // feeding it) because playback echo would poison the adaptation.
            if self.state == .speaking {
                self.dtd.process(micRms: r, refRms: self.audio.currentPlaybackRms, now: time)
            } else {
                self.vad.process(rms: r)
            }
            self.stt.feed(samples, sampleRate: self.audio.sampleRate)
        }

        dtd.onBargeIn = { [weak self] in
            guard let self = self else { return }
            self.controlQueue.async {
                guard self.state == .speaking else { return }
                vaLog("DTD confirmed barge-in")
                self.bargeIn()
            }
        }

        stt.onPartial = { [weak self] text in
            vaLog("STT partial: \(text)")
            self?.latestPartial = text
        }

        stt.onFinal = { [weak self] text in
            guard let self = self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.controlQueue.async {
                vaLog("STT final: \(text)")
                self.latestPartial = ""
                guard !trimmed.isEmpty else { return }
                self.handleUserUtterance(trimmed)
            }
        }

        vad.onSpeechStart = { [weak self] in
            guard let self = self else { return }
            self.controlQueue.async {
                vaLog("VAD speechStart state=\(self.state.rawValue)")
                if self.state == .listening {
                    self.stt.start()
                }
            }
        }

        vad.onSpeechEnd = { [weak self] in
            guard let self = self else { return }
            self.controlQueue.async {
                vaLog("VAD speechEnd state=\(self.state.rawValue)")
                if self.stt.isActive { self.stt.finish() }
            }
        }
    }

    private func handleUserUtterance(_ text: String) {
        onUserText?(text)
        history.append(ChatMessage(role: .user, text: text))
        state = .thinking
        pendingReply = ""
        replyGeneration += 1
        let generation = replyGeneration

        let messagesToSend = buildOutgoingMessages()

        var accumulatedText = ""
        var newMessages: [ChatMessage] = []

        Task { [weak self] in
            guard let self = self else { return }
            await self.agent.run(
                history: messagesToSend,
                isCurrent: { [weak self] in self?.replyGeneration == generation },
                onTextDelta: { [weak self] delta in
                    guard let self = self else { return }
                    self.controlQueue.async {
                        guard generation == self.replyGeneration else { return }
                        accumulatedText += delta
                        self.pendingReply += delta
                        self.flushSentences(generation: generation)
                    }
                },
                onToolStart: { [weak self] name in
                    guard let self = self else { return }
                    self.controlQueue.async {
                        guard generation == self.replyGeneration else { return }
                        self.flushRemainder(generation: generation)
                        self.state = .working
                        self.onToolActivity?(name)
                    }
                },
                onAssistantMessage: { msg in
                    newMessages.append(msg)
                },
                onToolResultMessage: { msg in
                    newMessages.append(msg)
                },
                onDone: { [weak self] reason in
                    guard let self = self else { return }
                    self.controlQueue.async {
                        guard generation == self.replyGeneration else { return }
                        self.flushRemainder(generation: generation)
                        self.history.append(contentsOf: newMessages)
                        self.store?.save(self.history)
                        if !accumulatedText.isEmpty {
                            self.onAgentText?(accumulatedText)
                        }
                        switch reason {
                        case .error(let error):
                            self.speakChunk("抱歉，出错了：\(error)", generation: generation)
                        default:
                            break
                        }
                        if !accumulatedText.isEmpty {
                            self.nvp?.ingest(sessionId: self.sessionId, turn: [
                                (role: "user", content: text),
                                (role: "assistant", content: accumulatedText),
                            ])
                        }
                    }
                }
            )
        }
    }

    /// 低于阈值直接发原始历史（新会话还没压缩内容，调 NVP 纯属浪费）；
    /// 超阈值才尝试 renderContext，任何失败/超时降级回原始历史。
    private func buildOutgoingMessages() -> [ChatMessage] {
        let totalChars = history.reduce(0) { $0 + $1.text.count }
        guard totalChars >= compressionSwitchThresholdChars, let nvp = nvp else {
            return history
        }
        guard let rendered = nvp.renderContext(
            sessionId: sessionId,
            contextWindowTokens: contextWindowTokens,
            budgetRatio: budgetRatio,
            recentFullTextTurns: recentFullTextTurns
        ), !rendered.isEmpty else {
            return history
        }
        return rendered.compactMap { m in
            switch m.role {
            case "user": return ChatMessage(role: .user, text: m.content)
            case "assistant": return ChatMessage(role: .assistant, text: m.content)
            default: return nil
            }
        }
    }

    private func flushSentences(generation: Int) {
        while let idx = pendingReply.firstIndex(where: { sentenceEnders.contains($0) }) {
            let sentence = String(pendingReply[...idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingReply = String(pendingReply[pendingReply.index(after: idx)...])
            if !sentence.isEmpty { speakChunk(sentence, generation: generation) }
        }
    }

    private func flushRemainder(generation: Int) {
        let tail = pendingReply.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingReply = ""
        if !tail.isEmpty { speakChunk(tail, generation: generation) }
    }

    private func speakChunk(_ text: String, generation: Int) {
        guard generation == replyGeneration else { return }
        if state != .speaking { dtd.arm() }
        state = .speaking
        tts.speak(text)
    }

    private func bargeIn() {
        replyGeneration += 1
        pendingReply = ""
        dtd.disarm()
        tts.stopImmediately()
        stt.reset()
        vad.reset()
        state = .listening
        stt.start()
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
