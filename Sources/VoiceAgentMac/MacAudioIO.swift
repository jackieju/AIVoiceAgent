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

    // Config-change notifications arrive on an AV-internal thread; touching the
    // engine there races the VPIO unit. Serialize all lifecycle work here.
    private let engineQueue = DispatchQueue(label: "com.aivoiceagent.audio.engine")

    // AEC reference signal: how loud our own TTS is currently playing. Written on
    // the playback-scheduling/completion path, read lock-free on the mic tap
    // thread (a plain Float word read is atomic on arm64/x86_64). The double-talk
    // detector needs this to tell echo residue from a real interrupting voice.
    private var playbackRms: Float = 0

    var currentPlaybackRms: Float { playbackRms }

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

        // Install the mic tap using the input node's NATIVE format (format: nil).
        // The VP route reports a 9ch layout whose channel 0 is a dead AEC reference
        // channel (digital silence); extractMono manually picks the near-end mic
        // channel rather than letting AVAudioEngine implicitly downmix a mono tap
        // format (which can average in ch0 silence and starve whisper).
        installMicTap()

        // setVoiceProcessingEnabled makes the engine self-stop via a config change
        // ~1-2s after start (VPIO negotiates the AEC reference stream + locks the
        // hardware format). That teardown ORPHANS the installed tap: the block is
        // retained but never scheduled again -> capture goes permanently silent
        // after ~20 buffers. So on every config change we must remove + REINSTALL
        // the tap (input format may have changed) then restart, serialized on
        // engineQueue to avoid racing a user-thread start()/stop() into -10875.
        // Do NOT call engine.stop() here (it already self-stopped) and do NOT
        // rewire player/mixer (that path is what triggers -10875).
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.engineQueue.async {
                guard self.started else { return }
                self.engine.inputNode.removeTap(onBus: 0)
                self.installMicTap()
                if !self.engine.isRunning { try? self.engine.start() }
            }
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

    /// (Re)install the mic tap. Called from start() and from the config-change
    /// handler (VPIO renegotiation orphans the previous tap). Uses format: nil so
    /// the tap always matches the input node's CURRENT native format, surviving
    /// sample-rate/channel renegotiations without a stale-format silent drop.
    private func installMicTap() {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }
            let samples = Self.extractMono(buffer)
            guard !samples.isEmpty else { return }
            self.onBuffer?(samples, CACurrentMediaTime())
        }
    }

    // MARK: - Playback (used by MacTts to route TTS through the shared VPIO engine)

    /// Schedule an already-VP-mono buffer for playback on the shared engine.
    func schedulePlayback(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)? = nil) {
        guard started else { return }
        if !player.isPlaying { player.play() }
        playbackRms = Self.bufferRms(buffer)
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            self?.playbackRms = 0
            completion?()
        }
    }

    /// Stop any in-flight playback immediately (barge-in / interruption).
    func stopPlayback() {
        guard started else { return }
        playbackRms = 0
        player.stop()
    }

    private static func extractMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        let n = Int(buffer.frameLength)
        // VPIO reports a 9ch layout whose ch0 is a dead AEC reference channel
        // (digital silence); the AEC-processed near-end mic is on ch1. A plain
        // mono route (some devices/routes) carries the real signal on ch0.
        let src = Int(buffer.format.channelCount) > 1 ? 1 : 0
        return Array(UnsafeBufferPointer(start: ch[src], count: n))
    }

    private static func bufferRms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { let s = ch[0][i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
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
