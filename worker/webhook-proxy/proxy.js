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

      messages.push({
        timestamp: obj.timestamp,
        content: texts.join("\n"),
      });
    } catch {}
  }
  return messages;
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
  if (/ええやん|嬉しい|楽しい|ありがとう|おめでとう|笑|良い|いい|ナイス/i.test(text)) return "happy";
  if (/心配|気をつけ|注意|まずい|問題|エラー|error|exception|timeout/i.test(text)) return "concerned";
  if (/調べ|確認|検討|ちょっと待|調査/i.test(text)) return "thinking";
  if (/完了|成功|done|ok|できた/i.test(text)) return "satisfied";
  if (/マジ|えっ|びっくり|すごい|unexpected|驚/i.test(text)) return "surprised";
  if (/残念|悲しい|つらい|申し訳|sorry|ごめん/i.test(text)) return "sad";
  if (/ふざけ|ありえない|許せ|怒|ダメ/i.test(text)) return "angry";
  return "neutral";
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
