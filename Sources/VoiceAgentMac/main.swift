import Foundation
import AVFoundation
import Speech
import VoiceAgentCore

func requestPermissions(_ completion: @escaping (Bool) -> Void) {
    let sem = DispatchSemaphore(value: 0)
    var micOK = false
    AVCaptureDevice.requestAccess(for: .audio) { micOK = $0; sem.signal() }
    sem.wait()
    guard micOK else {
        print("❌ 麦克风权限被拒绝。系统设置 > 隐私与安全性 > 麦克风")
        completion(false); return
    }
    MacStt.requestAuthorization { sttOK in
        guard sttOK else {
            print("❌ 语音识别权限被拒绝。系统设置 > 隐私与安全性 > 语音识别")
            completion(false); return
        }
        completion(true)
    }
}

let args = CommandLine.arguments

if args.contains("--probe") {
    let probe = AECProbe()
    DispatchQueue.global().async { probe.run() }
    RunLoop.main.run()
}

let configPath = args.firstIndex(of: "--config").flatMap { idx -> String? in
    idx + 1 < args.count ? args[idx + 1] : nil
} ?? "~/.config/aivoiceagent/config.json"

let config: AgentConfig
do {
    config = try AgentConfig.load(from: configPath)
} catch {
    print("❌ 配置加载失败: \(error)")
    print("   用 --config <路径> 指定，或创建 \(configPath)")
    exit(1)
}

requestPermissions { granted in
    guard granted else { exit(1) }

    let audio = MacAudioIO()
    let tts = MacTts(audio: audio, voiceLanguage: config.voice?.ttsVoice)
    let stt = MacStt(locale: config.voice?.sttLocale ?? "zh-CN")
    let vad = EnergyVad()
    let llm = makeProvider(from: config)

    var nvpClient: NVPClient?
    if config.nvp?.enabled ?? true {
        let defaultBinary = "~/Desktop/ju/projects/AIAgentLocalMemory/packages/server/dist/nvp-server"
        let defaultDB = "~/Library/Application Support/AIVoiceAgent/voice-memory.db"
        let rawDB = config.nvp?.dbPath ?? defaultDB
        let nvpConfig = NVPClient.Config(
            binaryPath: config.nvp?.binaryPath ?? defaultBinary,
            dbPath: (rawDB as NSString).expandingTildeInPath,
            projectId: config.nvp?.projectId ?? "voice"
        )
        let dbDir = (nvpConfig.dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        let client = NVPClient(config: nvpConfig)
        client.start()
        nvpClient = client.isHealthy ? client : nil
    }

    let session = VoiceSession(audio: audio, vad: vad, stt: stt, tts: tts, llm: llm, nvp: nvpClient)
    session.onState = { state in
        let label: String
        switch state {
        case .idle: label = "闲置"
        case .listening: label = "🎙️  聆听中…"
        case .thinking: label = "🤔 思考中…"
        case .speaking: label = "🔊 说话中…"
        }
        print("[\(label)]")
    }
    session.onUserText = { print("👤 你: \($0)") }
    session.onAgentText = { print("🤖 助手: \($0)") }

    do {
        try session.start()
        print("=== AI Voice Agent v\(VoiceAgent.version) ===")
        print("model=\(config.model) provider=\(config.provider.type)")
        print("开始说话，停顿后自动提交。说话可打断助手。Ctrl+C 退出。\n")
    } catch {
        print("❌ 启动失败: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
