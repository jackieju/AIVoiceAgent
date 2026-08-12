import Foundation

public final class EnergyVad: Vad {
    public var onSpeechStart: (() -> Void)?
    public var onSpeechEnd: (() -> Void)?

    private var noiseFloor: Float
    private let thresholdMultiplier: Float
    private let hangover: TimeInterval
    private let noiseAdaptRate: Float
    private let minThreshold: Float

    private var isSpeaking = false
    private var lastVoiceTime = Date()

    public init(
        initialNoiseFloor: Float = 0.005,
        thresholdMultiplier: Float = 3.0,
        hangoverSeconds: TimeInterval = 0.8,
        noiseAdaptRate: Float = 0.97,
        minThreshold: Float = 0.003
    ) {
        self.noiseFloor = initialNoiseFloor
        self.thresholdMultiplier = thresholdMultiplier
        self.hangover = hangoverSeconds
        self.noiseAdaptRate = noiseAdaptRate
        self.minThreshold = minThreshold
    }

    public func process(rms: Float) {
        let threshold = max(noiseFloor * thresholdMultiplier, minThreshold)
        let now = Date()
        if rms > threshold {
            lastVoiceTime = now
            if !isSpeaking {
                isSpeaking = true
                onSpeechStart?()
            }
        } else {
            noiseFloor = noiseAdaptRate * noiseFloor + (1 - noiseAdaptRate) * rms
            if isSpeaking, now.timeIntervalSince(lastVoiceTime) >= hangover {
                isSpeaking = false
                onSpeechEnd?()
            }
        }
    }

    public func reset() {
        isSpeaking = false
        lastVoiceTime = Date()
    }
}
