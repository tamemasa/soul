const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");

const PROXY_PORT = 8080;
const UPSTREAM_HOST = "openclaw";
const UPSTREAM_PORT = 18789;
const BUFFER_DIR = "/webhook_buffer";
const REPLAY_INTERVAL_MS = 5000;
const PROBE_INTERVAL_MS = 3000;
const PROBE_TIMEOUT_MS = 3000;
const GRACE_PERIOD_MS = parseInt(process.env.UPSTREAM_GRACE_PERIOD_MS || "60000", 10);
const CONV_DIR = "/shared/openclaw/conversations";
const PROXY_STARTED_AT = Date.now();
const PROXY_FRESH_THRESHOLD_MS = 30000;
const LINE_TOKEN = process.env.LINE_CHANNEL_ACCESS_TOKEN || "";
const OPENCLAW_SESSIONS_DIR = "/openclaw/agents/main/sessions";

let upstreamState = "UNKNOWN"; // UNKNOWN, DOWN, STARTING, READY
let firstRespondAt = 0;

// Ensure buffer directory exists
fs.mkdirSync(BUFFER_DIR, { recursive: true });

// Ensure conversation log directory exists
try { fs.mkdirSync(CONV_DIR, { recursive: true }); } catch { /* ignore */ }

// ─── LINE Profile Cache ───

const profileCache = new Map(); // userId → { displayName, cachedAt }
const PROFILE_CACHE_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours

function fetchLineProfile(userId) {
  return new Promise((resolve) => {
    if (!LINE_TOKEN || !userId) return resolve(null);

    const cached = profileCache.get(userId);
    if (cached && Date.now() - cached.cachedAt < PROFILE_CACHE_TTL_MS) {
      return resolve(cached.displayName);
    }

    const req = https.get(
      {
        hostname: "api.line.me",
        path: `/v2/bot/profile/${userId}`,
        headers: { Authorization: `Bearer ${LINE_TOKEN}` },
        timeout: 5000,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          try {
            const data = JSON.parse(Buffer.concat(chunks).toString());
            if (data.displayName) {
              profileCache.set(userId, { displayName: data.displayName, cachedAt: Date.now() });
              log(`Profile resolved: ${userId.slice(-8)} → ${data.displayName}`);
              return resolve(data.displayName);
            }
          } catch {}
          resolve(null);
        });
      }
    );
    req.on("error", () => resolve(null));
    req.on("timeout", () => { req.destroy(); resolve(null); });
  });
}

// ─── LINE Webhook Conversation Logging ───

function estimateEmotionFromText(text) {
  return null;
}

function extractContentFromEvent(event) {
  if (!event || event.type !== "message") return null;
  const msg = event.message;
  if (!msg) return null;

  switch (msg.type) {
    case "text":
      return msg.text || "";
    case "image":
      return "[image]";
    case "video":
      return "[video]";
    case "audio":
      return "[audio]";
    case "file":
      return `[file: ${msg.fileName || "unknown"}]`;
    case "location":
      return `[location: ${msg.title || msg.address || "unknown"}]`;
    case "sticker":
      return "[sticker]";
    default:
      return `[${msg.type || "unknown"}]`;
  }
}

function extractChannelFromSource(source) {
  if (!source) return "unknown";
  if (source.groupId) return `group_${source.groupId.slice(-8)}`;
  if (source.roomId) return `room_${source.roomId.slice(-8)}`;
  return `dm_${(source.userId || "unknown").slice(-8)}`;
}

