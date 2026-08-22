# AIVoiceAgent 跨平台插件框架架构规范

> 本文档是 AIVoiceAgent 从「Swift 全栈语音 app」演进为「跨平台语音 AI Agent（脚本核心 + 可插拔外壳 + 任意语言插件 + Web 控制界面）」的架构规范。
> 所有设计决策均已与项目所有者逐条确认。实现前以本文为准。

---

## 0. 目标与四条硬性诉求

这套系统是一个**独立的、能力很强的语音 AI Agent**，可以脱离 OpenCode 独立工作；「接入 OpenCode」只是它的一个插件能力，不是它存在的目的。

必须同时满足的四条诉求：

1. **跨平台**：Mac 先行，之后要能上 Windows / Linux。
2. **核心用脚本语言**：底层大脑用脚本语言（Node/TS）写，一份代码跨平台复用。
3. **Web 控制界面**：可通过浏览器访问本地 Web 页面操作 app（天然跨平台）。
4. **插件机制**：支持插件扩展，且**插件可用任意语言编写**。

---

## 1. 选定路线：方案 A（抽核心，不是各平台整体重写）

在两条跨平台路线中明确选择 **方案 A**：

- **方案 A（选定）**：把与语音无关的部分（AgentLoop / 大模型交互 / 工具系统）抽出来用 Node/TS 写成**跨平台大脑**，只写一次；每个平台各自写一个**音频外壳**（薄）。
- **方案 B（否决）**：每上一个新平台，就把整个 Swift app（外壳 + AgentLoop）用该平台语言整体重写一遍。

**为什么选 A：**

1. **写一次 vs 写 N 次**：AgentLoop/工具/大模型交互只写一次（Node），所有平台共享。方案 B 要把最复杂的这坨逻辑维护 N 份。
2. **一致性**：方案 B 会陷入「多套实现漂移」——Mac 修的 bug Windows 没修、Mac 加的工具 Windows 没有。
3. **音频外壳本来就躲不掉分平台写**（AEC/VAD 绑平台：Mac 用 CoreAudio/VPIO，Windows 用 WASAPI）。方案 A 是「只重写躲不掉的（音频外壳）」，方案 B 是「连能共享的（大脑）也重写」。
4. **渐进路径**：方案 A 下，浏览器外壳就是零安装全平台入口，Windows 用户开浏览器即可用；想要高质量再补 Windows 原生外壳。方案 B 上 Windows 的唯一路径就是「整体重写」，一上来就是大工程。

---

## 2. 架构总览（四层）

```
┌─────────────────────────────────────────────────────────────┐
│  L4  外壳 Shell（用户入口，平台特定，讲同一种 WebSocket 话）    │
│      · Swift(Mac)  : VPIO/AEC/VAD/whisper/Edge-TTS/barge-in  │
│      · 浏览器       : Web Speech API（STT+TTS）               │
│      · 微信 Shell   : iLink + wong2/weixin-agent-sdk（见 §7） │
│      职责：把「语音/输入 ↔ 文本」这件事做干净                  │
├─────────────────────────────────────────────────────────────┤
│  L3  传输 Transport（统一协议，WebSocket + JSON）             │
│      所有外壳讲同一种话：utterance / media / speak / …        │
├─────────────────────────────────────────────────────────────┤
│  L2  核心 Brain（Node/TS，跨平台，单进程）                    │
│      · 会话 / 模式栈管理                                       │
│      · 意图路由器（读配置 + LLM 判别 + 关键词快路）           │
│      · AgentLoop / 工具调用 / LLM 交互                        │
│      · 插件宿主（拉起子进程插件、走 JSON-RPC）                │
│      · Web UI HTTP server                                    │
├─────────────────────────────────────────────────────────────┤
│  L1  插件 Plugins（子进程，任意语言）                         │
│      · opencode 插件、其他插件…                              │
│      · 通过 stdin/stdout JSON-RPC 与核心通信                 │
└─────────────────────────────────────────────────────────────┘
```

### 关键边界（决定了整套系统的稳定性）

- **L4 ↔ L3 边界 = 文本（+媒体文件路径）**。外壳只吐/收文本和控制事件，**音频字节永不跨这条边界**。这是保住 Swift AEC 质量的唯一办法（AEC 一旦离开 CoreAudio 回路就废）。
- **L2 ↔ L1 边界 = 子进程 JSON-RPC**。插件跑在独立子进程，因此**可以用任意语言写**。
- **跨语言只发生在两条边界上**：外壳↔核心（WebSocket）、核心↔插件（子进程 JSON-RPC）。核心内部（意图路由/模式栈/AgentLoop）全是同进程 Node 代码，无跨语言开销。

