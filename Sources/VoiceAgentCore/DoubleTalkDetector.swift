import Foundation

/// Suppresses false barge-ins while the agent is speaking. VPIO's hardware AEC
/// only partially cancels our own TTS from the mic, so a plain energy VAD keeps
/// mistaking echo residue for the user talking and aborts the reply.
///
/// Three physically-motivated gates (per Oracle design), applied only while the
/// session is in `.speaking` (the caller gates that):
///   1. onset grace — the AEC adaptive filter needs ~100ms to converge when
///      playback starts; residue is largest there, so ignore it.
///   2. reference gating (α·refRMS) — echo residue is proportional to how loud
///      we are playing. Require mic energy to exceed α times the current
///      playback RMS. When playback is silent this degrades to `absoluteFloor`.
///   3. sustain — echo residue is bursty (tracks the TTS envelope); real speech
///      is a sustained envelope. Require the candidate condition to hold for
///      `sustainMs` continuously before declaring a real barge-in.
///
/// The onset reference is captured from the first `process` frame after `arm()`,
/// so all timing uses the audio tap's own clock and this type needs no
/// platform-specific time source.
public final class DoubleTalkDetector {
    public var onBargeIn: (() -> Void)?

    private let onsetGraceSec: Double
    private let sustainSec: Double
    private let alpha: Float
    private let absoluteFloor: Float

    private var armedAt: Double?
    private var candidateSince: Double?
    private var active = false

    public init(
        onsetGraceMs: Double = 100,
        sustainMs: Double = 180,
        alpha: Float = 2.5,
        absoluteFloor: Float = 0.012
    ) {
        self.onsetGraceSec = onsetGraceMs / 1000.0
        self.sustainSec = sustainMs / 1000.0
        self.alpha = alpha
        self.absoluteFloor = absoluteFloor
    }

    public func arm() {
        armedAt = nil
        candidateSince = nil
        active = true
    }

    public func disarm() {
        armedAt = nil
        candidateSince = nil
        active = false
    }

    public func process(micRms: Float, refRms: Float, now: Double) {
        guard active else { return }
        if armedAt == nil { armedAt = now }

        // (1) onset grace: swallow the AEC convergence window.
        if let start = armedAt, now - start < onsetGraceSec {
            candidateSince = nil
            return
        }

        // (2) reference gating: silent playback -> absoluteFloor, loud playback
        // -> tolerate proportionally more mic energy.
        let dynThreshold = max(absoluteFloor, alpha * refRms)

        // (3) sustain: candidate must persist to count as a real barge-in.
        if micRms > dynThreshold {
            if candidateSince == nil { candidateSince = now }
            if let since = candidateSince, now - since >= sustainSec {
                candidateSince = nil
                active = false
                onBargeIn?()
            }
        } else {
            candidateSince = nil
        }
    }
}