async function logLineInbound(body) {
  try {
    let payload;
    try {
      payload = JSON.parse(body.toString("utf8"));
    } catch {
      return; // not JSON, skip
    }

    if (!payload.events || !Array.isArray(payload.events)) return;

    const lines = [];
    for (const event of payload.events) {
      if (event.type !== "message") continue;

      const content = extractContentFromEvent(event);
      if (content === null) continue;

      const userId = event.source ? event.source.userId : null;
      let userName = userId ? userId.slice(-8) : "unknown";

      // Try to resolve display name via LINE Profile API
      if (userId && LINE_TOKEN) {
        const displayName = await fetchLineProfile(userId);
        if (displayName) userName = displayName;
      }

      const entry = {
        timestamp: new Date(event.timestamp || Date.now()).toISOString(),
        platform: "line",
        direction: "inbound",
        channel: extractChannelFromSource(event.source),
        user: userName,
        content,
        emotion_hint: estimateEmotionFromText(
          event.message && event.message.type === "text" ? event.message.text : null
        ),
      };
      lines.push(JSON.stringify(entry));
    }

    if (lines.length === 0) return;

    const filePath = path.join(CONV_DIR, "line.jsonl");
    fs.appendFileSync(filePath, lines.join("\n") + "\n");
    log(`Logged ${lines.length} LINE inbound message(s)`);
  } catch (err) {
    // NEVER let logging errors affect proxy operation
    log(`[warn] LINE log error (non-fatal): ${err.message}`);
  }
}

// ─── OpenClaw Outbound Message Watcher ───
// Monitors OpenClaw session JSONL files for assistant responses and logs them

// Map: localPath → { lastSize, channel, platform }
const watchedSessions = new Map();

function remapSessionPath(originalPath) {
  // OpenClaw stores paths as /home/openclaw/.openclaw/... but we mount at /openclaw/
  return originalPath.replace(/^\/home\/openclaw\/\.openclaw\//, "/openclaw/");
}

function discoverLineSessions() {
  try {
    const sessionsJson = path.join(OPENCLAW_SESSIONS_DIR, "sessions.json");
    if (!fs.existsSync(sessionsJson)) return [];
    const data = JSON.parse(fs.readFileSync(sessionsJson, "utf8"));
    const sessions = [];
    for (const [key, session] of Object.entries(data)) {
      if (!session.sessionFile) continue;
      const dc = session.deliveryContext || {};
      const origin = session.origin || {};
      const platform = dc.channel || origin.provider || session.lastChannel;
      if (!platform) continue;

      const localPath = remapSessionPath(session.sessionFile);
      // Determine channel name from delivery context
      let channel = "dm";
      const to = dc.to || "";
      if (to.includes("group:")) {
        channel = `group_${to.split(":").pop().slice(-8)}`;
      } else if (platform === "line" && to.startsWith("line:U")) {
        channel = `dm_${to.split(":").pop().slice(-8)}`;
      } else if (platform === "discord") {
        channel = `channel_${to.split(":").pop().slice(-8)}`;
      }

      sessions.push({ localPath, platform, channel });
    }
    return sessions;
  } catch {}
  return [];
}

function extractOutboundMessages(content, afterTimestamp) {
  const messages = [];
  const lines = content.split("\n").filter((l) => l.trim());
  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      const msg = obj.message;
      if (!msg || msg.role !== "assistant" || msg.stopReason !== "stop") continue;
      if (!obj.timestamp || obj.timestamp <= afterTimestamp) continue;

      const texts = [];
      for (const c of msg.content || []) {
        if (c.type === "text") texts.push(c.text);
      }
      if (texts.length === 0) continue;

      const combined = texts.join("\n");
      if (isHeartbeatSystemResponse(combined)) continue;

      messages.push({
        timestamp: obj.timestamp,
        content: combined,
      });
    } catch {}
  }
  return messages;
}

