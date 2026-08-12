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

    init(locale: String = "zh-CN") {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        useOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        super.init()
    }

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    private func startTaskIfNeeded() {
        guard request == nil, let recognizer, recognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if useOnDevice { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal { self.onFinal?(text) } else { self.onPartial?(text) }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.request = nil
                self.task = nil
            }
        }
    }

    func feed(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        startTaskIfNeeded()
        guard let request,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channel[0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        request.append(buffer)
    }

    func reset() {
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }
}
