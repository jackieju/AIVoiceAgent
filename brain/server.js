import http from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { WebSocketServer } from "ws";
import { loadConfig } from "./config.js";
import { chat } from "./llm.js";
import { OpenCodeSession } from "./opencode.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const config = loadConfig();
const PORT = process.env.BRAIN_PORT ? Number(process.env.BRAIN_PORT) : 8787;

const EXIT_WORDS = config.intents?.exit?.keywords || [
  "退出语音",
  "退出",
  "回到主控",
  "结束会话",
];
const OPENCODE_WAKE = [
  "opencode",
  "open code",
  "open cold",
  "open called",
  "opened code",
  "欧朋",
  "接到opencode",
  "打开opencode",
  "连到opencode",
];

function normalize(s) {
  return s.replace(/[\s，。！？、,.!?]/g, "").toLowerCase();
}
function hasAny(text, words) {
  const n = normalize(text);
  return words.some((w) => n.includes(normalize(w)));
}

const MIME = { html: "text/html", js: "text/javascript", css: "text/css" };
const httpServer = http.createServer((req, res) => {
  let path = (req.url === "/" ? "/index.html" : req.url).split("?")[0];
  try {
    const file = readFileSync(join(__dirname, "public", path));
    const ext = path.split(".").pop();
    res.writeHead(200, { "content-type": (MIME[ext] || "text/plain") + "; charset=utf-8" });
    res.end(file);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});

const wss = new WebSocketServer({ server: httpServer });

function send(ws, obj) {
  ws.send(JSON.stringify(obj));
}
function speak(ws, text) {
  send(ws, { type: "speak", text });
}

wss.on("connection", (ws) => {
  const conn = { mode: "main", history: [], oc: null };
  send(ws, { type: "mode", stack: ["main"] });

  ws.on("message", async (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (msg.type === "hello" || msg.type === "barge_in") return;
    if (msg.type !== "utterance" && msg.type !== "media") return;

    const text = (msg.text || "").trim();
    if (!text) return;

    try {
      if (conn.mode === "attached") {
        if (hasAny(text, EXIT_WORDS)) {
          conn.mode = "main";
          conn.oc = null;
          send(ws, { type: "mode", stack: ["main"] });
          return speak(ws, "已退出，回到主控。");
        }
        return speak(ws, await conn.oc.send(text));
      }

      if (hasAny(text, OPENCODE_WAKE)) {
        const oc = new OpenCodeSession(config.opencode);
        try {
          await oc.ensure();
        } catch (e) {
          return speak(ws, e.message || "接入 OpenCode 失败。");
        }
        conn.oc = oc;
        conn.mode = "attached";
        send(ws, { type: "mode", stack: ["main", "opencode.attach"] });
        return speak(ws, "已接入 OpenCode，请说。");
      }

      conn.history.push({ role: "user", content: text });
      const reply = await chat(config, conn.history);
      conn.history.push({ role: "assistant", content: reply });
      speak(ws, reply);
    } catch (e) {
      speak(ws, "出错了：" + (e.message || String(e)));
    }
  });
});

httpServer.listen(PORT, "127.0.0.1", () => {
  console.log(`[brain] http+ws 已启动: http://127.0.0.1:${PORT}`);
});
