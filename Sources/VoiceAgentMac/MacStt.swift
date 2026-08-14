import Foundation
import AVFoundation
import Speech
import VoiceAgentCore

final class MacStt: NSObject, Stt {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let useOnDevice: Bool
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private let queue = DispatchQueue(label: "voiceagent.stt.serial")
    private var active = false
    private var lastErrorAt: Date?

    private var preRoll: [Float] = []
    private var preRollSampleRate: Double = 16_000
    private var preRollCapacity = 8_000

    var isActive: Bool { queue.sync { active } }

    init(locale: String = "zh-CN") {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        useOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        super.init()
        vaLog("MacStt init locale=\(locale) recognizer=\(recognizer != nil) onDevice=\(useOnDevice) available=\(recognizer?.isAvailable ?? false)")
    }

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    private func startLocked() {
        guard !active else { return }
        guard let recognizer else { vaLog("STT start abort: recognizer nil"); return }
        guard recognizer.isAvailable else { vaLog("STT start abort: recognizer NOT available"); return }
        if let last = lastErrorAt, Date().timeIntervalSince(last) < 0.5 {
            vaLog("STT start skipped: error backoff")
            return
        }
        vaLog("STT start creating recognitionTask onDevice=\(useOnDevice) preRoll=\(preRoll.count)")
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if useOnDevice { req.requiresOnDeviceRecognition = true }
        request = req
        active = true
        flushPreRollLocked(into: req)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { self.onFinal?(trimmed) }
                    } else {
                        self.onPartial?(text)
                    }
                }
                if let error {
                    let ns = error as NSError
                    if ns.code == 1110 || ns.domain == "kAFAssistantErrorDomain" {
                        vaLog("STT no-speech/assistant error (silent): \(ns.domain) \(ns.code)")
                    } else {
                        vaLog("STT task error: \(error.localizedDescription)")
                        self.lastErrorAt = Date()
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.clearTaskLocked()
                }
            }
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            vaLog("STT finish")
            self.request?.endAudio()
            self.task?.finish()
        }
    }

    func feed(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if let request = self.active ? self.request : nil {
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                if let channel = buffer.floatChannelData {
                    samples.withUnsafeBufferPointer { src in
                        channel[0].update(from: src.baseAddress!, count: samples.count)
                    }
                }
                request.append(buffer)
            } else {
                self.preRollSampleRate = sampleRate
                self.preRollCapacity = Int(sampleRate * 0.5)
                self.preRoll.append(contentsOf: samples)
                if self.preRoll.count > self.preRollCapacity {
                    self.preRoll.removeFirst(self.preRoll.count - self.preRollCapacity)
                }
            }
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.request?.endAudio()
            self.task?.finish()
            self.clearTaskLocked()
            self.preRoll.removeAll(keepingCapacity: true)
        }
    }

    private func clearTaskLocked() {
        request = nil
        task = nil
        active = false
    }

    private func flushPreRollLocked(into req: SFSpeechAudioBufferRecognitionRequest) {
        guard !preRoll.isEmpty else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: preRollSampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(preRoll.count)) else {
            preRoll.removeAll(keepingCapacity: true)
            return
        }
        buffer.frameLength = AVAudioFrameCount(preRoll.count)
        if let channel = buffer.floatChannelData {
            preRoll.withUnsafeBufferPointer { src in
                channel[0].update(from: src.baseAddress!, count: preRoll.count)
            }
        }
        req.append(buffer)
        preRoll.removeAll(keepingCapacity: true)
    }
}
