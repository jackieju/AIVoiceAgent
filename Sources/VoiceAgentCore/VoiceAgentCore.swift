import Foundation

public enum VoiceAgent {
    public static let version = "0.1.0"
}

public func vaLog(_ msg: String) {    let line = "[\(Date().timeIntervalSince1970)] \(msg)\n"
    let path = "/tmp/aivoiceagent_debug.log"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

public protocol AudioIO: AnyObject {
    var onBuffer: (([Float], Double) -> Void)? { get set }
    var sampleRate: Double { get }
    func start() throws
    func stop()
}

public protocol Stt: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var isActive: Bool { get }
    func start()
    func finish()
    /// When no task is active, samples go to a pre-roll ring buffer; feed never auto-starts a task.
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