### 进程拓扑

```
┌──────────────┐  WebSocket   ┌────────────────────┐
│ Swift MacApp │ ◄──────────► │                    │
│  (音频外壳)   │              │   Node 核心 Brain   │  子进程 JSON-RPC
└──────────────┘              │   ├─ 意图路由       │  ┌──► opencode 插件(任意语言)
┌──────────────┐  WebSocket   │   ├─ 模式栈        │  ├──► 插件 B (任意语言)
│  浏览器       │ ◄──────────► │   ├─ AgentLoop     │──┤
│ (Web Speech) │              │   ├─ 插件宿主       │  │  子进程/HTTP
└──────────────┘              │   └─ Web UI server │  ├──► NVP (Bun, 上下文压缩)
┌──────────────┐  WebSocket   │                    │  └──► Edge-TTS / OpenCode headless
│  微信 Shell   │ ◄──────────► │                    │
└──────────────┘              └────────────────────┘
```

---

## 3. 外壳 ↔ 核心：WebSocket 协议（MVP 就要定死）

所有外壳（Swift / 浏览器 / 微信）讲同一种 WebSocket + JSON。**协议是整套系统的契约，MVP 阶段就要定稳，后面加外壳/插件全靠它。**

```jsonc
// ── 外壳 → 核心 ──
{"type":"hello",     "shell":"mac-swift" | "browser" | "wechat", "session":"shell-1"}
{"type":"utterance", "text":"用户说完的一整句", "session":"shell-1"}
{"type":"partial",   "text":"实时中间结果"}          // 可选，供 UI 显示
{"type":"barge_in"}                                  // 用户打断，核心停 TTS
{"type":"media",     "kind":"voice"|"file"|"image",  // 微信等外壳的非文本输入
                     "text":"外壳自带 ASR 转写(可选)",
                     "path":"本地临时文件路径", "session":"shell-1"}

// ── 核心 → 外壳 ──
{"type":"speak",      "text":"要念的话"}
{"type":"stop_speak"}                                // barge-in 响应，让外壳停朗读
{"type":"mode",       "stack":["main","opencode.attach"]}  // 当前模式栈，供 UI 显示
```

**要点：**
- 音频字节不走这条边界，外壳自己做 STT/TTS，核心只收发文本。
- `media` 消息用于微信这类会送语音/文件的外壳；`text` 字段可携带外壳侧已有的 ASR 转写（如微信自带转写），`path` 指向落到本地的媒体文件供核心侧 STT 使用。

---

## 4. 核心 ↔ 插件：子进程 JSON-RPC 协议（任意语言）

### 4.1 进程模型决策

**插件 = 独立子进程**，通过 stdin/stdout 交换 NDJSON（每行一个 JSON-RPC 消息）。**只要能读写 stdin/stdout JSON，任何语言都能写插件。**

> 说明：Oracle 最初建议「插件同进程（只能 Node）」以省 IPC 开销。但本系统插件干的活（如调 OpenCode headless、等 Sisyphus 干活）本身是秒级的，一次子进程 IPC 往返是毫秒级，可忽略。因此明确采用**子进程模型**换取「任意语言写插件」的开放性。高频的框架内部逻辑（意图路由/退出词快判）留在核心同进程，不受影响——这是「核心同进程 + 插件子进程」的双轨设计。

### 4.2 契约（4 个方法）

核心发给插件、插件回一个 `speak` 文本。契约极小：

```jsonc
// ① init：插件启动后核心先发，插件回元信息
→ {"jsonrpc":"2.0","id":1,"method":"init","params":{}}
← {"jsonrpc":"2.0","id":1,"result":{"name":"opencode","version":"1.0"}}

// ② onWake：命中 session:true 的意图时，核心把抠好的参数一起塞进来（方案甲）
→ {"jsonrpc":"2.0","id":2,"method":"onWake","params":{
      "intent":"opencode.attach","params":{"session_name":"sisyphus"}}}
← {"jsonrpc":"2.0","id":2,"result":{"speak":"已接入 sisyphus，请说"}}

// ③ onUtter：接管期间用户说的每句都发这个
→ {"jsonrpc":"2.0","id":3,"method":"onUtter","params":{"text":"帮我看看这个 bug"}}
← {"jsonrpc":"2.0","id":3,"result":{"speak":"...OpenCode 的回复..."}}

// ④ onExit：用户说退出词，核心通知插件清理
→ {"jsonrpc":"2.0","id":4,"method":"onExit","params":{}}
← {"jsonrpc":"2.0","id":4,"result":{"speak":"已退出"}}
```

