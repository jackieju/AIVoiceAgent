import Foundation
import AVFoundation
import VoiceAgentCore

/// Speech-to-text backed by whisper.cpp (`whisper-cli` subprocess) instead of
/// Apple's SFSpeechRecognizer. Apple's recognizer mis-hears domain words like
/// "OpenCode" ("open cold") and has the No-speech-detected restart loop; whisper
/// (ggml-large-v3-turbo) is far more accurate for Chinese and technical terms.
///
/// whisper is NOT streaming — it takes one complete utterance and transcribes it
/// once. So the VAD drives the lifecycle: `feed()` accumulates audio while active,
/// `finish()` (fired on VAD speech-end) snapshots the buffer, resamples 48k->16k,
/// writes a temp WAV, spawns whisper-cli, and fires `onFinal` with the result.
/// `onPartial` never fires (no streaming); VoiceSession only uses it for display.
///
/// Concurrency model (per Oracle design):
///   - `stateQueue` (serial) guards ONLY active/preRoll/accumulator/epoch — all
///     O(µs) operations. The blocking whisper subprocess NEVER runs here.
///   - `finish()` snapshots state on stateQueue, then hops to a global queue to
///     run resample + WAV + subprocess (1-2s) so feeds never pile up.
///   - An `epoch` token is bumped on every start()/reset(); a stale whisper result
///     whose epoch != current is discarded before onFinal, so a barge-in or a new
///     utterance can't be polluted by the previous utterance's late transcription.
final class WhisperStt: NSObject, Stt {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private let stateQueue = DispatchQueue(label: "voiceagent.whisper.stt.state")
    private let isActiveLock = NSLock()
    private var _isActive = false

    private var epoch: UInt64 = 0
    private var accumulator: [Float] = []
    private var preRoll: [Float] = []
    private var currentProcess: Process?

    private let inputSampleRate: Double
    private let whisperSampleRate: Double = 16_000
    private let maxAccumSamples: Int
    private let preRollCapacity: Int

    private var converter: AVAudioConverter?
    private var converterInRate: Double = 0

    private let corrector = TranscriptCorrector(rules: TranscriptCorrector.defaultRules)

    private let whisperPath = "/opt/homebrew/bin/whisper-cli"
    private let modelSearchDir = NSString("~/.local/share/whisper-cpp/models").expandingTildeInPath
    private let preferredModels = [
        "ggml-large-v3-turbo.bin",
        "ggml-large-v3.bin",
        "ggml-medium.bin",
        "ggml-base.bin",
        "ggml-small.bin",
        "ggml-tiny.bin",
    ]

    /// - Parameter inputSampleRate: the sample rate of buffers arriving via feed()
    ///   (MacAudioIO delivers hardware rate, typically 48000).
    init(inputSampleRate: Double = 48_000) {
        self.inputSampleRate = inputSampleRate
        self.maxAccumSamples = Int(inputSampleRate * 30)
        self.preRollCapacity = Int(inputSampleRate * 0.5)
        super.init()
        let modelFound = Self.locateModel(dir: modelSearchDir, preferred: preferredModels) != nil
        let cliFound = FileManager.default.fileExists(atPath: whisperPath)
        vaLog("WhisperStt init inRate=\(inputSampleRate) cli=\(cliFound) model=\(modelFound)")
    }

    var isActive: Bool {
        isActiveLock.lock(); defer { isActiveLock.unlock() }
        return _isActive
    }

    private func setActive(_ v: Bool) {
        isActiveLock.lock(); _isActive = v; isActiveLock.unlock()
    }

