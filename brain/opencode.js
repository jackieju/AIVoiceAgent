import { spawn } from "node:child_process";

let sharedChild = null;

export class OpenCodeSession {
  constructor(cfg) {
    this.base = (cfg?.baseURL || "http://127.0.0.1:4096").replace(/\/$/, "");
    this.auth = cfg?.username
      ? "Basic " + Buffer.from(`${cfg.username}:${cfg.password || ""}`).toString("base64")
      : null;
    this.sessionID = cfg?.defaultSessionID || "";
    this.agent = cfg?.agent || "";
    this.autoStart = cfg?.autoStart !== false;
    this.binary = cfg?.binary || "opencode";
    this.port = cfg?.port || this.portFromBase() || 4096;
    this.directory = cfg?.directory || "";
    this.startTimeoutMs = cfg?.startTimeoutMs || 15000;
  }

  portFromBase() {
    const m = this.base.match(/:(\d+)/);
    return m ? Number(m[1]) : null;
  }

  headers() {
    const h = { "content-type": "application/json" };
    if (this.auth) h.authorization = this.auth;
    return h;
  }

  withDir(path) {
    if (!this.directory) return this.base + path;
    const sep = path.includes("?") ? "&" : "?";
    return this.base + path + sep + "directory=" + encodeURIComponent(this.directory);
  }

  // opencode 无 /health，用 GET /doc 探活（200 即 HTTP 层就绪）
  async probe() {
    try {
      const res = await fetch(this.base + "/doc", {
        method: "GET",
        headers: this.auth ? { authorization: this.auth } : {},
        signal: AbortSignal.timeout(2000),
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  async ensureServer() {
    if (await this.probe()) return;

    if (!this.autoStart) {
      throw new Error(
        "连不上 OpenCode 服务，且未开启自动拉起。请先在终端启动：opencode --pure serve --port " +
          this.port
      );
    }

    // --pure 必须放子命令前否则 yargs 静默失效；它禁掉 server 侧外部插件（含 tts.js），根治插件崩溃污染 server 返 500
    if (!sharedChild || sharedChild.killed) {
      sharedChild = spawn(
        this.binary,
        ["--pure", "serve", "--port", String(this.port), "--hostname", "127.0.0.1"],
        {
          env: { ...process.env, OPENCODE_PURE: "1" },
          stdio: ["ignore", "pipe", "pipe"],
          detached: false,
        }
      );
      sharedChild.on("exit", (code) => {
        console.log(`[opencode] server 进程退出 code=${code}`);
        sharedChild = null;
      });
      sharedChild.stdout?.on("data", (d) => {
        const line = d.toString().trim();
        if (line) console.log("[opencode]", line);
      });
      sharedChild.stderr?.on("data", (d) => {
        const line = d.toString().trim();
        if (line) console.log("[opencode:err]", line);
      });
      console.log(`[opencode] 已拉起 headless server（--pure，端口 ${this.port}）`);
    }

    const deadline = Date.now() + this.startTimeoutMs;
    while (Date.now() < deadline) {
      if (await this.probe()) return;
      await new Promise((r) => setTimeout(r, 250));
    }
    throw new Error(`拉起 OpenCode 服务超时（${this.startTimeoutMs / 1000}s），请检查终端。`);
  }

  async ensure() {
    await this.ensureServer();
    if (this.sessionID) return;
    let res;
    try {
      res = await fetch(this.withDir("/session"), {
        method: "POST",
        headers: this.headers(),
        body: JSON.stringify({}),
      });
    } catch {
      throw new Error("连不上 OpenCode 服务，请先在终端启动 opencode headless（端口 " + this.port + "）。");
    }
    if (!res.ok) throw new Error(`opencode 创建 session 失败 ${res.status}`);
    const s = await res.json();
    this.sessionID = s.id;
  }

  async send(text) {
    let res;
    const payload = { parts: [{ type: "text", text }] };
    if (this.agent) payload.agent = this.agent;
    try {
      res = await fetch(this.withDir(`/session/${this.sessionID}/message`), {
        method: "POST",
        headers: this.headers(),
        body: JSON.stringify(payload),
      });
    } catch {
      throw new Error("连不上 OpenCode 服务，可能已停止。");
    }
    if (!res.ok) throw new Error(`opencode 发送失败 ${res.status}`);
    const data = await res.json();
    const parts = data.parts || data.message?.parts || [];
    const out = parts
      .filter((p) => p.type === "text")
      .map((p) => p.text)
      .join("");
    return out.trim() || "OpenCode 没有返回文本。";
  }
}
