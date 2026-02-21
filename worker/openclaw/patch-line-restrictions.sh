#!/usr/bin/env bash
# patch-line-restrictions.sh
# Patches OpenClaw to enforce LINE channel restrictions:
#   1. Remove web_search/web_fetch tools from main LINE sessions (sub-agents keep them)
#   2. Block Push API at LINE SDK level (messagingApiClient.pushMessage)
#   3. Inject pending messages into LINE replies (dist deliverLineAutoReply)
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

# --- Patch 2: Block Push API at LINE SDK level ---
# Instead of patching individual dist push functions, block at the SDK layer:
#   MessagingApiClient.pushMessage() → no-op with log
#   MessagingApiClient.pushMessageWithHttpInfo() → no-op with log
# This catches ALL code paths: dist functions, TypeScript extensions, WebSocket chat.send, etc.
# Reply API (replyMessage/replyMessageWithHttpInfo) is unaffected.
patch_push_api_sdk() {
  local sdk_file="/usr/local/lib/node_modules/openclaw/node_modules/@line/bot-sdk/dist/messaging-api/api/messagingApiClient.js"
  if [[ ! -f "$sdk_file" ]]; then
    log "WARNING: LINE SDK messagingApiClient.js not found, skipping push API patch"
    return 1
  fi

  if grep -q 'LINE-PUSH-BLOCKED' "$sdk_file" 2>/dev/null; then
    log "SDK already patched (push API blocked)"
    return 0
  fi

  cat > /tmp/patch-push-sdk.js << 'NODEOF'
const fs = require("fs");
const file = "/usr/local/lib/node_modules/openclaw/node_modules/@line/bot-sdk/dist/messaging-api/api/messagingApiClient.js";
let code = fs.readFileSync(file, "utf8");

// --- Block pushMessage() ---
const pushOld = [
  "    async pushMessage(pushMessageRequest, xLineRetryKey) {",
  "        return (await this.pushMessageWithHttpInfo(pushMessageRequest, xLineRetryKey)).body;",
  "    }"
].join("\n");

const pushNew = [
  "    async pushMessage(pushMessageRequest, xLineRetryKey) {",
  "        // [LINE-PUSH-BLOCKED]",
  '        console.log("[LINE-PUSH-BLOCKED] pushMessage blocked: to=" + (pushMessageRequest && pushMessageRequest.to || "unknown"));',
  "        return {};",
  "    }"
].join("\n");

if (!code.includes(pushOld)) {
  console.log("ERROR: pushMessage pattern not found in SDK");
  process.exit(1);
}
code = code.replace(pushOld, pushNew);
console.log("Blocked: pushMessage()");

// --- Block pushMessageWithHttpInfo() ---
const withInfoOld = [
  "    async pushMessageWithHttpInfo(pushMessageRequest, xLineRetryKey) {",
  "        const params = pushMessageRequest;",
  "        const headerParams = {",
  '            ...(xLineRetryKey != null ? { "X-Line-Retry-Key": xLineRetryKey } : {}),',
  "        };",
  '        const res = await this.httpClient.post("/v2/bot/message/push", params, { headers: headerParams });',
  "        const text = await res.text();",
  "        const parsedBody = text ? JSON.parse(text) : null;",
  "        return { httpResponse: res, body: parsedBody };",
  "    }"
].join("\n");

const withInfoNew = [
  "    async pushMessageWithHttpInfo(pushMessageRequest, xLineRetryKey) {",
  "        // [LINE-PUSH-BLOCKED]",
  '        console.log("[LINE-PUSH-BLOCKED] pushMessageWithHttpInfo blocked: to=" + (pushMessageRequest && pushMessageRequest.to || "unknown"));',
  "        return { httpResponse: {}, body: {} };",
  "    }"
].join("\n");

if (!code.includes(withInfoOld)) {
  console.log("ERROR: pushMessageWithHttpInfo pattern not found in SDK");
  process.exit(1);
}
code = code.replace(withInfoOld, withInfoNew);
console.log("Blocked: pushMessageWithHttpInfo()");

fs.writeFileSync(file, code);
console.log("SDK push API patch complete");
NODEOF

  node /tmp/patch-push-sdk.js 2>&1
  rm -f /tmp/patch-push-sdk.js

  if grep -q 'LINE-PUSH-BLOCKED' "$sdk_file" 2>/dev/null; then
    log "SDK patched: pushMessage + pushMessageWithHttpInfo blocked at SDK level"
  else
    log "WARNING: SDK push API patch may have failed"
    return 1
  fi
}