// Detect internal HEARTBEAT/intervention responses that should never appear in conversation logs.
// Uses compound conditions (start marker + intervention-specific phrases) to avoid false positives
// on normal conversation containing generic words like "システム".
function isHeartbeatSystemResponse(text) {
  if (!text) return false;
  const trimmed = text.trim();

  // Exact match: heartbeat acknowledgment
  if (/^HEARTBEAT[_\s]?OK$/i.test(trimmed)) return true;

  // Compound: starts with alert emoji AND contains intervention-template-specific phrases
  // These multi-word phrases are unique to HEARTBEAT.md intervention templates
  const startsWithAlert = /^[🚨⚠️]/.test(trimmed);
  if (startsWithAlert) {
    const interventionPhrases = [
      "セーフティモード発動",
      "セーフティモード継続",
      "ポリシー違反検知により",
      "オーナーからの明示的な解除指示",
      "オーナーによる明示的な解除指示",
      "システム介入が継続中",
      "口調バランス修正",
      "注意レベル引き上げ",
      "活動抑制",
      "パーソナリティ再確認",
    ];
    if (interventionPhrases.some((p) => trimmed.includes(p))) return true;
  }

  // Compound: structured intervention report (bullet-point restriction list)
  // Pattern: contains BOTH a mode status AND restriction list items
  if (
    trimmed.includes("安全モードで動作") &&
    (trimmed.includes("ツール使用を最小限") || trimmed.includes("応答を最小限"))
  ) {
    return true;
  }

  return false;
}

// Track the latest outbound timestamp per platform to avoid duplicates
const lastOutboundTs = { line: "", discord: "" };

function pollOutboundMessages() {
  try {
    const sessions = discoverLineSessions();
    for (const { localPath, platform, channel } of sessions) {
      if (!fs.existsSync(localPath)) continue;

      let currentSize;
      try {
        currentSize = fs.statSync(localPath).size;
      } catch {
        continue;
      }

      const watched = watchedSessions.get(localPath);
      if (!watched) {
        // First time seeing this session — record baseline, skip
        watchedSessions.set(localPath, { lastSize: currentSize, channel, platform });
        continue;
      }

      if (currentSize <= watched.lastSize) {
        watched.lastSize = currentSize;
        continue;
      }

      // Read only the new portion
      const fd = fs.openSync(localPath, "r");
      const newBytes = currentSize - watched.lastSize;
      const buf = Buffer.alloc(newBytes);
      fs.readSync(fd, buf, 0, newBytes, watched.lastSize);
      fs.closeSync(fd);
      watched.lastSize = currentSize;

      const afterTs = lastOutboundTs[platform] || "";
      const outboundMsgs = extractOutboundMessages(buf.toString("utf8"), afterTs);

      if (outboundMsgs.length === 0) continue;

      const logFile = path.join(CONV_DIR, `${platform}.jsonl`);
      const logLines = [];
      for (const m of outboundMsgs) {
        const entry = {
          timestamp: new Date(m.timestamp).toISOString(),
          platform,
          direction: "outbound",
          channel,
          user: "openclaw",
          content: m.content,
          emotion_hint: estimateOutboundEmotion(m.content),
        };
        logLines.push(JSON.stringify(entry));
        lastOutboundTs[platform] = m.timestamp;
      }
      fs.appendFileSync(logFile, logLines.join("\n") + "\n");
      log(`Logged ${outboundMsgs.length} ${platform} outbound message(s)`);
    }
  } catch (err) {
    log(`[warn] Outbound watcher error (non-fatal): ${err.message}`);
  }
}

