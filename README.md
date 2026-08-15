# AIVoiceAgent

纯语音直连大模型的 macOS 对话助手。不用碰键盘、不用打字、没有触发词——像跟人聊天一样：你说话，停顿后自动提交给大模型，回复用语音朗读出来；你随时开口就能打断它（barge-in）。

内置声学回声消除（AEC），所以扬声器放出来的朗读声不会被麦克风当成你的话再听回去。

## 功能

- **自然断句**：基于能量的 VAD 检测你说完了没，停顿即自动提交，无需按键、无需触发词。
- **流式朗读**：大模型一边流式返回，一边按句子朗读，不用等整段说完。
- **随时打断**：朗读过程中你一开口，立即停止朗读、重新聆听（barge-in）。
- **回声消除**：VPIO + AEC，朗读声不会污染识别。
- **工具调用**：大模型可调用内置工具（读写文件、跑命令、搜索、抓网页）和外部 MCP 工具，多轮回路自动完成任务后语音播报结果（详见「工具系统」）。
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
| `maxRounds` | 单次对话里工具调用的最大轮数上限，默认 5（防止工具回路无限循环） |
| `mcpServers` | 外部 MCP 工具服务配置（见下文「工具系统」） |
| `nvp.enabled` | 是否启用上下文压缩，`false` 则完全不调 NVP |
| `nvp.binaryPath` | NVP server 可执行文件路径（见下文说明） |
| `nvp.dbPath` | 语音对话专用记忆库路径（独立于主库，避免污染） |
| `nvp.projectId` | 记忆分区标识 |

## 工具系统

大模型不只是聊天——它可以调用工具来读写文件、执行命令、联网搜索。你说一句「帮我看看某个文件里写了什么」「跑一下测试」，它会自己调工具完成，再用语音把结果讲给你听。

工具调用是流式的多轮回路：大模型可以连续调用多个工具、拿到结果后继续调，直到得出最终回答（受 `maxRounds` 上限约束）。工具执行期间会先播报一句桥接语（如「正在执行…」），执行结束后继续朗读结果。工具执行中你随时可以开口打断（barge-in）。

### 内置工具（无需配置，默认可用）

参数名与 opencode 对齐，方便迁移：

| 工具 | 作用 | 主要参数 |
|---|---|---|
| `read` | 读文件（支持目录列表、大文件按行 offset/limit） | `filePath`、`offset`、`limit` |
| `write` | 写文件（覆盖写，自动建目录） | `filePath`、`content` |
| `bash` | 执行 shell 命令（用 `workdir` 指定目录，勿用 `cd`） | `command`、`timeout`(毫秒)、`workdir` |
| `grep` | 按正则搜索文件内容 | `pattern`、`path`、`include` |
| `glob` | 按 glob 模式查找文件 | `pattern`、`path` |
| `webfetch` | 抓取网页内容 | `url`、`format` |

内置工具直接运行在你本机、以你的用户权限执行——`bash` 能跑任意命令、`write` 能覆盖文件。语音场景下无二次确认，请在信任的环境使用。

### MCP 工具（可选，扩展能力）

除内置工具外，可通过 [MCP（Model Context Protocol）](https://modelcontextprotocol.io) 接入第三方工具服务，无需改本项目代码。在 `config.json` 的 `mcpServers` 里按「名字 → 启动命令」配置，程序启动时会以子进程方式拉起这些 server（stdio JSON-RPC），把它们暴露的工具合并进工具集。

样例（接入官方文件系统 MCP server）：

```json
"mcpServers": {
  "filesystem": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents"]
  }
}
```

每个 MCP server 的配置字段：

| 字段 | 说明 |
|---|---|
| `command` | 启动 server 的可执行文件，如 `npx`、`uvx`、`node`、绝对路径 |
| `args` | 传给命令的参数数组（可选） |
| `env` | 额外环境变量（可选），如 API key |

常见公共 MCP server（社区维护，直接配即可用，无需自己写）：

- `@modelcontextprotocol/server-filesystem` — 受限目录内的文件读写
- `@modelcontextprotocol/server-github` — GitHub 仓库/Issue/PR 操作（需在 `env` 里配 token）
- `@modelcontextprotocol/server-fetch` — 网页抓取
- 更多见 [MCP servers 列表](https://github.com/modelcontextprotocol/servers)

MCP server 是异步后台连接的：即使某个 server 启动失败或很慢，也不会阻塞对话——它的工具连上后才会加入工具集，主窗口会提示「已连接 N 个 MCP 工具」。不需要 MCP 时，删掉 `mcpServers` 字段或留空即可，只用内置工具。

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
- `[🛠️ 执行中…]` 正在调用工具
- `[🔊 说话中…]` 正在朗读回复

## 架构

分两层，为将来跨平台预留：

- **`VoiceAgentCore`（平台无关）**
  - `Config.swift` — 配置加载，支持 `{env:VAR}` 展开
  - `LLMProvider.swift` — Anthropic SSE / OpenAI 兼容流式接口（含 tool_use / tool_calls 流式解析）
  - `VAD.swift` — 能量 VAD（RMS + 自适应噪声底 + hangover）
  - `VoiceSession.swift` — 对话编排器，状态机 `idle→listening→thinking→working→speaking` + barge-in + 流式分句
  - `AgentLoop.swift` — 多轮工具调用回路（流式喂 TTS、并发执行工具、错误回填、barge-in 丢弃结果）
  - `ToolTypes.swift` — `Tool` 协议 + 线程安全 `ToolRegistry`
  - `BuiltinTools.swift` / `SearchTools.swift` / `WebTool.swift` — 内置工具 read/write/bash/grep/glob/webfetch
  - `MCPClient.swift` — MCP stdio 客户端（JSON-RPC 2.0，握手 + tools/list + tools/call）
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

## License

Copyright (C) 2026 Jackie Ju

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.