# --- Patch 3: Inject pending messages into LINE replies ---
# When replying to a LINE message, check /bot_commands/line_pending_{userId}.json
# and prepend any pending messages to the reply text automatically.
# Targets dist files containing deliverLineAutoReply (not loader-*.js which no longer exists).
# Uses existsSync/readFileSync/writeFileSync from top-level ESM import (node:fs).
patch_pending_injection() {
  # Find dist files containing the marker
  local marker_files
  marker_files=$(grep -rl 'let replyTokenUsed = params.replyTokenUsed' "$OPENCLAW_DIST" 2>/dev/null || true)
  if [[ -z "$marker_files" ]]; then
    log "WARNING: pending injection marker not found in dist, skipping"
    return 1
  fi

  # Check if already patched (LINE-PENDING marker present in all matching files)
  local needs_patch=false
  for f in $marker_files; do
    if ! grep -q 'LINE-PENDING' "$f" 2>/dev/null; then
      needs_patch=true
      break
    fi
  done

  if ! $needs_patch; then
    log "Dist already patched (LINE pending injection)"
    return 0
  fi

  cat > /tmp/patch-pending-dist.js << 'NODEOF'
const fs = require("fs");
const distDir = "/usr/local/lib/node_modules/openclaw/dist";
const allFiles = fs.readdirSync(distDir).filter(function(f) { return f.endsWith(".js"); });

const marker = "let replyTokenUsed = params.replyTokenUsed;";
let patchedCount = 0;

for (const fname of allFiles) {
  const fpath = distDir + "/" + fname;
  let code;
  try { code = fs.readFileSync(fpath, "utf8"); } catch(e) { continue; }
  if (!code.includes(marker)) continue;
  if (code.includes("LINE-PENDING")) { console.log("Already patched: " + fname); continue; }

  // Injection code — uses existsSync/readFileSync/writeFileSync from top-level ESM import
  var injection = [
    "",
    "\t// [LINE-PENDING] Prepend pending messages to LINE reply",
    "\ttry {",
    "\t\tvar _toId = to.replace(/^line:group:/, '').replace(/^line:room:/, '').replace(/^line:/, '');",
    "\t\tvar _pp = '/bot_commands/line_pending_' + _toId + '.json';",
    "\t\tif (existsSync(_pp)) {",
    "\t\t\tvar _pd = JSON.parse(readFileSync(_pp, 'utf8'));",
    "\t\t\tif (_pd.pending_messages && _pd.pending_messages.length > 0) {",
    "\t\t\t\tvar _pt = _pd.pending_messages.map(function(m){ return m.text; }).join('\\n\\n---\\n\\n');",
    "\t\t\t\tpayload.text = _pt + (payload.text ? '\\n\\n---\\n\\n' + payload.text : '');",
    "\t\t\t\t_pd.delivered_messages = (_pd.delivered_messages || []).concat(",
    "\t\t\t\t\t_pd.pending_messages.map(function(m){ m.delivered_at = new Date().toISOString().replace(/\\.\\d{3}Z$/, 'Z'); return m; })",
    "\t\t\t\t);",
    "\t\t\t\t_pd.pending_messages = [];",
    "\t\t\t\t_pd.updated_at = new Date().toISOString().replace(/\\.\\d{3}Z$/, 'Z');",
    "\t\t\t\twriteFileSync(_pp, JSON.stringify(_pd, null, 2));",
    "\t\t\t\tconsole.log('[LINE-PENDING] Injected ' + _pt.length + ' chars for ' + _toId);",
    "\t\t\t}",
    "\t\t}",
    "\t} catch(_e) { console.log('[LINE-PENDING] Error: ' + _e.message); }",
  ].join("\n");

  code = code.replace(marker, marker + injection);
  fs.writeFileSync(fpath, code);
  patchedCount++;
  console.log("Patched: " + fname);
}
console.log("Total files patched: " + patchedCount);
NODEOF

  node /tmp/patch-pending-dist.js 2>&1
  rm -f /tmp/patch-pending-dist.js

  local total
  total=$(grep -rl 'LINE-PENDING' "$OPENCLAW_DIST"/*.js 2>/dev/null | wc -l)
  if [[ "$total" -gt 0 ]]; then
    log "Pending injection applied in $total dist files"
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

# --- Patch 6: Evolution Trigger (Opus upgrade on owner command) ---
# When the owner says "Masaru-kun進化！", inject /model directive to switch to Opus
# for 30 minutes. Auto-reverts on next message after expiry.
# Patched in resolveReplyDirectives(): const→let for commandText,
# then inject evolution check before parseInlineDirectives().
patch_evolution_trigger() {
  local file
  file=$(find "$OPENCLAW_DIST" -name 'loader-*.js' -print -quit 2>/dev/null || true)
  if [[ -z "$file" || ! -f "$file" ]]; then
    log "WARNING: loader file not found, skipping evolution trigger patch"
    return 1
  fi

  if grep -q 'EVOLUTION-TRIGGER' "$file" 2>/dev/null; then
    log "Loader already patched (evolution trigger)"
    return 0
  fi

  cat > /tmp/patch-evolution.js << 'NODEOF'
const fs = require("fs");
const distDir = "/usr/local/lib/node_modules/openclaw/dist";
const loaderFiles = fs.readdirSync(distDir).filter(function(f) { return f.startsWith("loader-") && f.endsWith(".js"); });
if (loaderFiles.length === 0) { console.log("ERROR: no loader file found"); process.exit(1); }
const fpath = distDir + "/" + loaderFiles[0];
let code = fs.readFileSync(fpath, "utf8");

// Step 1: Inject evolution state check before parseInlineDirectives
// This handles: detection, state file read/write, expiry cleanup
const parseMarker = "let parsedDirectives = parseInlineDirectives(commandText,";
if (!code.includes(parseMarker)) {
  console.log("ERROR: parseInlineDirectives marker not found");
  process.exit(1);
}

var stateInjection = [
  "",
  "\t// [EVOLUTION-TRIGGER] State management (detect trigger, manage timer)",
  "\tvar _evoActive = false;",
  "\ttry {",
  "\t\tvar _evoFile = '/tmp/openclaw-evolution.json';",
  "\t\tvar _evoData = {};",
  "\t\tif (existsSync(_evoFile)) {",
  "\t\t\t_evoData = JSON.parse(readFileSync(_evoFile, 'utf8'));",
  "\t\t}",
  "\t\tvar _evoSid = ctx.SenderId || command.senderId || '';",
  "\t\tvar _evoOwnerLine = process.env.OWNER_LINE_ID || '';",
  "\t\tvar _evoOwnerDiscord = process.env.OWNER_DISCORD_ID || '';",
  "\t\tvar _evoIsOwner = (_evoSid && (_evoSid === _evoOwnerLine || _evoSid === _evoOwnerDiscord));",
  "\t\tvar _evoKey = (command.from || sessionKey || '') + ':evo';",
  "\t\tif (_evoData[_evoKey] && new Date(_evoData[_evoKey].expires_at) <= new Date()) {",
  "\t\t\tdelete _evoData[_evoKey];",
  "\t\t\tif (Object.keys(_evoData).length === 0) {",
  "\t\t\t\tunlinkSync(_evoFile);",
  "\t\t\t} else {",
  "\t\t\t\twriteFileSync(_evoFile, JSON.stringify(_evoData, null, 2));",
  "\t\t\t}",
  "\t\t\tconsole.log('[EVOLUTION-TRIGGER] Session ' + _evoKey + ' expired, reverted to default');",
  "\t\t}",
  "\t\telse if (_evoIsOwner && commandText.includes('Masaru-kun\\u9032\\u5316\\uff01')) {",
  "\t\t\t_evoData[_evoKey] = {",
  "\t\t\t\tactivated_at: _evoData[_evoKey] ? _evoData[_evoKey].activated_at : new Date().toISOString(),",
  "\t\t\t\texpires_at: new Date(Date.now() + 30*60*1000).toISOString()",
  "\t\t\t};",
  "\t\t\twriteFileSync(_evoFile, JSON.stringify(_evoData, null, 2));",
  "\t\t\t_evoActive = true;",
  "\t\t\tconsole.log('[EVOLUTION-TRIGGER] Opus triggered for session ' + _evoKey + ' (owner: ' + _evoSid + ')');",
  "\t\t}",
  "\t\telse if (_evoData[_evoKey] && new Date(_evoData[_evoKey].expires_at) > new Date()) {",
  "\t\t\t_evoActive = true;",
  "\t\t}",
  "\t} catch(_evoErr) { console.log('[EVOLUTION-TRIGGER] Error: ' + _evoErr.message); }",
].join("\n");

code = code.replace(parseMarker, stateInjection + "\n\t" + parseMarker);
console.log("Step 1: Evolution state management injected");

// Step 2: Inject model override after "model = modelState.model;"
// Directly sets provider/model when evolution is active (bypasses commandAuthorized check)
const modelMarker = "\tmodel = modelState.model;\n\tlet contextTokens = resolveContextTokens({";
if (!code.includes(modelMarker)) {
  console.log("ERROR: model assignment marker not found");
  process.exit(1);
}

var modelInjection = [
  "\tmodel = modelState.model;",
  "\t// [EVOLUTION-TRIGGER] Direct model override (bypasses directive auth)",
  "\tif (_evoActive) {",
  "\t\tprovider = 'anthropic';",
  "\t\tmodel = 'claude-opus-4-6';",
  "\t\tconsole.log('[EVOLUTION-TRIGGER] Model overridden to anthropic/claude-opus-4-6');",
  "\t}",
  "\tlet contextTokens = resolveContextTokens({",
].join("\n");

code = code.replace(modelMarker, modelInjection);
console.log("Step 2: Direct model override injected");

fs.writeFileSync(fpath, code);
console.log("Evolution trigger patch applied to " + loaderFiles[0]);
NODEOF

  node /tmp/patch-evolution.js 2>&1
  rm -f /tmp/patch-evolution.js

  if grep -q 'EVOLUTION-TRIGGER' "$file" 2>/dev/null; then
    log "Loader patched: evolution trigger active (Opus upgrade on owner command)"
  else
    log "WARNING: evolution trigger patch may have failed"
    return 1
  fi
}

# --- Patch 7: Fix LINE provider crash-loop ---
# OpenClaw's LINE plugin startAccount returns monitorLineProvider() which resolves immediately
# (webhook-based provider, no long-running connection). The gateway treats the resolved promise
# as "stopped" and triggers auto-restart in a loop. Fix: wrap in a Promise that waits on abortSignal.
patch_line_startup_keepalive() {
  local file="/usr/local/lib/node_modules/openclaw/extensions/line/src/channel.ts"
  if [[ ! -f "$file" ]]; then
    log "WARNING: LINE channel.ts not found"
    return 1
  fi

  if grep -q 'Keep the task alive until abortSignal' "$file" 2>/dev/null; then
    log "LINE channel.ts already patched (startup keepalive)"
    return 0
  fi

  cat > /tmp/patch-line-startup.js << 'NODEOF'
const fs = require("fs");
const file = "/usr/local/lib/node_modules/openclaw/extensions/line/src/channel.ts";
let code = fs.readFileSync(file, "utf8");

const oldCode = `      return getLineRuntime().channel.line.monitorLineProvider({
        channelAccessToken: token,
        channelSecret: secret,
        accountId: account.accountId,
        config: ctx.cfg,
        runtime: ctx.runtime,
        abortSignal: ctx.abortSignal,
        webhookPath: account.config.webhookPath,
      });`;

const newCode = `      // Start LINE provider (webhook-based, returns immediately)
      const providerResult = await getLineRuntime().channel.line.monitorLineProvider({
        channelAccessToken: token,
        channelSecret: secret,
        accountId: account.accountId,
        config: ctx.cfg,
        runtime: ctx.runtime,
        abortSignal: ctx.abortSignal,
        webhookPath: account.config.webhookPath,
      });

      // Keep the task alive until abortSignal fires. LINE webhook provider
      // returns immediately after registering routes — without this wait,
      // the gateway treats the resolved promise as "stopped" and triggers
      // an infinite auto-restart loop.
      await new Promise<void>((resolve) => {
        if (ctx.abortSignal?.aborted) { resolve(); return; }
        ctx.abortSignal?.addEventListener("abort", () => resolve(), { once: true });
      });

      return providerResult;`;

if (!code.includes("monitorLineProvider(")) {
  console.log("ERROR: monitorLineProvider not found in channel.ts");
  process.exit(1);
}

code = code.replace(oldCode, newCode);
fs.writeFileSync(file, code);
console.log("LINE startup keepalive patch applied");
NODEOF

  node /tmp/patch-line-startup.js 2>&1
  rm -f /tmp/patch-line-startup.js

  if grep -q 'Keep the task alive until abortSignal' "$file" 2>/dev/null; then
    log "LINE channel.ts patched: startup keepalive active (prevents crash-loop)"
  else
    log "WARNING: LINE startup keepalive patch may have failed"
    return 1
  fi
}

# --- Apply patches ---
# Each patch runs independently — failure of one must not block the other.
log "Applying channel restrictions..."
patch_coding_tools || log "WARNING: patch_coding_tools failed (continuing)"
patch_push_api_sdk || log "WARNING: patch_push_api_sdk failed (continuing)"
patch_pending_injection || log "WARNING: patch_pending_injection failed (continuing)"
patch_pause_enforcement || log "WARNING: patch_pause_enforcement failed (continuing)"
patch_discord_pause_enforcement || log "WARNING: patch_discord_pause_enforcement failed (continuing)"
patch_evolution_trigger || log "WARNING: patch_evolution_trigger failed (continuing)"
patch_line_startup_keepalive || log "WARNING: patch_line_startup_keepalive failed (continuing)"
log "Channel restrictions applied."