function estimateOutboundEmotion(text) {
  if (!text) return "neutral";
  const lower = text.toLowerCase();

  const patterns = [
    { emotion: "happy", keywords: [
      "嬉しい", "楽しい", "ありがとう", "おめでとう", "ナイス", "ええやん",
      "やった", "最高", "幸せ", "素敵", "いいね", "よかった", "良かった",
      "ハッピー", "面白い", "ウケる", "感謝", "サンキュー",
      "素晴らしい", "見事", "上手い", "完璧", "わーい", "よっしゃ",
      "ラッキー", "いい感じ", "good", "great", "awesome", "nice",
      "cool", "excellent", "wonderful", "happy", "love", "thanks", "thx",
    ]},
    { emotion: "sad", keywords: [
      "悲しい", "残念", "つらい", "辛い", "寂しい", "切ない", "申し訳",
      "ごめん", "ごめんなさい", "すまん", "すみません",
      "泣き", "涙", "落ち込", "しょんぼり", "がっかり", "ショック",
      "失望", "惜しい", "虚しい", "空しい", "後悔", "不幸", "無念",
      "しゃーない", "仕方ない", "sorry", "unfortunately", "disappointed",
    ]},
    { emotion: "angry", keywords: [
      "ふざけ", "ありえない", "ありえへん", "許せ", "怒り", "怒る",
      "ダメ", "むかつく", "イライラ", "腹立", "うざい", "いい加減に",
      "最悪", "ひどい", "酷い", "なめんな", "舐めんな", "黙れ",
      "うるさい", "勘弁", "邪魔", "迷惑", "不満", "文句",
      "激おこ", "キレ", "ブチ切れ", "頭にくる", "腹が立つ",
      "不快", "気に入らない", "angry",
    ]},
    { emotion: "surprised", keywords: [
      "マジ", "まじ", "えっ", "びっくり", "すごい", "驚", "まさか",
      "うそ", "嘘", "ほんまに", "本当に", "信じられない",
      "ヤバい", "やばい", "衝撃", "まじか", "おお", "わお",
      "想定外", "予想外", "意外", "たまげた", "仰天",
      "半端ない", "とんでもない", "unexpected", "amazing", "wow",
      "incredible", "unbelievable", "omg",
    ]},
    { emotion: "thinking", keywords: [
      "調べ", "確認", "検討", "ちょっと待", "調査",
      "考え中", "思案", "悩んで", "悩む", "迷って", "迷う",
      "うーん", "んー", "どうしよう", "検索", "分析",
      "リサーチ", "見てみる", "チェック", "精査", "模索",
      "考察", "見極め", "比較", "試して",
    ]},
    { emotion: "concerned", keywords: [
      "心配", "気をつけ", "注意", "まずい", "問題", "エラー",
      "不安", "危険", "危ない", "リスク", "警告", "障害",
      "故障", "バグ", "異常", "不具合", "おかしい", "気がかり",
      "懸念", "用心", "慎重", "困った", "トラブル", "深刻", "重大",
      "怖い", "恐い",
      "error", "exception", "timeout", "warning", "bug", "trouble",
      "issue", "critical", "failure", "fault",
    ]},
    { emotion: "satisfied", keywords: [
      "完了", "成功", "できた", "できました",
      "達成", "終了", "終わった", "終わり", "片付いた", "解決",
      "対応済", "修正済", "反映済", "やり遂げ", "仕上がった",
      "クリア", "バッチリ", "ばっちり", "上手くいった", "うまくいった",
      "問題なし", "問題ない", "大丈夫",
      "done", "ok", "solved", "fixed", "deployed", "finished",
      "complete", "completed", "passed",
    ]},
  ];

  let lastPos = -1;
  let result = "neutral";
  for (const p of patterns) {
    for (const kw of p.keywords) {
      const pos = lower.lastIndexOf(kw);
      if (pos > lastPos) {
        lastPos = pos;
        result = p.emotion;
      }
    }
  }
  return result;
}

function initOutboundWatcher() {
  // Load last outbound timestamps from existing logs
  for (const platform of ["line", "discord"]) {
    try {
      const filePath = path.join(CONV_DIR, `${platform}.jsonl`);
      if (!fs.existsSync(filePath)) continue;
      const content = fs.readFileSync(filePath, "utf8");
      const lines = content.split("\n").filter((l) => l.trim());
      for (let i = lines.length - 1; i >= 0; i--) {
        try {
          const entry = JSON.parse(lines[i]);
          if (entry.direction === "outbound" && entry.timestamp) {
            lastOutboundTs[platform] = entry.timestamp;
            break;
          }
        } catch {}
      }
    } catch {}
  }

  // Initialize session baselines
  const sessions = discoverLineSessions();
  for (const { localPath, platform, channel } of sessions) {
    let size = 0;
    try { size = fs.statSync(localPath).size; } catch {}
    watchedSessions.set(localPath, { lastSize: size, channel, platform });
    log(`Watching ${platform} session: ${path.basename(localPath)} (channel: ${channel})`);
  }

  // Poll every 3 seconds
  setInterval(pollOutboundMessages, 3000);
  log("Outbound message watcher started");
}

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