    func start() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.epoch &+= 1
            self.setActive(true)
            self.accumulator = self.preRoll
            self.preRoll.removeAll(keepingCapacity: true)
            vaLog("WhisperStt start epoch=\(self.epoch) preRoll=\(self.accumulator.count)")
        }
    }

    func feed(_ samples: [Float], sampleRate: Double) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            if self._isActive {
                self.accumulator.append(contentsOf: samples)
                if self.accumulator.count >= self.maxAccumSamples {
                    vaLog("WhisperStt accum cap hit (\(self.accumulator.count)) -> force finish")
                    self.finishLocked()
                }
            } else {
                self.preRoll.append(contentsOf: samples)
                if self.preRoll.count > self.preRollCapacity {
                    self.preRoll.removeFirst(self.preRoll.count - self.preRollCapacity)
                }
            }
        }
    }

    func finish() {
        stateQueue.async { [weak self] in self?.finishLocked() }
    }

    /// Must be called on stateQueue.
    private func finishLocked() {
        guard _isActive else { return }
        setActive(false)
        let myEpoch = epoch
        let samples = accumulator
        accumulator.removeAll(keepingCapacity: true)
        guard !samples.isEmpty else {
            vaLog("WhisperStt finish: empty buffer, skipping")
            return
        }
        vaLog("WhisperStt finish epoch=\(myEpoch) samples=\(samples.count)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let text = self.transcribe(samples)
            self.stateQueue.async {
                guard myEpoch == self.epoch else {
                    vaLog("WhisperStt discard stale result epoch=\(myEpoch) current=\(self.epoch)")
                    return
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let corrected = self.corrector.correct(trimmed)
                if !corrected.isEmpty { self.onFinal?(corrected) }
            }
        }
    }

    func reset() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.epoch &+= 1
            self.setActive(false)
            self.accumulator.removeAll(keepingCapacity: true)
            self.preRoll.removeAll(keepingCapacity: true)
            self.currentProcess?.terminate()
            self.currentProcess = nil
            vaLog("WhisperStt reset epoch=\(self.epoch)")
        }
    }

    // MARK: - Transcription (runs on global queue, never stateQueue)

    private func transcribe(_ samples: [Float]) -> String {
        guard let resampled = resampleTo16k(samples) else {
            vaLog("WhisperStt resample failed")
            return ""
        }
        guard let wavURL = writeWav(resampled) else {
            vaLog("WhisperStt WAV write failed")
            return ""
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }
        return runWhisper(wavURL: wavURL)
    }

    private func runWhisper(wavURL: URL) -> String {
        guard let model = Self.locateModel(dir: modelSearchDir, preferred: preferredModels) else {
            vaLog("WhisperStt no model in \(modelSearchDir)")
            return ""
        }
        guard FileManager.default.fileExists(atPath: whisperPath) else {
            vaLog("WhisperStt cli not found at \(whisperPath)")
            return ""
        }

        // Language: first selected language forces that language; none/empty = auto.
        // (SFSpeech was single-locale; whisper honours real multi-select semantics.)
        let savedLangs = UserDefaults.standard.stringArray(forKey: "selectedLanguages") ?? []
        let langArg = savedLangs.isEmpty ? "auto" : savedLangs[0]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "-m", model.path,
            "-f", wavURL.path,
            "-l", langArg,
            "--no-timestamps",
            "-t", "4",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        stateQueue.sync { self.currentProcess = process }

        vaLog("WhisperStt cmd: \(whisperPath) \(process.arguments?.joined(separator: " ") ?? "")")
        do {
            try process.run()
        } catch {
            vaLog("WhisperStt run failed: \(error)")
            stateQueue.sync { self.currentProcess = nil }
            return ""
        }

        // Read stdout fully BEFORE waitUntilExit to avoid a full-pipe deadlock.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stateQueue.sync { if self.currentProcess === process { self.currentProcess = nil } }

        let raw = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        vaLog("WhisperStt exit=\(process.terminationStatus) stdoutBytes=\(outData.count) stderrTail=\(errStr.suffix(200))")

        // Drop a trailing sentence period whisper likes to add on short utterances.
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\.$|。$", with: "", options: .regularExpression)
    }

    // MARK: - Resampling 48k -> 16k mono

    private func resampleTo16k(_ samples: [Float]) -> [Float]? {
        if inputSampleRate == whisperSampleRate { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: inputSampleRate,
                                           channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: whisperSampleRate,
                                            channels: 1, interleaved: false)
        else { return nil }

        if converter == nil || converterInRate != inputSampleRate {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converter?.primeMethod = .none
            converterInRate = inputSampleRate
        }
        guard let converter = converter else { return nil }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                              frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = inBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                dst[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        let ratio = whisperSampleRate / inputSampleRate
        let outCapacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if let convError = convError {
            vaLog("WhisperStt convert error: \(convError)")
            return nil
        }
        if status == .error { return nil }

        let n = Int(outBuffer.frameLength)
        guard n > 0, let ch = outBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }

    // MARK: - WAV writing (16-bit PCM mono @ 16kHz)

    private func writeWav(_ samples: [Float]) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aivoiceagent_\(UUID().uuidString).wav")

        let sampleRate = UInt32(whisperSampleRate)
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count) * UInt32(bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(chunkSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))           // fmt chunk size
        appendLE(UInt16(1))            // PCM
        appendLE(numChannels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        appendLE(dataSize)

        data.reserveCapacity(data.count + samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i16 = Int16(clamped * 32767.0)
            appendLE(i16)
        }

        do {
            try data.write(to: url)
            return url
        } catch {
            vaLog("WhisperStt WAV write error: \(error)")
            return nil
        }
    }

    // MARK: - Model location

    private static func locateModel(dir: String, preferred: [String]) -> URL? {
        let base = URL(fileURLWithPath: dir)
        for name in preferred {
            let candidate = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
