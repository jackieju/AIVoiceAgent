import Foundation
import AVFoundation
import AppKit

final class AECProbe: NSObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private var converter: AVAudioConverter?
    private var playerFormat: AVAudioFormat!
    private var samples: [Float] = []
    private let lock = NSLock()

    private func rmsChannel0(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        let data = ch[0]
        var sumSquares: Float = 0
        for i in 0..<n { sumSquares += data[i] * data[i] }
        return (sumSquares / Float(n)).squareRoot()
    }

    private func averageRMS(overSeconds seconds: Double) -> Float {
        lock.lock(); samples.removeAll(); lock.unlock()
        Thread.sleep(forTimeInterval: seconds)
        lock.lock(); let collected = samples; lock.unlock()
        guard !collected.isEmpty else { return 0 }
        return collected.reduce(0, +) / Float(collected.count)
    }

    private func speakThroughEngine(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5
        synth.write(utterance) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            let src = pcm.format
            if self.converter == nil || self.converter?.inputFormat != src {
                self.converter = AVAudioConverter(from: src, to: self.playerFormat)
            }
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * self.playerFormat.sampleRate / src.sampleRate) + 1024
            guard let converter = self.converter,
                  let out = AVAudioPCMBuffer(pcmFormat: self.playerFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            var consumed = false
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return pcm
            }
            self.player.scheduleBuffer(out, completionCallbackType: .dataPlayedBack)
        }
    }

    func run() {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
        sem.wait()
        guard granted else {
            print("❌ 麦克风权限被拒绝。请到 系统设置 > 隐私与安全性 > 麦克风 授权后重试。")
            exit(1)
        }

        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = false
            print("✅ VoiceProcessingIO 已开启, AGC 已关闭")
        } catch {
            print("❌ 无法开启 VoiceProcessingIO: \(error)")
            exit(1)
        }

        engine.attach(player)
        playerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)

        let inputFormat = input.outputFormat(forBus: 0)
        print("麦克风格式(VP后): \(Int(inputFormat.sampleRate))Hz, \(inputFormat.channelCount)ch (只取 ch0)")
        print("播放格式: \(Int(playerFormat.sampleRate))Hz, \(playerFormat.channelCount)ch")

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let r = self.rmsChannel0(buffer)
            self.lock.lock(); self.samples.append(r); self.lock.unlock()
        }
        engine.prepare()
        do { try engine.start() } catch {
            print("❌ 音频引擎启动失败: \(error)"); exit(1)
        }
        player.play()

        print("\n=== AEC 排雷 v2 (正确接线: TTS 经 VP engine 播放) ===")
        print("请用内置扬声器外放, 切勿接外接音箱/耳机, 全程保持安静\n")

        print("[阶段A] 静默测环境底噪 (2.5s) …")
        let baseline = averageRMS(overSeconds: 2.5)
        print(String(format: "  底噪 baseline RMS = %.5f\n", baseline))

        print("[阶段B] TTS 经 VP engine 播放期间测麦克风 (3s) …")
        speakThroughEngine("这是回声消除测试。如果接线正确，麦克风里我现在播放的声音应该被消掉。一二三四五六七八九十。")
        Thread.sleep(forTimeInterval: 0.5)
        let duringTTS = averageRMS(overSeconds: 3.0)
        print(String(format: "  TTS 期间麦克风 RMS = %.5f\n", duringTTS))

        player.stop()
        engine.stop()
        try? input.setVoiceProcessingEnabled(false)

        // 正确接线后 AEC 把 TTS 回声消到接近底噪; 残留声学/非线性路径使比值不会到 1.0x,
        // 内置扬声器+麦克风典型残留 1.3~2.5x。仍 >3x 多为 AGC 未关/接了外接音箱/切VP时engine未停。
        let ratio = baseline > 0.00001 ? duringTTS / baseline : duringTTS / 0.00001
        print("=== 结论 ===")
        print(String(format: "底噪=%.5f  TTS期间=%.5f  倍数=%.2fx", baseline, duringTTS, ratio))
        if ratio < 3.0 {
            print("✅ AEC 有效: 全双工 barge-in 可行 (TTS 说话时可开麦听用户插话)。")
        } else {
            print("⚠️  仍偏高: 排查 AGC / 外接音箱耳机 / engine 是否停止时才切 VP。")
        }
        exit(0)
    }
}

let probe = AECProbe()
DispatchQueue.global().async { probe.run() }
RunLoop.main.run()
