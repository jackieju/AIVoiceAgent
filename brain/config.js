// 读取配置文件，解析 {env:VAR} 语法（与 Swift 版 Config.swift 保持一致）。
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

function expandEnv(v) {
  if (typeof v !== "string") return v;
  const m = v.match(/^\{env:([^}]+)\}$/);
  if (m) return process.env[m[1]] ?? "";
  return v;
}

function deepExpand(obj) {
  if (Array.isArray(obj)) return obj.map(deepExpand);
  if (obj && typeof obj === "object") {
    const out = {};
    for (const [k, val] of Object.entries(obj)) out[k] = deepExpand(val);
    return out;
  }
  return expandEnv(obj);
}

function expandHome(p) {
  if (typeof p === "string" && p.startsWith("~/")) return join(homedir(), p.slice(2));
  return p;
}

export function loadConfig() {
  const path =
    process.env.AIVOICEAGENT_CONFIG ||
    join(homedir(), ".config", "aivoiceagent", "config.json");
  const raw = JSON.parse(readFileSync(path, "utf8"));
  const cfg = deepExpand(raw);
  if (cfg.nvp?.binaryPath) cfg.nvp.binaryPath = expandHome(cfg.nvp.binaryPath);
  if (cfg.nvp?.dbPath) cfg.nvp.dbPath = expandHome(cfg.nvp.dbPath);
  return cfg;
}
