import Foundation
import AVFoundation
import AppKit

final class AECProbe: NSObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
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

    private func synthesizeToBuffer(_ text: String) -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5

        var chunks: [AVAudioPCMBuffer] = []
        let sem = DispatchSemaphore(value: 0)
        synth.write(utterance) { buffer in
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                chunks.append(pcm)
            } else {
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 10)
        guard let first = chunks.first else { return nil }
        let format = first.format
        let total = chunks.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard total > 0,
              let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        for chunk in chunks {
            guard chunk.format == format,
                  let dst = combined.floatChannelData,
                  let src = chunk.floatChannelData else { continue }
            let offset = Int(combined.frameLength)
            let n = Int(chunk.frameLength)
            for c in 0..<Int(format.channelCount) {
                memcpy(dst[c] + offset, src[c], n * MemoryLayout<Float>.size)
            }
            combined.frameLength += chunk.frameLength
        }
        return combined
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

        print("[准备] 合成 TTS 到缓冲 …")
        guard let ttsBuffer = synthesizeToBuffer("这是回声消除测试。如果接线正确，麦克风里我现在播放的声音应该被消掉。一二三四五六七八九十。") else {
            print("❌ TTS 合成失败"); exit(1)
        }
        print("  TTS 缓冲格式: \(Int(ttsBuffer.format.sampleRate))Hz, \(ttsBuffer.format.channelCount)ch, \(ttsBuffer.frameLength) frames")

        // VPIO wiring order is load-bearing (Oracle diagnosis of -10875):
        // enable VP before any attach/connect; never query mainMixer.outputFormat
        // (pins it to 44.1/2ch and defeats VP's 48k renegotiation); connect player
        // with the TTS buffer's own format; tap inputFormat (post-AEC mono) not
        // outputFormat (raw 9ch); never manually connect mainMixer->outputNode.
        let input = engine.inputNode
        let output = engine.outputNode
        do {
            // VP on input-only leaves outputNode a plain HAL output that fights the shared VPIO unit -> -10875 at outputNode kAUInitialize; must enable on both.
            try input.setVoiceProcessingEnabled(true)
            try output.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = false
            print("✅ VoiceProcessingIO 已开启(input+output), AGC 已关闭")
        } catch {
            print("❌ 无法开启 VoiceProcessingIO: \(error)")
            exit(1)
        }

        engine.attach(player)

        let hwFormat = output.inputFormat(forBus: 0)
        guard let vpMono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: hwFormat.sampleRate,
                                         channels: 1, interleaved: false) else {
            print("❌ 无法构造 VP 边界格式"); exit(1)
        }
        // On macOS+VP the implicit mainMixer->output edge inherits 44.1/2ch and fights the 48k VPIO bus -> -10875; the mixer->output edge MUST be explicit at hwFormat, and the player edge must be hardware-rate mono (never the raw 22050 TTS format).
        engine.connect(player, to: engine.mainMixerNode, format: vpMono)
        engine.connect(engine.mainMixerNode, to: output, format: hwFormat)

        // The VP route reports a 9ch format whose channel 0 is a dead/reference channel (digital silence); installing the tap with an explicit mono format forces the engine to deliver the real AEC-processed mono signal instead.
        let tapFormat = vpMono
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let r = self.rmsChannel0(buffer)
            self.lock.lock(); self.samples.append(r); self.lock.unlock()
        }

        // setVoiceProcessingEnabled makes the engine self-stop via a config change; must restart on the notification or start() silently leaves it not running.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            if !self.engine.isRunning { try? self.engine.start() }
        }

        engine.prepare()
        do { try engine.start() } catch {
            print("❌ 音频引擎启动失败: \(error)"); exit(1)
        }
        let liveMic = input.outputFormat(forBus: 0)
        print("麦克风格式(post-AEC): \(Int(liveMic.sampleRate))Hz, \(liveMic.channelCount)ch")

        print("\n=== AEC 排雷 v3 (Oracle 修正接线) ===")
        print("请用内置扬声器外放, 切勿接外接音箱/耳机, 全程保持安静\n")

        print("[阶段A] 静默测环境底噪 (2.5s) …")
        let baseline = averageRMS(overSeconds: 2.5)
        print(String(format: "  底噪 baseline RMS = %.5f\n", baseline))

        print("[阶段B] TTS 经 VP engine 播放期间测麦克风 (播放时长) …")
        guard let converter = AVAudioConverter(from: ttsBuffer.format, to: vpMono) else {
            print("❌ 无法构造 TTS 重采样器"); exit(1)
        }
        let ratioSR = vpMono.sampleRate / ttsBuffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(ttsBuffer.frameLength) * ratioSR + 4096)
        guard let playBuffer = AVAudioPCMBuffer(pcmFormat: vpMono, frameCapacity: outCap) else {
            print("❌ 无法分配播放缓冲"); exit(1)
        }
        var convErr: NSError?
        var fed = false
        _ = converter.convert(to: playBuffer, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return ttsBuffer
        }
        if let convErr = convErr { print("❌ TTS 重采样失败: \(convErr)"); exit(1) }
        player.scheduleBuffer(playBuffer, at: nil, options: [], completionHandler: nil)
        player.play()
        Thread.sleep(forTimeInterval: 0.3)
        let ttsSeconds = Double(ttsBuffer.frameLength) / ttsBuffer.format.sampleRate
        let duringTTS = averageRMS(overSeconds: min(max(ttsSeconds - 0.3, 1.0), 5.0))
        print(String(format: "  TTS 期间麦克风 RMS = %.5f\n", duringTTS))

        player.stop()
        engine.stop()
        try? input.setVoiceProcessingEnabled(false)

        // 正确接线后 AEC 把 TTS 回声消到接近底噪; 残留声学/非线性路径使比值不会到 1.0x,
        // 内置扬声器+麦克风典型残留 1.3~2.5x。仍 >3x 多为 AGC 未关/接了外接音箱/默认输出非内置扬声器。
        let ratio = baseline > 0.00001 ? duringTTS / baseline : duringTTS / 0.00001
        print("=== 结论 ===")
        print(String(format: "底噪=%.5f  TTS期间=%.5f  倍数=%.2fx", baseline, duringTTS, ratio))
        if ratio < 3.0 {
            print("✅ AEC 有效: 全双工 barge-in 可行 (TTS 说话时可开麦听用户插话)。")
        } else {
            print("⚠️  仍偏高: 排查 AGC / 外接音箱耳机 / 默认输出是否为内置扬声器 / 系统采样率是否 48kHz。")
        }
        exit(0)
    }
}
