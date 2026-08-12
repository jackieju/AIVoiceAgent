import Foundation

public enum VoiceAgent {
    public static let version = "0.1.0"
}

public protocol AudioIO: AnyObject {
    var onBuffer: (([Float], Double) -> Void)? { get set }
    func start() throws
    func stop()
}

public protocol Stt: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    func feed(_ samples: [Float], sampleRate: Double)
    func reset()
}

public protocol Tts: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String)
    func stopImmediately()
}

public protocol Vad: AnyObject {
    var onSpeechStart: (() -> Void)? { get set }
    var onSpeechEnd: (() -> Void)? { get set }
    func process(rms: Float)
}
