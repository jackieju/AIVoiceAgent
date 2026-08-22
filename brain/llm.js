// LLM 调用（Anthropic messages 格式，走 hyproxy）。第一阶段非流式：拿完整回复再朗读。
// baseURL 例：http://localhost:6655/anthropic  → 实际请求 <baseURL>/v1/messages

export async function chat(config, messages) {
  const provider = config.provider || {};
  const base = (provider.baseURL || "").replace(/\/$/, "");
  const url = base + "/v1/messages";

  const body = {
    model: config.model,
    max_tokens: 1024,
    system: config.systemPrompt || "",
    messages,
  };

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": provider.apiKey || "",
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const t = await res.text().catch(() => "");
    throw new Error(`LLM ${res.status}: ${t.slice(0, 200)}`);
  }

  const data = await res.json();
  const text = (data.content || [])
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("");
  return text.trim();
}
