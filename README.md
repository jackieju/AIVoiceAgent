# AIVoiceAgent

纯语音直连大模型的 macOS 对话助手。不用碰键盘、不用打字、没有触发词——像跟人聊天一样：你说话，停顿后自动提交给大模型，回复用语音朗读出来；你随时开口就能打断它（barge-in）。

内置声学回声消除（AEC），所以扬声器放出来的朗读声不会被麦克风当成你的话再听回去。

## 功能

- **自然断句**：基于能量的 VAD 检测你说完了没，停顿即自动提交，无需按键、无需触发词。
- **流式朗读**：大模型一边流式返回，一边按句子朗读，不用等整段说完。
- **随时打断**：朗读过程中你一开口，立即停止朗读、重新聆听（barge-in）。
- **回声消除**：VPIO + AEC，朗读声不会污染识别。
- **上下文压缩**（可选）：接入 NVP server，长对话自动压缩历史，省 token。找不到 NVP 时自动降级为直接对话，不影响使用。

## 依赖

- macOS 13 及以上
- Swift 5.9+（`swift build` 用）
- 一个可访问的大模型 API（Anthropic 或 OpenAI 兼容接口，例如本地 hyproxy）
- 麦克风、语音识别权限

## 编译

```bash
cd AIVoiceAgent
swift build -c release
```

产物在 `.build/release/VoiceAgentMac`。若已用脚本打包成 `.app`（见下文），直接双击运行即可。

## 配置

配置文件默认读取 `~/.config/aivoiceagent/config.json`。仓库根目录提供了 `config.example.json` 作为模板：

```bash
mkdir -p ~/.config/aivoiceagent
cp config.example.json ~/.config/aivoiceagent/config.json
```

样例里 `apiKey` 写的是 `{env:AIVOICEAGENT_API_KEY}`，表示从环境变量读取（避免把密钥写进文件）。运行前先导出：

```bash
export AIVOICEAGENT_API_KEY=你的key
```

也可以直接把 key 明文填进 `config.json` 的 `apiKey` 字段。

字段说明：

| 字段 | 说明 |
|---|---|
| `model` | 模型名，如 `claude-opus-4-8` |
| `provider.type` | `anthropic`（走 `/v1/messages`）或 `openai`（走 `/chat/completions`） |
| `provider.baseURL` | API 基地址。**Anthropic 填到 `.../anthropic`（不带 `/v1`）**，程序会自动拼 `/v1/messages`；**OpenAI 填到 `.../openai/v1`**，程序会自动拼 `/chat/completions` |
| `provider.apiKey` | API key。支持 `{env:VAR_NAME}` 从环境变量读取 |
| `systemPrompt` | 系统提示词。样例里已写好「语音场景」提示（回复口语化、不用 markdown） |
| `voice.ttsVoice` | 朗读语言/语音，如 `zh-CN` |
| `voice.sttLocale` | 识别语言，如 `zh-CN` |
| `nvp.enabled` | 是否启用上下文压缩，`false` 则完全不调 NVP |
| `nvp.binaryPath` | NVP server 可执行文件路径（见下文说明） |
| `nvp.dbPath` | 语音对话专用记忆库路径（独立于主库，避免污染） |
| `nvp.projectId` | 记忆分区标识 |

### 关于 NVP（上下文压缩，可选）

上下文压缩不是本项目自己实现的，而是调用另一个项目 `AIAgentLocalMemory` 编译出的独立程序 `nvp-server`。它是一个约 63MB 的独立二进制，通过 stdin/stdout 的 JSON-RPC 通信，只负责把长对话历史压缩成更省 token 的形式。

`config.json` 里的 `nvp.binaryPath` 指向这个二进制。默认值指向：

```
~/Desktop/ju/projects/AIAgentLocalMemory/packages/server/dist/nvp-server
```

如果这个文件不存在（比如换了电脑、移动了目录、或没编译），**程序会自动跳过压缩、正常对话，不会崩溃**。想要压缩功能，先在 `AIAgentLocalMemory` 项目里编译：

```bash
cd AIAgentLocalMemory/packages/server
bun run build   # 产出 dist/nvp-server
```

短对话（累计不到 16000 字符）本来就不会调 NVP——新会话没多少历史，压缩纯属浪费。只有对话变长后才会触发。

## 权限

首次运行会依次弹出两个系统权限请求：

1. **麦克风** — 系统设置 > 隐私与安全性 > 麦克风
2. **语音识别** — 系统设置 > 隐私与安全性 > 语音识别

两个都要允许，否则无法工作。若被拒绝，去上面的系统设置里手动打开，再重启程序。

## 运行

命令行方式：

```bash
.build/release/VoiceAgentMac
# 或指定配置：
.build/release/VoiceAgentMac --config /path/to/config.json
```

启动后开始说话，停顿即自动提交。说话可打断助手朗读。`Ctrl+C` 退出。

状态提示：

- `[闲置]` idle
- `[🎙️ 聆听中…]` 正在听你说话
- `[🤔 思考中…]` 等大模型回复
- `[🔊 说话中…]` 正在朗读回复

## 架构

分两层，为将来跨平台预留：

- **`VoiceAgentCore`（平台无关）**
  - `Config.swift` — 配置加载，支持 `{env:VAR}` 展开
  - `LLMProvider.swift` — Anthropic SSE / OpenAI 兼容流式接口
  - `VAD.swift` — 能量 VAD（RMS + 自适应噪声底 + hangover）
  - `VoiceSession.swift` — 对话编排器，状态机 `idle→listening→thinking→speaking` + barge-in + 流式分句
  - `NVPClient.swift` — NVP server 子进程客户端（JSON-RPC over stdin/stdout）
  - 四个协议 `AudioIO`/`Stt`/`Tts`/`Vad` 定义平台接口
- **`VoiceAgentMac`（macOS 实现）**
  - `MacAudioIO.swift` — VPIO 引擎，同一 engine 做麦克风采集 + TTS 播放（保证 AEC 参考信号）
  - `MacStt.swift` — SFSpeech 离线识别
  - `MacTts.swift` — 走同 engine 播放（不用 `synth.speak`，否则绕过 AEC）
  - `AECProbe.swift` — AEC 回声泄漏排雷工具（`--probe` 运行）
  - `main.swift` — 组装入口

### AEC 排雷

```bash
.build/release/VoiceAgentMac --probe
```

会测量扬声器→麦克风的回声泄漏倍数。目标 < 3x（已验证 0.27x）。用内置麦克风 + 内置扬声器时效果最好。

## 已知限制

- v1 是命令行 + 可选 `.app` 包装，无独立设置界面，配置靠改 json。
- NVP 二进制路径默认写死指向同级项目位置，换环境需在 config 里改 `nvp.binaryPath`。
- 目前只做 macOS；core 层已抽象协议，Windows 实现留待将来。
