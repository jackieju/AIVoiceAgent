import Foundation

public enum VoiceState: String {
    case idle
    case listening
    case thinking
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

    public var onState: ((VoiceState) -> Void)?
    public var onUserText: ((String) -> Void)?
    public var onAgentText: ((String) -> Void)?

    private var state: VoiceState = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    private var history: [ChatMessage] = []
    private var latestPartial = ""
    private var pendingReply = ""
    private var replyGeneration = 0

    private let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]

    public init(audio: AudioIO, vad: Vad, stt: Stt, tts: Tts, llm: LLMProvider) {
        self.audio = audio
        self.vad = vad
        self.stt = stt
        self.tts = tts
        self.llm = llm
        wire()
    }

    public func start() throws {
        try audio.start()
        state = .listening
    }

    public func stop() {
        audio.stop()
        tts.stopImmediately()
        state = .idle
    }

    private func wire() {
        audio.onBuffer = { [weak self] samples, _ in
            guard let self = self else { return }
            self.vad.process(rms: Self.rms(samples))
            if self.state == .listening || self.state == .speaking {
                self.stt.feed(samples, sampleRate: self.audio.sampleRate)
            }
        }

        stt.onPartial = { [weak self] text in
            self?.latestPartial = text
        }

        stt.onFinal = { [weak self] text in
            guard let self = self else { return }
            self.latestPartial = ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.handleUserUtterance(trimmed)
        }

        vad.onSpeechStart = { [weak self] in
            guard let self = self else { return }
            if self.state == .speaking { self.bargeIn() }
        }

        vad.onSpeechEnd = { [weak self] in
            guard let self = self else { return }
            if self.state == .listening { self.stt.reset() }
        }
    }

    private func handleUserUtterance(_ text: String) {
        onUserText?(text)
        history.append(ChatMessage(role: .user, text: text))
        state = .thinking
        pendingReply = ""
        replyGeneration += 1
        let generation = replyGeneration

        var accumulated = ""
        llm.stream(
            messages: history,
            onDelta: { [weak self] delta in
                guard let self = self, generation == self.replyGeneration else { return }
                accumulated += delta
                self.pendingReply += delta
                self.flushSentences(generation: generation)
            },
            onDone: { [weak self] in
                guard let self = self, generation == self.replyGeneration else { return }
                self.flushRemainder(generation: generation)
                if !accumulated.isEmpty {
                    self.history.append(ChatMessage(role: .assistant, text: accumulated))
                    self.onAgentText?(accumulated)
                }
            },
            onError: { [weak self] error in
                guard let self = self, generation == self.replyGeneration else { return }
                self.speakChunk("抱歉，出错了：\(error)", generation: generation)
            }
        )
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
        state = .speaking
        tts.speak(text)
    }

    private func bargeIn() {
        replyGeneration += 1
        pendingReply = ""
        tts.stopImmediately()
        stt.reset()
        state = .listening
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
