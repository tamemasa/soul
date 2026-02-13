const http = require("http");
const fs = require("fs");
const path = require("path");

const PROXY_PORT = 8080;
const UPSTREAM_HOST = "openclaw";
const UPSTREAM_PORT = 18789;
const BUFFER_DIR = "/webhook_buffer";
const REPLAY_INTERVAL_MS = 5000;

// Ensure buffer directory exists
fs.mkdirSync(BUFFER_DIR, { recursive: true });

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
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
  let files;
  try {
    files = fs.readdirSync(BUFFER_DIR).filter((f) => f.endsWith(".json")).sort();
  } catch {
    return;
  }

  if (files.length === 0) return;
  log(`Replaying ${files.length} buffered request(s)...`);

  for (const file of files) {
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

// HTTP server
const server = http.createServer((req, res) => {
  // Health check endpoint
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
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
});

// Replay timer
setInterval(replayBuffered, REPLAY_INTERVAL_MS);
