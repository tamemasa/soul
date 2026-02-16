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

# --- Apply patches ---
# Each patch runs independently — failure of one must not block the other.
log "Applying LINE channel restrictions..."
patch_coding_tools || log "WARNING: patch_coding_tools failed (continuing)"
patch_push_api_all || log "WARNING: patch_push_api_all failed (continuing)"
log "LINE channel restrictions applied."
