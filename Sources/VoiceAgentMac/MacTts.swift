import Foundation
import AVFoundation
import VoiceAgentCore

/// TTS that renders speech to PCM and plays it through the shared VPIO engine
/// (MacAudioIO) so hardware AEC can subtract our own output from the mic, which
/// is what makes barge-in work. Playing through any other path starves the AEC
/// reference and makes the VAD trigger barge-in on the AI's own voice.
///
/// Primary engine is Edge-TTS (Microsoft neural voices) via a python subprocess
/// producing a 24kHz mono MP3 we decode with AVAudioFile. AVSpeechSynthesizer is
/// the offline fallback when the subprocess/network/decode fails.
///
/// Concurrency model (per Oracle design):
///   - speak(text) is a synchronous enqueue; it spawns an async render Task.
///   - A monotonically increasing `generation` token invalidates all in-flight
///     work on stopImmediately(): render Tasks are cancelled (SIGTERM->SIGKILL
///     on the subprocess), the play queue is cleared, and the player is stopped.
///   - Rendered buffers whose generation != current are discarded on enqueue.
final class MacTts: NSObject, Tts {
    private let synth = AVSpeechSynthesizer()
    private let audio: MacAudioIO

    private let useEdge: Bool
    private let pythonPath: String
    private let voiceZh: String
    private let voiceEn: String
    private let systemVoiceLanguage: String?
    private let systemRate: Float

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var inflight: [UInt64: Task<Void, Never>] = [:]
    private var taskSeq: UInt64 = 0
    private var pendingCount = 0
    private var edgeFailures = 0
    private var forceFallback = false

    init(audio: MacAudioIO,
         voiceLanguage: String? = "zh-CN",
         rate: Float = 0.5,
         ttsEngine: String? = nil,
         edgePythonPath: String? = nil,
         edgeVoiceZh: String? = nil,
         edgeVoiceEn: String? = nil) {
        self.audio = audio
        self.systemVoiceLanguage = voiceLanguage
        self.systemRate = rate
        self.voiceZh = edgeVoiceZh ?? "zh-CN-XiaoxiaoNeural"
        self.voiceEn = edgeVoiceEn ?? "en-US-AvaNeural"

        let resolvedPython = Self.resolvePython(edgePythonPath)
        self.pythonPath = resolvedPython ?? ""
        let engine = (ttsEngine ?? "edge").lowercased()
        self.useEdge = (engine == "edge") && resolvedPython != nil
        super.init()
    }

