#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_HOME="/home/openclaw/.openclaw"
DATA_DIR="/app/data"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

log "OpenClaw container starting..."

# Apply network restrictions as root before dropping privileges
if [[ "$(id -u)" == "0" ]]; then
  /app/network-restrict.sh apply
  log "Network restrictions applied. Dropping privileges to openclaw user..."
fi

# Clean up stale lock files
rm -rf /tmp/openclaw-* 2>/dev/null || true

# Ensure required directories exist
mkdir -p "${OPENCLAW_HOME}/workspace"
mkdir -p "${OPENCLAW_HOME}/agents/main/sessions"
mkdir -p "${OPENCLAW_HOME}/credentials"
mkdir -p "${OPENCLAW_HOME}/canvas"
chmod 700 "${OPENCLAW_HOME}" 2>/dev/null || true

# Link persistent data directories
if [[ -d "${DATA_DIR}" ]]; then
  for dir in workspace agents sessions memory; do
    mkdir -p "${DATA_DIR}/${dir}"
    ln -sfn "${DATA_DIR}/${dir}" "${OPENCLAW_HOME}/${dir}"
  done
  log "Persistent data directories linked."
fi

# Deploy Masaru personality files to workspace (after symlinks so files land in persistent storage)
if [[ -f /app/personality/SOUL.md ]]; then
  cp /app/personality/SOUL.md "${OPENCLAW_HOME}/workspace/SOUL.md"
  log "SOUL.md deployed to workspace."
fi
if [[ -f /app/personality/IDENTITY.md ]]; then
  cp /app/personality/IDENTITY.md "${OPENCLAW_HOME}/workspace/IDENTITY.md"
  log "IDENTITY.md deployed to workspace."
fi

# Check required env vars
if [[ -z "${DISCORD_BOT_TOKEN:-}" ]]; then
  echo "ERROR: DISCORD_BOT_TOKEN is not set."
  exit 1
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  log "WARNING: ANTHROPIC_API_KEY is not set."
fi

MODEL="${OPENCLAW_MODEL:-anthropic/claude-sonnet-4-20250514}"
GW_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"

# Write config directly via node (fast, no CLI overhead)
CONFIG_FILE="${OPENCLAW_HOME}/openclaw.json"
log "Writing configuration..."

node -e "
const fs = require('fs');
// Read existing config or start fresh
let config = {};
try { config = JSON.parse(fs.readFileSync('${CONFIG_FILE}', 'utf8')); } catch(e) {}

// Merge agent model config
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = { primary: process.env.OPENCLAW_MODEL || 'anthropic/claude-sonnet-4-20250514' };

// Merge Discord channel config
config.channels = config.channels || {};
config.channels.discord = Object.assign(config.channels.discord || {}, {
  enabled: true,
  token: process.env.DISCORD_BOT_TOKEN,
  guilds: { '*': { requireMention: false } },
  dm: { enabled: true, policy: 'pairing' },
  textChunkLimit: 2000,
  historyLimit: 20,
  dmHistoryLimit: 10,
  retry: { attempts: 3, minDelayMs: 500, maxDelayMs: 30000, jitter: 0.1 },
  actions: { reactions: true, messages: true, threads: true, moderation: false, roles: false, presence: false }
});

// Merge gateway config
config.gateway = Object.assign(config.gateway || {}, { bind: 'loopback', mode: 'local' });
if (process.env.OPENCLAW_GATEWAY_TOKEN) {
  config.gateway.auth = { mode: 'token', token: process.env.OPENCLAW_GATEWAY_TOKEN };
}

// Ensure Discord plugin is enabled
config.plugins = config.plugins || {};
config.plugins.entries = config.plugins.entries || {};
config.plugins.entries.discord = { enabled: true };

fs.writeFileSync('${CONFIG_FILE}', JSON.stringify(config, null, 2));
console.log('Config written successfully');
" 2>&1

chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
log "Configuration written (model: ${MODEL})."

# Start gateway directly (no doctor --fix to avoid lock conflicts)
log "Starting OpenClaw gateway..."
if [[ "$(id -u)" == "0" ]]; then
  exec gosu openclaw openclaw gateway run --verbose --force
else
  exec openclaw gateway run --verbose --force
fi
