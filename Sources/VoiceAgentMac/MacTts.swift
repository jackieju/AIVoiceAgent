import Foundation
import AVFoundation
import VoiceAgentCore

final class MacTts: NSObject, Tts {
    private let synth = AVSpeechSynthesizer()
    private let voiceLanguage: String?
    private let rate: Float

    init(voiceLanguage: String? = "zh-CN", rate: Float = 0.5) {
        self.voiceLanguage = voiceLanguage
        self.rate = rate
        super.init()
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceLanguage, let voice = AVSpeechSynthesisVoice(language: voiceLanguage) {
            utterance.voice = voice
        }
        utterance.rate = rate
        synth.speak(utterance)
    }

    func stopImmediately() {
        synth.stopSpeaking(at: .immediate)
    }
}