    var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingCount > 0
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        let gen = generation
        let goEdge = useEdge && !forceFallback
        taskSeq &+= 1
        let taskID = taskSeq
        pendingCount += 1
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.render(trimmed, generation: gen, taskID: taskID, useEdge: goEdge)
        }
        inflight[taskID] = task
        lock.unlock()
    }

    func stopImmediately() {
        lock.lock()
        generation &+= 1
        let tasks = Array(inflight.values)
        inflight.removeAll()
        pendingCount = 0
        lock.unlock()

        for t in tasks { t.cancel() }
        synth.stopSpeaking(at: .immediate)
        audio.stopPlayback()
    }

    private func render(_ text: String, generation gen: UInt64, taskID: UInt64, useEdge: Bool) async {
        defer { finishTask(taskID) }

        var vpBuffer: AVAudioPCMBuffer?
        var source = "none"
        if useEdge {
            do {
                vpBuffer = try await renderEdge(text)
                if vpBuffer != nil { source = "edge" }
            } catch {
                if Task.isCancelled { return }
                noteEdgeFailure()
                vaLog("TTS edge render failed: \(error)")
            }
        }
        if vpBuffer == nil {
            if Task.isCancelled { return }
            vpBuffer = renderSystem(text)
            if vpBuffer != nil { source = "system" }
        }

        guard let buffer = vpBuffer, !Task.isCancelled else {
            vaLog("TTS render produced no buffer (text=\(text.prefix(20)))")
            return
        }
        guard isCurrent(gen) else { return }

        vaLog("TTS play source=\(source) frames=\(buffer.frameLength) sr=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) via VPIO")
        let finished = PlaybackFlag()
        audio.schedulePlayback(buffer) { finished.set() }
        while !finished.isSet {
            if Task.isCancelled || !isCurrent(gen) {
                audio.stopPlayback()
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }


    private func renderEdge(_ text: String) async throws -> AVAudioPCMBuffer? {
        let voice = Self.hasChinese(text) ? voiceZh : voiceEn
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("aivoice-tts-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: out) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-m", "edge_tts", "--voice", voice, "--text", text,
                          "--write-media", out.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try await runProcess(proc)
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path) else {
            throw TtsError.synthFailed
        }

        let file = try AVAudioFile(forReading: out)
        guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TtsError.decodeFailed
        }
        try file.read(into: raw)
        guard raw.frameLength > 0 else { throw TtsError.decodeFailed }
        return convertToVP(raw, from: raw.format)
    }

    /// Runs the process and suspends until exit. On task cancellation it sends
    /// SIGTERM, and a 2s watchdog escalates to SIGKILL if edge_tts is wedged in
    /// a network recv (terminate() alone won't unblock it).
    private func runProcess(_ proc: Process) async throws {
        try proc.run()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                proc.terminationHandler = { _ in cont.resume() }
            }
        } onCancel: {
            proc.terminate()
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
        try Task.checkCancellation()
    }


    private func renderSystem(_ text: String) -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        if let lang = systemVoiceLanguage, let voice = AVSpeechSynthesisVoice(language: lang) {
            utterance.voice = voice
        }
        utterance.rate = systemRate

        var chunks: [AVAudioPCMBuffer] = []
        let sem = DispatchSemaphore(value: 0)
        synth.write(utterance) { buffer in
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                chunks.append(pcm)
            } else {
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 15)

        guard let first = chunks.first else { return nil }
        let srcFormat = first.format
        let total = chunks.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard total > 0,
              let combined = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: total) else { return nil }
        for chunk in chunks {
            guard chunk.format == srcFormat,
                  let dst = combined.floatChannelData,
                  let src = chunk.floatChannelData else { continue }
            let offset = Int(combined.frameLength)
            let n = Int(chunk.frameLength)
            for c in 0..<Int(srcFormat.channelCount) {
                memcpy(dst[c] + offset, src[c], n * MemoryLayout<Float>.size)
            }
            combined.frameLength += chunk.frameLength
        }
        return convertToVP(combined, from: srcFormat)
    }


    private func convertToVP(_ buffer: AVAudioPCMBuffer, from srcFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let vp = audio.vpFormat else { return nil }
        guard let converter = AVAudioConverter(from: srcFormat, to: vp) else { return nil }
        let ratio = vp.sampleRate / srcFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 4096)
        guard let out = AVAudioPCMBuffer(pcmFormat: vp, frameCapacity: outCap) else { return nil }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return err == nil ? out : nil
    }


    private func isCurrent(_ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    private func finishTask(_ taskID: UInt64) {
        lock.lock()
        if inflight.removeValue(forKey: taskID) != nil, pendingCount > 0 {
            pendingCount -= 1
        }
        lock.unlock()
    }

    /// After 3 consecutive edge failures, pin the whole session to the offline
    /// fallback so we stop paying the network+subprocess penalty per sentence.
    private func noteEdgeFailure() {
        lock.lock()
        edgeFailures += 1
        if edgeFailures >= 3 { forceFallback = true }
        lock.unlock()
    }

    private static func hasChinese(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where (0x4E00...0x9FFF).contains(scalar.value) {
            return true
        }
        return false
    }

    private static func resolvePython(_ configured: String?) -> String? {
        if let p = configured {
            let expanded = (p as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let candidates = [
            "~/Desktop/ju/projects/opencode-voice-output-plugin/.venv/bin/python3",
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3"
        ]
        for c in candidates {
            let expanded = (c as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }
        return nil
    }
}

enum TtsError: Error {
    case synthFailed
    case decodeFailed
}

final class PlaybackFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