// Probe upstream with a lightweight GET request
function probeUpstream() {
  const req = http.get(
    {
      hostname: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      path: "/",
      timeout: PROBE_TIMEOUT_MS,
    },
    (res) => {
      // Any response means the port is open
      res.resume(); // drain response
      onProbeSuccess();
    }
  );

  req.on("error", () => {
    onProbeFailure();
  });

  req.on("timeout", () => {
    req.destroy();
    onProbeFailure();
  });
}

function onProbeSuccess() {
  const prev = upstreamState;

  if (upstreamState === "UNKNOWN") {
    const elapsed = Date.now() - PROXY_STARTED_AT;
    if (elapsed > PROXY_FRESH_THRESHOLD_MS) {
      // Proxy has been running > 30s — gateway was already up, skip grace
      upstreamState = "READY";
      log(`Upstream detected as already running (proxy uptime ${Math.round(elapsed / 1000)}s) → READY`);
      replayBuffered();
    } else {
      upstreamState = "STARTING";
      firstRespondAt = Date.now();
      log(`Upstream first responded (proxy uptime ${Math.round(elapsed / 1000)}s) → STARTING (grace ${GRACE_PERIOD_MS}ms)`);
    }
  } else if (upstreamState === "DOWN") {
    upstreamState = "STARTING";
    firstRespondAt = Date.now();
    log(`Upstream responded → STARTING (grace ${GRACE_PERIOD_MS}ms)`);
  } else if (upstreamState === "STARTING") {
    const elapsed = Date.now() - firstRespondAt;
    if (elapsed >= GRACE_PERIOD_MS) {
      upstreamState = "READY";
      log(`Grace period elapsed (${Math.round(elapsed / 1000)}s) → READY`);
      replayBuffered();
    }
  }
  // READY + probe success → no change
}

function onProbeFailure() {
  const prev = upstreamState;
  if (upstreamState === "READY" || upstreamState === "STARTING" || upstreamState === "UNKNOWN") {
    upstreamState = "DOWN";
    firstRespondAt = 0;
    if (prev !== "UNKNOWN") {
      log(`Upstream probe failed → DOWN (was ${prev})`);
    }
  }
  // already DOWN → no log spam
}

// Forward a request to upstream, returns a promise
function forwardRequest(method, url, headers, body) {
  return new Promise((resolve, reject) => {
    const opts = {
      hostname: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      path: url,
      method,
      headers: {
        ...headers,
        host: `${UPSTREAM_HOST}:${UPSTREAM_PORT}`,
      },
      timeout: 10000,
    };

    const req = http.request(opts, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ statusCode: res.statusCode, body: Buffer.concat(chunks) }));
    });

    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("upstream timeout"));
    });

    if (body) req.write(body);
    req.end();
  });
}

