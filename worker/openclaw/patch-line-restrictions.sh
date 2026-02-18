#!/usr/bin/env bash
# patch-line-restrictions.sh
# Patches OpenClaw to enforce LINE channel restrictions:
#   1. Remove web_search/web_fetch tools from main LINE sessions (sub-agents keep them)
#   2. Block ALL Push API functions across all dist files
#   3. Block sendMessageLine push path (direct client.pushMessage fallback)
#
# Applied at container startup (entrypoint.sh) after npm install,
# because openclaw is installed globally and the dist files are overwritten on rebuild.

set -euo pipefail

OPENCLAW_DIST="/usr/local/lib/node_modules/openclaw/dist"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [line-patch] $*"
}

# --- Patch 1: Remove web_search/web_fetch for main LINE sessions in createOpenClawCodingTools ---
# Main LINE sessions should NOT have web_search/web_fetch (they delegate research via sessions_spawn).
# Sub-agents (spawnedBy is set) keep these tools so they can actually do the research.
patch_coding_tools() {
  local file
  file=$(find "$OPENCLAW_DIST" -name 'loader-*.js' -print -quit 2>/dev/null || true)
  if [[ -z "$file" || ! -f "$file" ]]; then
    log "WARNING: loader file not found, skipping tool exclusion patch"
    return 1
  fi

  # Check if already patched
  if grep -q 'LINE-FILTER' "$file" 2>/dev/null; then
    log "Loader already patched (LINE tool filter)"
    return 0
  fi

  # Use node.js to apply the patch (avoids shell quoting issues with perl/sed)
  node -e "
const fs = require('fs');
const file = '$file';
let code = fs.readFileSync(file, 'utf8');

// Step 1: Change const to let for toolsByAuthorization
code = code.replace(
  'const toolsByAuthorization = applyOwnerOnlyToolPolicy',
  'let toolsByAuthorization = applyOwnerOnlyToolPolicy'
);

// Step 2: Insert LINE filter after toolsByAuthorization assignment
const marker = '], options?.senderIsOwner === true);';
const filterCode = ' if (!options?.spawnedBy && resolveGatewayMessageChannel(options?.messageProvider) === \"line\") { const blocked = new Set([\"web_search\",\"web_fetch\"]); toolsByAuthorization = toolsByAuthorization.filter(t => !blocked.has(t.name)); console.log(\"[LINE-FILTER] Removed web_search/web_fetch for main LINE session. tools=\" + toolsByAuthorization.length); }';
code = code.replace(marker, marker + filterCode);

fs.writeFileSync(file, code);
console.log('Patch applied successfully');
" 2>&1

  if grep -q 'LINE-FILTER' "$file" 2>/dev/null; then
    log "Loader patched: web_search/web_fetch excluded for main LINE sessions (sub-agents unaffected)"
  else
    log "WARNING: Loader patch may have failed (pattern not found)"
    return 1
  fi
}

