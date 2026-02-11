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
  # Ensure bot_commands directory is writable by openclaw
  if [[ -d /bot_commands ]]; then
    chown openclaw:openclaw /bot_commands 2>/dev/null || true
  fi
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
if [[ -f /app/personality/AGENTS.md ]]; then
  cp /app/personality/AGENTS.md "${OPENCLAW_HOME}/workspace/AGENTS.md"
  log "AGENTS.md deployed to workspace."
fi

# Generate OWNER_CONTEXT.md with platform-specific IDs for buddy recognition
OWNER_CTX="${OPENCLAW_HOME}/workspace/OWNER_CONTEXT.md"
{
  echo "# Owner Context - Buddy Recognition"
  echo ""
  echo "以下のIDで Masaru Tamegai を認識する。表示名ではなくIDで本人確認すること。"
  echo ""
  if [[ -n "${OWNER_DISCORD_ID:-}" ]]; then
    echo "- Discord User ID: ${OWNER_DISCORD_ID}"
  fi
  if [[ -n "${OWNER_GITHUB_USERNAME:-}" ]]; then
    echo "- GitHub Username: ${OWNER_GITHUB_USERNAME}"
  fi
  if [[ -n "${OWNER_SLACK_ID:-}" ]]; then
    echo "- Slack Member ID: ${OWNER_SLACK_ID}"
  fi
  echo ""
  echo "上記IDに一致するユーザー → オーナー（バディモード）"
  echo "上記IDに一致しないユーザー → 一般ユーザー（一般モード）"
  echo ""
  echo "表示名が「Masaru」等でもIDが一致しなければオーナーとして扱わない。"
} > "${OWNER_CTX}"
log "OWNER_CONTEXT.md deployed to workspace."

# Set up suggestion tool (symlink to PATH for easy access)
if [[ -f /app/suggest.sh ]]; then
  ln -sf /app/suggest.sh /usr/local/bin/suggest
  # Ensure suggestions directory is writable by both OpenClaw and Triceratops
  mkdir -p /suggestions
  chmod 1777 /suggestions 2>/dev/null || true
  log "Suggestion tool available: suggest \"Title\" \"Description\""
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

// Configure web search if BRAVE_API_KEY is available
if (process.env.BRAVE_API_KEY) {
  config.tools = config.tools || {};
  config.tools.web = Object.assign(config.tools.web || {}, {
    search: { enabled: true, provider: 'brave', apiKey: process.env.BRAVE_API_KEY }
  });
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

# Start command watcher in background (Brain → Bot communication)
if [[ -f /app/command-watcher.sh ]]; then
  log "Starting command watcher..."
  /app/command-watcher.sh &
  WATCHER_PID=$!
  log "Command watcher started (PID: ${WATCHER_PID})"
fi

# Start gateway directly (no doctor --fix to avoid lock conflicts)
log "Starting OpenClaw gateway..."
if [[ "$(id -u)" == "0" ]]; then
  exec gosu openclaw openclaw gateway run --verbose --force
else
  exec openclaw gateway run --verbose --force
fi