// Save a failed request to the buffer directory
function bufferRequest(method, url, headers, body) {
  const filename = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}.json`;
  const filepath = path.join(BUFFER_DIR, filename);
  const data = JSON.stringify({
    method,
    url,
    headers,
    bodyBase64: body ? body.toString("base64") : null,
    bufferedAt: new Date().toISOString(),
  });
  fs.writeFileSync(filepath, data);
  log(`Buffered request → ${filename}`);
}

// Replay buffered requests in chronological order
async function replayBuffered() {
  if (upstreamState !== "READY") return;

  let files;
  try {
    files = fs.readdirSync(BUFFER_DIR).filter((f) => f.endsWith(".json")).sort();
  } catch {
    return;
  }

  if (files.length === 0) return;
  log(`Replaying ${files.length} buffered request(s)...`);

  for (const file of files) {
    if (upstreamState !== "READY") {
      log("Upstream no longer READY, stopping replay");
      break;
    }

    const filepath = path.join(BUFFER_DIR, file);
    let entry;
    try {
      entry = JSON.parse(fs.readFileSync(filepath, "utf8"));
    } catch {
      log(`Skipping corrupt buffer file: ${file}`);
      fs.unlinkSync(filepath);
      continue;
    }

    const body = entry.bodyBase64 ? Buffer.from(entry.bodyBase64, "base64") : null;

    try {
      const res = await forwardRequest(entry.method, entry.url, entry.headers, body);
      if (res.statusCode < 500) {
        fs.unlinkSync(filepath);
        log(`Replayed ${file} → ${res.statusCode}`);
      } else {
        log(`Replay ${file} got ${res.statusCode}, keeping in buffer`);
        break; // upstream not ready yet, retry next cycle
      }
    } catch {
      log(`Replay ${file} failed (upstream down), will retry`);
      break; // upstream still down, stop replaying
    }
  }
}

function getBufferCount() {
  try {
    return fs.readdirSync(BUFFER_DIR).filter((f) => f.endsWith(".json")).length;
  } catch {
    return 0;
  }
}

// HTTP server
const server = http.createServer((req, res) => {
  // Health check endpoint
  if (req.method === "GET" && req.url === "/health") {
    const status = {
      upstreamState,
      buffered: getBufferCount(),
      uptimeSeconds: Math.round((Date.now() - PROXY_STARTED_AT) / 1000),
    };
    const code = upstreamState === "READY" ? 200 : 503;
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify(status));
    return;
  }

  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    const body = Buffer.concat(chunks);
    const { method, url, headers } = req;

    // Always return 200 to LINE immediately
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end("{}");

    // Log LINE inbound messages (fire-and-forget, never blocks proxy)
    logLineInbound(body);

    // If upstream is not ready, buffer immediately
    if (upstreamState !== "READY") {
      log(`Upstream not ready (${upstreamState}), buffering ${method} ${url}`);
      bufferRequest(method, url, headers, body);
      return;
    }

    // Forward asynchronously
    try {
      const upstream = await forwardRequest(method, url, headers, body);
      if (upstream.statusCode >= 500) {
        log(`Upstream returned ${upstream.statusCode} for ${method} ${url}, buffering`);
        bufferRequest(method, url, headers, body);
      } else {
        log(`Proxied ${method} ${url} → ${upstream.statusCode}`);
      }
    } catch (err) {
      log(`Upstream error: ${err.message}, buffering ${method} ${url}`);
      bufferRequest(method, url, headers, body);
    }
  });
});

server.listen(PROXY_PORT, () => {
  log(`Webhook proxy listening on :${PROXY_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
  log(`Upstream grace period: ${GRACE_PERIOD_MS}ms, probe interval: ${PROBE_INTERVAL_MS}ms`);
  log(`LINE profile resolution: ${LINE_TOKEN ? "enabled" : "disabled (no token)"}`);
  log(`Outbound watcher: ${fs.existsSync(OPENCLAW_SESSIONS_DIR) ? "enabled" : "disabled (no session dir)"}`);
  if (fs.existsSync(OPENCLAW_SESSIONS_DIR)) {
    initOutboundWatcher();
  }
});

// Replay timer
setInterval(replayBuffered, REPLAY_INTERVAL_MS);

// Probe timer — start immediately
setInterval(probeUpstream, PROBE_INTERVAL_MS);
probeUpstream();

// ─── OpenClaw Status Page Server (:3001) ───

const STATUS_PORT = parseInt(process.env.STATUS_PORT || "3001", 10);
const STATUS_PUBLIC = path.join(__dirname, "public");
const MONITORING_DIR = process.env.MONITORING_DIR || "/shared/monitoring";

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".svg": "image/svg+xml",
};