- **一次性意图**（`session:false`）：核心只发一次 `onUtter`（带参数），不发 onWake/onExit。
- 插件只负责「收文本 → 干活 → 回文本」，**完全不用懂意图判别 / 唤醒机制**，因此任意语言写起来都极简。

---

## 5. 意图路由：配置驱动（配置文件 + LLM 判别 + 方案甲抠参数）

**意图不由插件上报，而是写在配置文件里交给核心。** 核心读配置 → 让大模型判意图 → 命中 → 按配置调对应插件。

### 5.1 意图配置文件 `intents.json`

```jsonc
{
  "intents": [
    {
      "id": "opencode.attach",
      "description": "用户想把语音接入某个 OpenCode session，之后说的话转发给它、回复念回来",
      "examples": ["接下来帮我打开 OpenCode 的 xxx session", "连到 sisyphus", "接到 opencode"],
      "plugin": "opencode",              // 绑定哪个插件（意图与插件解耦，一个插件可被多意图触发）
      "parameters": {                     // 大模型判意图时顺手抠的槽位（方案甲：核心抠好塞给插件）
        "session_name": "OpenCode session 的名字或别名，可能没有"
      },
      "session": true                     // true=命中后进入持续会话(接管)；false=一次性调用
    }
  ],
  "exit": {                               // 全局退出意图（从任何插件会话退回主控）
    "keywords": ["退出语音", "退出", "回到主控", "结束会话"],
    "description": "用户想退出当前会话回到主控"
  }
}
```

### 5.2 路由逻辑（放核心，不在插件里）

```
每句语音文本进来：
  if 当前在某插件会话中（栈顶 ≠ main）:
      先本地快判退出词（规范化匹配：去空格标点+小写后 contains）——命中就 pop 回主控
      没退出 → 直接调该插件的 onUtter（转发）        ← 接管期间零 LLM 开销
  else（在主控）:
      过一次小模型判意图（读 intents.json 的 description + examples）
        → 命中某意图 → 抠出 parameters → push 该插件 → 调 onWake（session:true）
                                                     或 调一次 onUtter（session:false）
```

### 5.3 从 RealtimeVoiceMode.swift 复用的成熟经验

- **wake / trigger / exit / reset 四分关键词** → 对应插件的 唤醒/提交/退出/撤销。
- **规范化匹配**（去空格标点+小写后 contains）→ 退出词快判用这套，别用精确匹配（ASR 会加标点）。
- **优先级 exit > reset > trigger** → 已验证合理。
- **MVP 保留一个关键词兜底**（如「嘿 OpenCode」强制唤醒）：LLM 意图判别做锦上添花，不做唯一路径，避免小模型判错打断体验。

---

## 6. 现有资产的新定位（一个都不浪费）

| 现有资产 | 新角色 |
|---|---|
| AIVoiceAgent 的 Swift 音频管线（VPIO/AEC/VAD/whisper/Edge-TTS） | Mac 平台的高质量音频外壳（WebSocket client） |
| VoiceAgentWeb（浏览器 Web Speech + 瘦后端） | 「浏览器外壳」的雏形；服务端从 Swift 迁到 Node |
| opencode-voice-output-plugin 的插件形态 | 插件机制的**形态蓝本**（工厂函数返回 hook 表的思路） |
| RealtimeVoiceMode.swift 的唤醒/接管状态机 | 移植成 Node 核心的「意图路由 + 模式栈」逻辑 |
| NVP server（Bun 二进制 + 子进程 JSON-RPC） | 保留，Node 核心照样子进程调它做上下文压缩 |
| Swift 的 AgentLoop / 工具系统 | 搬到 Node 核心（跨平台复用） |

---

## 7. 微信外壳（第三种外壳，非插件）

### 7.1 定位澄清

微信入口在架构里是**外壳（Shell）**，不是 §4 意义上的「插件」：

- **插件** = agent 主动出去连服务干活（如 opencode 插件 POST 给 OpenCode）。
- **外壳** = 用户从哪个入口进来跟 agent 说话（Swift / 浏览器 / **微信**）。

微信是用户入口 → 是外壳 → 讲 §3 的 WebSocket 协议接入核心。**加微信入口，核心一行不用改**（方案 A 分层红利）。微信外壳本身是独立进程，可任意语言写。

### 7.2 技术选型（调研结论）

