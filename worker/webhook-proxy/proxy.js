const http = require("http");
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

let upstreamState = "UNKNOWN"; // UNKNOWN, DOWN, STARTING, READY
let firstRespondAt = 0;

// Ensure buffer directory exists
fs.mkdirSync(BUFFER_DIR, { recursive: true });

// Ensure conversation log directory exists
try { fs.mkdirSync(CONV_DIR, { recursive: true }); } catch { /* ignore */ }

// ─── LINE Webhook Conversation Logging ───

function estimateEmotionFromText(text) {
  if (!text) return "idle";
  if (/ありがとう|嬉しい|やった|thanks|thx/i.test(text)) return "happy";
  if (/困った|どうしよう|心配|ヤバい|まずい/i.test(text)) return "concerned";
  if (/？|\?|教えて|どう|なに|いつ|どこ|why|how|what/i.test(text)) return "thinking";
  return "idle";
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

function extractUserFromSource(source) {
  if (!source) return "unknown";
  return source.userId ? source.userId.slice(-8) : "unknown";
}

function extractChannelFromSource(source) {
  if (!source) return "unknown";
  if (source.groupId) return `group_${source.groupId.slice(-8)}`;
  if (source.roomId) return `room_${source.roomId.slice(-8)}`;
  return `dm_${(source.userId || "unknown").slice(-8)}`;
}

function logLineInbound(body) {
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

      const entry = {
        timestamp: new Date(event.timestamp || Date.now()).toISOString(),
        platform: "line",
        direction: "inbound",
        channel: extractChannelFromSource(event.source),
        user: extractUserFromSource(event.source),
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
});

// Replay timer
setInterval(replayBuffered, REPLAY_INTERVAL_MS);

// Probe timer — start immediately
setInterval(probeUpstream, PROBE_INTERVAL_MS);
probeUpstream();
