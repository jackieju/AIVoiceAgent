import Foundation
import AVFoundation
import VoiceAgentCore

/// TTS that renders speech to PCM via synth.write and plays it through the shared
/// VPIO engine (MacAudioIO). synth.speak() bypasses our engine and starves the
/// AEC of a reference signal, breaking barge-in — hence the write+convert route.
final class MacTts: NSObject, Tts {
    private let synth = AVSpeechSynthesizer()
    private let audio: MacAudioIO
    private let voiceLanguage: String?
    private let rate: Float

    private var speaking = false
    private let synthQueue = DispatchQueue(label: "com.aivoiceagent.tts.synth")

    init(audio: MacAudioIO, voiceLanguage: String? = "zh-CN", rate: Float = 0.5) {
        self.audio = audio
        self.voiceLanguage = voiceLanguage
        self.rate = rate
        super.init()
    }

    var isSpeaking: Bool { speaking }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speaking = true
        synthQueue.async { [weak self] in
            guard let self = self else { return }
            guard let vpBuffer = self.renderToVPBuffer(trimmed) else {
                self.speaking = false
                return
            }
            self.audio.schedulePlayback(vpBuffer) { [weak self] in
                self?.speaking = false
            }
        }
    }

    func stopImmediately() {
        synth.stopSpeaking(at: .immediate)
        audio.stopPlayback()
        speaking = false
    }

    private func renderToVPBuffer(_ text: String) -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceLanguage, let voice = AVSpeechSynthesisVoice(language: voiceLanguage) {
            utterance.voice = voice
        }
        utterance.rate = rate

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
        let vp = audio.vpFormat!
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
}