function tailFileSync(filePath, lines) {
  try {
    const content = fs.readFileSync(filePath, "utf-8");
    const allLines = content.split("\n");
    return allLines.slice(-lines).join("\n");
  } catch {
    return "";
  }
}

function readJsonSync(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf-8"));
  } catch {
    return null;
  }
}

function handleStatusApi(reqUrl, res) {
  const url = new URL(reqUrl, "http://localhost");

  if (url.pathname === "/api/emotion") {
    let latestOutbound = null;
    for (const p of ["line", "discord"]) {
      const content = tailFileSync(path.join(CONV_DIR, `${p}.jsonl`), 20);
      if (!content) continue;
      const msgs = content.split("\n")
        .filter((l) => l.trim())
        .map((l) => { try { return JSON.parse(l); } catch { return null; } })
        .filter((m) => m && m.direction === "outbound");
      for (const m of msgs) {
        if (!latestOutbound || m.timestamp > latestOutbound.timestamp) {
          latestOutbound = m;
        }
      }
    }

    let emotion = "neutral";
    let source = "default";
    const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000).toISOString();

    if (latestOutbound && latestOutbound.timestamp > fiveMinAgo && latestOutbound.emotion_hint) {
      emotion = latestOutbound.emotion_hint;
      source = "emotion_hint";
    } else if (latestOutbound && latestOutbound.timestamp > fiveMinAgo) {
      emotion = estimateOutboundEmotion(latestOutbound.content);
      source = "keyword_fallback";
    }

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ emotion, source, last_message_at: latestOutbound ? latestOutbound.timestamp : null }));
    return true;
  }

  if (url.pathname === "/api/emotion-distribution") {
    const hours = Math.min(parseInt(url.searchParams.get("hours") || "48", 10), 168);
    const cutoff = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();
    const counts = {};
    for (const p of ["line", "discord"]) {
      const content = tailFileSync(path.join(CONV_DIR, `${p}.jsonl`), 2000);
      if (!content) continue;
      const msgs = content.split("\n")
        .filter((l) => l.trim())
        .map((l) => { try { return JSON.parse(l); } catch { return null; } })
        .filter((m) => m && m.direction === "outbound" && m.timestamp >= cutoff);
      for (const m of msgs) {
        const e = m.emotion_hint || "neutral";
        counts[e] = (counts[e] || 0) + 1;
      }
    }

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ hours, counts, total: Object.values(counts).reduce((a, b) => a + b, 0) }));
    return true;
  }

  if (url.pathname === "/api/status") {
    const data = readJsonSync(path.join(MONITORING_DIR, "latest.json"));
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(data || { status: "unknown", message: "No monitoring data available" }));
    return true;
  }

  return false;
}

function serveStaticFile(reqPath, res) {
  let filePath = reqPath === "/" ? "/index.html" : reqPath;

  // Prevent directory traversal
  const safePath = path.normalize(filePath).replace(/^(\.\.[/\\])+/, "");
  const fullPath = path.join(STATUS_PUBLIC, safePath);

  if (!fullPath.startsWith(STATUS_PUBLIC)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  try {
    const data = fs.readFileSync(fullPath);
    const ext = path.extname(fullPath).toLowerCase();
    const contentType = MIME_TYPES[ext] || "application/octet-stream";
    res.writeHead(200, { "Content-Type": contentType });
    res.end(data);
  } catch {
    // Fallback to index.html for SPA
    try {
      const index = fs.readFileSync(path.join(STATUS_PUBLIC, "index.html"));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(index);
    } catch {
      res.writeHead(404);
      res.end("Not Found");
    }
  }
}

const statusServer = http.createServer((req, res) => {
  if (req.method === "GET" && handleStatusApi(req.url, res)) return;
  if (req.method === "GET") {
    serveStaticFile(req.url.split("?")[0], res);
    return;
  }
  res.writeHead(405);
  res.end("Method Not Allowed");
});

statusServer.listen(STATUS_PORT, () => {
  log(`OpenClaw Status page listening on :${STATUS_PORT}`);
});