- **「龙虾」= OpenClaw**（🦞，github.com/openclaw/openclaw）。它连微信走的是**腾讯 2026-03 发布的官方 iLink Bot API**（`ilinkai.weixin.qq.com`），由外部 npm 插件 `@tencent-weixin/openclaw-weixin` 封装。机制：`openclaw channels login` 触发**二维码登录** → 手机微信扫码 → 通讯录出现一个「机器人好友」→ 私聊它即把消息喂进 agent。
- **推荐实现路径**：不碰 OpenClaw 闭源插件，直接用社区的 [`wong2/weixin-agent-sdk`](https://github.com/wong2/weixin-agent-sdk)（把 iLink 协议封装成干净的 `Agent` 接口）。实现一个 `chat(request)` 方法，内部把消息经 WebSocket 转发给核心即可。
- **零封号风险**（官方 API）、**无需公网 IP**、**扫码即用**、文本/语音/文件全支持。

### 7.3 iLink 的三个硬限制（影响产品形态）

1. **只能私聊，不支持群聊**。
2. **只能被动回复，不能主动找陌生人**：用户须先给 bot 发消息（拿到 `context_token`）才能回；进程重启 token 会丢，需用户再发一句恢复（可存 SQLite 缓解）。
3. **1 个微信号 = 1 个 bot**；语音是微信专用 **SILK 格式**，需 `silk-v3-decoder` 转 PCM/wav 才能喂 STT（也可先用 iLink 消息自带的微信 ASR 转写文本）。

### 7.4 访问控制（DM pairing，参考 OpenClaw）

陌生人首条消息不处理，回一个配对码；操作者在 Web UI / CLI 批准后该 sender 才能对话。可参考 OpenClaw 的 `channel_pairing_requests` 机制。

---

## 8. 落地路线（分阶段，先跑通再抽象）

> 核心策略：**第一阶段完全不碰 Swift**。先用「浏览器外壳 + Node 核心」把架构跑通，证明对了，Swift 那条线纯粹是后期的 Mac 高质量优化，不是前置条件。

| 阶段 | 做什么 | 验收 |
|---|---|---|
| **一（跑通）** | Node 核心骨架（WebSocket server）+ 最简 HTML 外壳（Web Speech STT/TTS）+ **硬编码**一个 opencode 转发（`if 文本含 opencode → POST 给 headless(parts:[{type,text}]+agent:"sisyphus") → 读回`）+ 两状态 main/attached + 关键词退出。**不上插件机制、不上 LLM 路由。** | 浏览器说话 → 转文字 → 发核心 → opencode 回复念出来，闭环通 |
| **二（抽象化）** | 把硬编码的 opencode 逻辑重构成 §4 插件接口 + §5 意图配置 + LLM 意图路由 + Web UI 控制面 | 插件可插拔、意图靠配置+LLM 判、Web 界面可操作 |
| **三（Mac 外壳）** | Swift 外壳改造成 WebSocket client：砍掉 AgentLoop 搬到 Node，保留音频管线（VPIO/AEC/whisper/Edge-TTS） | Mac 原生高质量语音 + Node 核心 |
| **四（微信外壳）** | 按 §7 用 `wong2/weixin-agent-sdk` 写微信外壳，接核心 WebSocket；WebSocket 协议加 `media` 类型 | 微信扫码 → 私聊 bot → 消息进 agent → 回复发回微信 |

### 三个必须提前警惕的坑（Oracle 提醒）

1. **WebSocket 协议 MVP 就要定死**（§3）——外壳和核心的契约，协议不稳整个系统晃。
2. **LLM 意图路由保留关键词兜底**——小模型判错很打断体验，LLM 锦上添花不做唯一路径。
3. **别过度设计**——多插件热加载、意图向量检索、插件沙箱、模式栈嵌套，当前单插件时全是浪费。一期硬编码单插件是对的。

---

## 附录：决策清单（均已确认）

- [x] 跨平台路线 = **方案 A**（抽核心，大脑搬 Node，Swift 缩成音频外壳）
- [x] 系统定位 = **独立通用语音 Agent**，OpenCode 只是其一个插件能力（大脑要「厚」，含自己的 AgentLoop）
- [x] 插件进程模型 = **子进程 JSON-RPC**，因此**任意语言**可写插件
- [x] 意图机制 = **配置文件驱动**（intents.json）+ LLM 判别 + 关键词兜底
- [x] 参数传递 = **方案甲**（核心抠好参数塞给插件）
- [x] 微信入口 = **第三种外壳**（非插件），走 iLink + `wong2/weixin-agent-sdk`
- [x] WebSocket 协议需新增 **media** 消息类型以支持微信的语音/文件输入