# --- Patch 2: Block ALL Push API functions across all dist/*.js files ---
# Blocks: pushMessageLine, pushMessagesLine, pushTextMessageWithQuickReplies,
#         pushFlexMessage, pushLocationMessage, pushTemplateMessage
# Also blocks sendMessageLine push path (direct client.pushMessage fallback)
patch_push_api_all() {
  # Write patch script to temp file (avoids shell quoting issues)
  cat > /tmp/patch-push-all.js << 'NODEOF'
const fs = require("fs");
const distDir = "/usr/local/lib/node_modules/openclaw/dist";
const allFiles = fs.readdirSync(distDir).filter(function(f) { return f.endsWith(".js"); });

// --- Part A: Block push function definitions ---
const pushFunctions = [
  { sig: 'async function pushMessageLine(to, text, opts = {}) {', block: '\tconsole.log("[LINE-PUSH-BLOCKED] pushMessageLine dropped: to=" + to); return { messageId: "push-blocked", chatId: to };' },
  { sig: 'async function pushMessagesLine(to, messages, opts = {}) {', block: '\tconsole.log("[LINE-PUSH-BLOCKED] pushMessagesLine dropped: to=" + to); return { messageId: "push-blocked", chatId: to };' },
  { sig: 'async function pushTextMessageWithQuickReplies(to, text, quickReplyLabels, opts = {}) {', block: '\tconsole.log("[LINE-PUSH-BLOCKED] pushTextMessageWithQuickReplies dropped: to=" + to); return { messageId: "push-blocked", chatId: to };' },
  { sig: 'async function pushFlexMessage(to, altText, contents, opts = {}) {', block: '\tconsole.log("[LINE-PUSH-BLOCKED] pushFlexMessage dropped: to=" + to); return { messageId: "push-blocked", chatId: to };' },
  { sig: 'async function pushLocationMessage(to, location, opts = {}) {', block: '\tconsole.log("[LINE-PUSH-BLOCKED] pushLocationMessage dropped: to=" + to); return { messageId: "push-blocked", chatId: to };' },
  { sig: 'async function pushTemplateMessage(to, template, opts = {}) {', block: '\tconsole.log("[LINE-PUSH-BLOCKED] pushTemplateMessage dropped: to=" + to); return { messageId: "push-blocked", chatId: to };' },
];

// --- Part B: Block sendMessageLine push path ---
const sendMsgOld = '\tawait client.pushMessage({\n\t\tto: chatId,\n\t\tmessages\n\t});\n\trecordChannelActivity({\n\t\tchannel: "line",\n\t\taccountId: account.accountId,\n\t\tdirection: "outbound"\n\t});\n\tif (opts.verbose) logVerbose(`line: pushed message to ${chatId}`);\n\treturn {\n\t\tmessageId: "push",\n\t\tchatId\n\t};';
const sendMsgGuard = '\tconsole.log("[LINE-PUSH-BLOCKED] sendMessageLine push path blocked: to=" + chatId); return { messageId: "push-blocked", chatId };\n';

let totalPatched = 0;
for (const fname of allFiles) {
  const fpath = distDir + "/" + fname;
  let code;
  try { code = fs.readFileSync(fpath, "utf8"); } catch(e) { continue; }
  if (code.includes("LINE-PUSH-BLOCKED")) continue;

  let patched = false;

  // Part A: Block push functions
  for (const pf of pushFunctions) {
    if (code.includes(pf.sig)) {
      code = code.replace(pf.sig, pf.sig + "\n" + pf.block);
      patched = true;
    }
  }

  // Part B: Block sendMessageLine push path
  if (code.includes(sendMsgOld) && !code.includes("sendMessageLine push path blocked")) {
    code = code.replace(sendMsgOld, sendMsgGuard + sendMsgOld);
    patched = true;
  }

  if (patched) {
    fs.writeFileSync(fpath, code);
    const count = (code.match(/LINE-PUSH-BLOCKED/g) || []).length;
    console.log("Patched " + fname + " (" + count + " push paths blocked)");
    totalPatched++;
  }
}
console.log("Total files patched: " + totalPatched);
NODEOF

  node /tmp/patch-push-all.js 2>&1
  rm -f /tmp/patch-push-all.js

  local total
  total=$(grep -rl 'LINE-PUSH-BLOCKED' "$OPENCLAW_DIST"/*.js 2>/dev/null | wc -l)
  if [[ "$total" -gt 0 ]]; then
    log "Push API blocked in $total dist files"
  else
    log "WARNING: Push API patch may have failed"
    return 1
  fi
}

# --- Patch 3: Inject pending messages into LINE replies ---
# When replying to a LINE message, check /bot_commands/line_pending_{userId}.json
# and prepend any pending messages to the reply text automatically.
# Uses existsSync/readFileSync/writeFileSync already imported in the ESM loader.
patch_pending_injection() {
  local file
  file=$(find "$OPENCLAW_DIST" -name 'loader-*.js' -print -quit 2>/dev/null || true)
  if [[ -z "$file" || ! -f "$file" ]]; then
    log "WARNING: loader file not found, skipping pending injection patch"
    return 1
  fi

  if grep -q 'LINE-PENDING' "$file" 2>/dev/null; then
    log "Loader already patched (LINE pending injection)"
    return 0
  fi

  cat > /tmp/patch-pending.js << 'NODEOF'
const fs = require("fs");
const distDir = "/usr/local/lib/node_modules/openclaw/dist";
const loaderFiles = fs.readdirSync(distDir).filter(function(f) { return f.startsWith("loader-") && f.endsWith(".js"); });
if (loaderFiles.length === 0) { console.log("ERROR: no loader file found"); process.exit(1); }
const fpath = distDir + "/" + loaderFiles[0];
let code = fs.readFileSync(fpath, "utf8");

const marker = "let replyTokenUsed = params.replyTokenUsed;";
if (!code.includes(marker)) {
  console.log("ERROR: marker not found in " + loaderFiles[0]);
  process.exit(1);
}

// Injection uses existsSync/readFileSync/writeFileSync from the ESM import already in scope
// (imported as: import fs, { existsSync, ..., readFileSync, ..., writeFileSync } from "node:fs")
// `to` has format "line:userId" or "line:group:groupId" — strip prefix to match pending file names
var injection = [
  "",
  "\ttry {",
  "\t\tvar _toId = to.replace(/^line:group:/, '').replace(/^line:room:/, '').replace(/^line:/, '');",
  "\t\tvar _pp = '/bot_commands/line_pending_' + _toId + '.json';",
  "\t\tconsole.log('[LINE-PENDING] checking ' + _pp);",
  "\t\tif (existsSync(_pp)) {",
  "\t\t\tvar _pd = JSON.parse(readFileSync(_pp, 'utf8'));",
  "\t\t\tif (_pd.pending_messages && _pd.pending_messages.length > 0) {",
  "\t\t\t\tvar _pt = _pd.pending_messages.map(function(m){ return m.text; }).join('\\n\\n---\\n\\n');",
  "\t\t\t\tpayload.text = _pt + (payload.text ? '\\n\\n---\\n\\n' + payload.text : '');",
  "\t\t\t\t_pd.delivered_messages = _pd.pending_messages.map(function(m){ m.delivered_at = new Date().toISOString().replace(/\\.\\d{3}Z$/, 'Z'); return m; });",
  "\t\t\t\t_pd.pending_messages = [];",
  "\t\t\t\t_pd.updated_at = new Date().toISOString().replace(/\\.\\d{3}Z$/, 'Z');",
  "\t\t\t\twriteFileSync(_pp, JSON.stringify(_pd, null, 2));",
  "\t\t\t\tconsole.log('[LINE-PENDING] Injected ' + _pt.length + ' chars of pending messages for ' + _toId);",
  "\t\t\t}",
  "\t\t}",
  "\t} catch(_e) { console.log('[LINE-PENDING] Error: ' + _e.message); }",
].join("\n");

code = code.replace(marker, marker + injection);
fs.writeFileSync(fpath, code);
console.log("Pending injection patch applied to " + loaderFiles[0]);
NODEOF

  node /tmp/patch-pending.js 2>&1
  rm -f /tmp/patch-pending.js

  if grep -q 'LINE-PENDING' "$file" 2>/dev/null; then
    log "Loader patched: pending messages injected into LINE replies"
  else
    log "WARNING: pending injection patch may have failed"
    return 1
  fi
}

# --- Patch 4: Enforce pause by replacing LINE reply text ---
# When /tmp/openclaw-pause.json exists and is not expired,
# replace the outgoing reply text with a minimal maintenance message.
# Inserted right after the LINE-PENDING injection block.
patch_pause_enforcement() {
  local file
  file=$(find "$OPENCLAW_DIST" -name 'loader-*.js' -print -quit 2>/dev/null || true)
  if [[ -z "$file" || ! -f "$file" ]]; then
    log "WARNING: loader file not found, skipping pause enforcement patch"
    return 1
  fi

  if grep -q 'LINE-PAUSE' "$file" 2>/dev/null; then
    log "Loader already patched (LINE pause enforcement)"
    return 0
  fi

  cat > /tmp/patch-pause.js << 'NODEOF'
const fs = require("fs");
const distDir = "/usr/local/lib/node_modules/openclaw/dist";
const loaderFiles = fs.readdirSync(distDir).filter(function(f) { return f.startsWith("loader-") && f.endsWith(".js"); });
if (loaderFiles.length === 0) { console.log("ERROR: no loader file found"); process.exit(1); }
const fpath = distDir + "/" + loaderFiles[0];
let code = fs.readFileSync(fpath, "utf8");

// Insert after LINE-PENDING catch block
const marker = "} catch(_e) { console.log('[LINE-PENDING] Error: ' + _e.message); }";
if (!code.includes(marker)) {
  console.log("ERROR: LINE-PENDING marker not found — apply patch_pending_injection first");
  process.exit(1);
}

var injection = [
  "",
  "\ttry {",
  "\t\tvar _pauseFile = '/tmp/openclaw-pause.json';",
  "\t\tif (existsSync(_pauseFile)) {",
  "\t\t\tvar _pauseData = JSON.parse(readFileSync(_pauseFile, 'utf8'));",
  "\t\t\tvar _pauseUntil = _pauseData.paused_until ? new Date(_pauseData.paused_until) : null;",
  "\t\t\tif (_pauseUntil && _pauseUntil > new Date()) {",
  "\t\t\t\tconsole.log('[LINE-PAUSE] Pause active until ' + _pauseData.paused_until + ', replacing reply');",
  "\t\t\t\tpayload.text = 'ちょっと今メンテ中。すぐ戻るわ。';",
  "\t\t\t} else if (_pauseUntil && _pauseUntil <= new Date()) {",
  "\t\t\t\tconsole.log('[LINE-PAUSE] Pause expired, removing stale file');",
  "\t\t\t\ttry { require('fs').unlinkSync(_pauseFile); } catch(_ue) {}",
  "\t\t\t}",
  "\t\t}",
  "\t} catch(_pe) { console.log('[LINE-PAUSE] Error: ' + _pe.message); }",
].join("\n");

code = code.replace(marker, marker + injection);
fs.writeFileSync(fpath, code);
console.log("Pause enforcement patch applied to " + loaderFiles[0]);
NODEOF

  node /tmp/patch-pause.js 2>&1
  rm -f /tmp/patch-pause.js

  if grep -q 'LINE-PAUSE' "$file" 2>/dev/null; then
    log "Loader patched: pause enforcement active for LINE replies"
  else
    log "WARNING: pause enforcement patch may have failed"
    return 1
  fi
}

# --- Patch 5: Enforce pause on Discord replies ---
# Mirrors Patch 4 for Discord: when /tmp/openclaw-pause.json is active,
# replace the text parameter of sendMessageDiscord with a maintenance message.
patch_discord_pause_enforcement() {
  local file
  file=$(find "$OPENCLAW_DIST" -name 'loader-*.js' -print -quit 2>/dev/null || true)
  if [[ -z "$file" || ! -f "$file" ]]; then
    log "WARNING: loader file not found, skipping Discord pause enforcement patch"
    return 1
  fi

  if grep -q 'DISCORD-PAUSE' "$file" 2>/dev/null; then
    log "Loader already patched (Discord pause enforcement)"
    return 0
  fi

  cat > /tmp/patch-discord-pause.js << 'NODEOF'
const fs = require("fs");
const distDir = "/usr/local/lib/node_modules/openclaw/dist";
const loaderFiles = fs.readdirSync(distDir).filter(function(f) { return f.startsWith("loader-") && f.endsWith(".js"); });
if (loaderFiles.length === 0) { console.log("ERROR: no loader file found"); process.exit(1); }
const fpath = distDir + "/" + loaderFiles[0];
let code = fs.readFileSync(fpath, "utf8");

const marker = "async function sendMessageDiscord(to, text, opts = {}) {";
if (!code.includes(marker)) {
  console.log("ERROR: sendMessageDiscord marker not found");
  process.exit(1);
}

// Guard inserted at the top of sendMessageDiscord — replaces text if pause is active
var guard = [
  "",
  "\ttry {",
  "\t\tvar _dpf = '/tmp/openclaw-pause.json';",
  "\t\tif (require('fs').existsSync(_dpf)) {",
  "\t\t\tvar _dpd = JSON.parse(require('fs').readFileSync(_dpf, 'utf8'));",
  "\t\t\tvar _dpu = _dpd.paused_until ? new Date(_dpd.paused_until) : null;",
  "\t\t\tif (_dpu && _dpu > new Date()) {",
  "\t\t\t\tconsole.log('[DISCORD-PAUSE] Pause active until ' + _dpd.paused_until + ', replacing reply');",
  "\t\t\t\ttext = 'ちょっと今メンテ中。すぐ戻るわ。';",
  "\t\t\t} else if (_dpu && _dpu <= new Date()) {",
  "\t\t\t\tconsole.log('[DISCORD-PAUSE] Pause expired, removing stale file');",
  "\t\t\t\ttry { require('fs').unlinkSync(_dpf); } catch(_due) {}",
  "\t\t\t}",
  "\t\t}",
  "\t} catch(_dpe) { console.log('[DISCORD-PAUSE] Error: ' + _dpe.message); }",
].join("\n");

code = code.replace(marker, marker + guard);
fs.writeFileSync(fpath, code);
console.log("Discord pause enforcement patch applied to " + loaderFiles[0]);
NODEOF

  node /tmp/patch-discord-pause.js 2>&1
  rm -f /tmp/patch-discord-pause.js

  if grep -q 'DISCORD-PAUSE' "$file" 2>/dev/null; then
    log "Loader patched: pause enforcement active for Discord replies"
  else
    log "WARNING: Discord pause enforcement patch may have failed"
    return 1
  fi
}

# --- Apply patches ---
# Each patch runs independently — failure of one must not block the other.
log "Applying channel restrictions..."
patch_coding_tools || log "WARNING: patch_coding_tools failed (continuing)"
patch_push_api_all || log "WARNING: patch_push_api_all failed (continuing)"
patch_pending_injection || log "WARNING: patch_pending_injection failed (continuing)"
patch_pause_enforcement || log "WARNING: patch_pause_enforcement failed (continuing)"
patch_discord_pause_enforcement || log "WARNING: patch_discord_pause_enforcement failed (continuing)"
log "Channel restrictions applied."
