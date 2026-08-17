import XCTest
@testable import VoiceAgentCore

final class DoubleTalkDetectorTests: XCTestCase {

    private func makeDetector(
        onsetGraceMs: Double = 100,
        sustainMs: Double = 180,
        alpha: Float = 2.5,
        absoluteFloor: Float = 0.012
    ) -> (DoubleTalkDetector, () -> Int) {
        let dtd = DoubleTalkDetector(onsetGraceMs: onsetGraceMs, sustainMs: sustainMs, alpha: alpha, absoluteFloor: absoluteFloor)
        var fires = 0
        dtd.onBargeIn = { fires += 1 }
        return (dtd, { fires })
    }

    func testDisarmedNeverFires() {
        let (dtd, fires) = makeDetector()
        for i in 0..<100 { dtd.process(micRms: 1.0, refRms: 0, now: Double(i) * 0.02) }
        XCTAssertEqual(fires(), 0)
    }

    func testOnsetGraceSwallowsEarlyResidue() {
        let (dtd, fires) = makeDetector(onsetGraceMs: 100, sustainMs: 180)
        dtd.arm()
        dtd.process(micRms: 1.0, refRms: 0, now: 0.0)
        dtd.process(micRms: 1.0, refRms: 0, now: 0.05)
        dtd.process(micRms: 1.0, refRms: 0, now: 0.09)
        XCTAssertEqual(fires(), 0)
    }

    func testSustainedRealSpeechFiresAfterGrace() {
        let (dtd, fires) = makeDetector(onsetGraceMs: 100, sustainMs: 180)
        dtd.arm()
        dtd.process(micRms: 0.001, refRms: 0, now: 0.0)
        var t = 0.12
        while t < 0.40 {
            dtd.process(micRms: 0.05, refRms: 0, now: t)
            t += 0.02
        }
        XCTAssertEqual(fires(), 1)
    }

    func testBurstyEchoBelowSustainDoesNotFire() {
        let (dtd, fires) = makeDetector(onsetGraceMs: 100, sustainMs: 180)
        dtd.arm()
        dtd.process(micRms: 0.001, refRms: 0.02, now: 0.0)
        dtd.process(micRms: 0.05, refRms: 0.02, now: 0.12)
        dtd.process(micRms: 0.05, refRms: 0.02, now: 0.14)
        dtd.process(micRms: 0.001, refRms: 0.02, now: 0.16)
        dtd.process(micRms: 0.05, refRms: 0.02, now: 0.18)
        dtd.process(micRms: 0.05, refRms: 0.02, now: 0.20)
        XCTAssertEqual(fires(), 0)
    }

    func testReferenceGatingToleratesLoudPlayback() {
        let (dtd, fires) = makeDetector(onsetGraceMs: 100, sustainMs: 180, alpha: 2.5)
        dtd.arm()
        dtd.process(micRms: 0.001, refRms: 0.1, now: 0.0)
        // Mic energy high in absolute terms but below alpha*refRMS (2.5*0.1=0.25):
        // our own loud TTS bleeding through, must be tolerated.
        var t = 0.12
        while t < 0.50 {
            dtd.process(micRms: 0.2, refRms: 0.1, now: t)
            t += 0.02
        }
        XCTAssertEqual(fires(), 0)
    }

    func testReferenceGatingFiresWhenMicExceedsAlphaRef() {
        let (dtd, fires) = makeDetector(onsetGraceMs: 100, sustainMs: 180, alpha: 2.5)
        dtd.arm()
        dtd.process(micRms: 0.001, refRms: 0.05, now: 0.0)
        // Mic well above alpha*refRMS (2.5*0.05=0.125), sustained -> real talk.
        var t = 0.12
        while t < 0.50 {
            dtd.process(micRms: 0.3, refRms: 0.05, now: t)
            t += 0.02
        }
        XCTAssertEqual(fires(), 1)
    }

    func testFiresOnlyOnce() {
        let (dtd, fires) = makeDetector(onsetGraceMs: 100, sustainMs: 180)
        dtd.arm()
        dtd.process(micRms: 0.001, refRms: 0, now: 0.0)
        var t = 0.12
        while t < 0.80 {
            dtd.process(micRms: 0.05, refRms: 0, now: t)
            t += 0.02
        }
        XCTAssertEqual(fires(), 1)
    }

    func testReArmAfterDisarm() {
        let (dtd, fires) = makeDetector(onsetGraceMs: 100, sustainMs: 180)
        dtd.arm()
        dtd.process(micRms: 0.001, refRms: 0, now: 0.0)
        var t = 0.12
        while t < 0.40 { dtd.process(micRms: 0.05, refRms: 0, now: t); t += 0.02 }
        XCTAssertEqual(fires(), 1)

        dtd.disarm()
        dtd.arm()
        dtd.process(micRms: 0.001, refRms: 0, now: 1.0)
        t = 1.12
        while t < 1.40 { dtd.process(micRms: 0.05, refRms: 0, now: t); t += 0.02 }
        XCTAssertEqual(fires(), 2)
    }

    func testAbsoluteFloorGatesQuietMicWithSilentPlayback() {
        let (dtd, fires) = makeDetector(onsetGraceMs: 100, sustainMs: 180, absoluteFloor: 0.012)
        dtd.arm()
        dtd.process(micRms: 0.001, refRms: 0, now: 0.0)
        // Sustained mic below absoluteFloor with no playback -> ambient noise.
        var t = 0.12
        while t < 0.50 { dtd.process(micRms: 0.008, refRms: 0, now: t); t += 0.02 }
        XCTAssertEqual(fires(), 0)
    }
}
