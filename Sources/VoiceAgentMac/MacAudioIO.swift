import Foundation
import AVFoundation
import VoiceAgentCore

/// Shared VPIO engine doing capture + TTS playback on one graph so hardware AEC
/// can subtract our own TTS from the mic (enables barge-in). The wiring order is
/// load-bearing: violating any note below reproduces the -10875 init crash.
final class MacAudioIO: NSObject, AudioIO {
    var onBuffer: (([Float], Double) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private(set) var vpFormat: AVAudioFormat!
    private var hwFormat: AVAudioFormat!

    private var started = false

    var sampleRate: Double { vpFormat?.sampleRate ?? 48000 }

    func start() throws {
        guard !started else { return }

        let input = engine.inputNode
        let output = engine.outputNode

        // VP on input-only leaves outputNode a plain HAL output that fights the
        // shared VPIO unit -> -10875 at outputNode kAUInitialize. Enable on both.
        try input.setVoiceProcessingEnabled(true)
        try output.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = false

        engine.attach(player)

        // Never query mainMixer.outputFormat: it pins the mixer to 44.1/2ch and
        // defeats VP's 48k renegotiation. Derive the hardware format from the
        // output node's input bus instead.
        hwFormat = output.inputFormat(forBus: 0)
        guard let vpMono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: hwFormat.sampleRate,
                                         channels: 1, interleaved: false) else {
            throw AudioIOError.formatSetup
        }
        vpFormat = vpMono

        // The implicit mainMixer->output edge inherits 44.1/2ch and fights the
        // 48k VPIO bus -> -10875. Both edges MUST be explicit: mixer->output at
        // hwFormat, and player->mixer at hardware-rate mono (never raw TTS rate).
        engine.connect(player, to: engine.mainMixerNode, format: vpMono)
        engine.connect(engine.mainMixerNode, to: output, format: hwFormat)

        // The VP route reports a 9ch format whose channel 0 is a dead reference
        // channel (digital silence); an explicit mono tap format forces delivery
        // of the real AEC-processed mono signal.
        input.installTap(onBus: 0, bufferSize: 4096, format: vpMono) { [weak self] buffer, _ in
            guard let self = self else { return }
            let samples = Self.extractMono(buffer)
            guard !samples.isEmpty else { return }
            self.onBuffer?(samples, CACurrentMediaTime())
        }

        // setVoiceProcessingEnabled makes the engine self-stop via a config
        // change; restart on the notification or start() silently no-ops.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            if !self.engine.isRunning { try? self.engine.start() }
        }

        engine.prepare()
        try engine.start()
        started = true
    }

    func stop() {
        guard started else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        started = false
    }

    // MARK: - Playback (used by MacTts to route TTS through the shared VPIO engine)

    /// Schedule an already-VP-mono buffer for playback on the shared engine.
    func schedulePlayback(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)? = nil) {
        guard started else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: []) {
            completion?()
        }
    }

    /// Stop any in-flight playback immediately (barge-in / interruption).
    func stopPlayback() {
        guard started else { return }
        player.stop()
    }

    private static func extractMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        let n = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }
}

enum AudioIOError: Error, CustomStringConvertible {
    case formatSetup
    var description: String {
        switch self {
        case .formatSetup: return "failed to construct VP boundary audio format"
        }
    }
}
