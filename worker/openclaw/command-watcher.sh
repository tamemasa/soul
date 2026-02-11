#!/usr/bin/env bash
# command-watcher.sh - Watches /bot_commands/ for instructions from Brain nodes
# Runs as a background process alongside the OpenClaw gateway
# Polls every 10 seconds for new command files

COMMANDS_DIR="/bot_commands"
POLL_INTERVAL=10

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [command-watcher] $*"
}

process_command() {
  local cmd_file="$1"
  [[ -f "${cmd_file}" ]] || return 0

  local status
  status=$(jq -r '.status // ""' "${cmd_file}" 2>/dev/null)
  [[ "${status}" == "pending" ]] || return 0

  local cmd_id action reason
  cmd_id=$(jq -r '.id // "unknown"' "${cmd_file}")
  action=$(jq -r '.action // ""' "${cmd_file}")
  reason=$(jq -r '.reason // ""' "${cmd_file}")

  log "Processing command: ${cmd_id} (action: ${action}, reason: ${reason})"

  local result="success"
  local result_detail=""

  case "${action}" in
    pause)
      local duration
      duration=$(jq -r '.params.duration_minutes // 5' "${cmd_file}")
      log "Pausing activity for ${duration} minutes"
      # Create a pause marker file that OpenClaw can check
      local pause_until
      pause_until=$(date -u -d "+${duration} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                    date -u +%Y-%m-%dT%H:%M:%SZ)
      echo "{\"paused_until\": \"${pause_until}\", \"reason\": \"${reason}\"}" > /tmp/openclaw-pause.json
      result_detail="Paused until ${pause_until}"
      ;;
    resume)
      log "Resuming activity"
      rm -f /tmp/openclaw-pause.json
      result_detail="Pause cleared"
      ;;
    adjust_params)
      local params
      params=$(jq -r '.params // {}' "${cmd_file}")
      log "Adjusting parameters: ${params}"
      # Store parameter adjustments for OpenClaw to pick up
      echo "${params}" > /tmp/openclaw-adjusted-params.json
      result_detail="Parameters adjusted"
      ;;
    restart)
      log "Restart requested - this will be handled by container orchestration"
      result="acknowledged"
      result_detail="Restart must be executed externally via docker"
      ;;
    *)
      log "Unknown action: ${action}"
      result="error"
      result_detail="Unknown action: ${action}"
      ;;
  esac

  # Mark command as processed
  local tmp
  tmp=$(mktemp)
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg st "processed" --arg ts "${ts}" --arg res "${result}" --arg det "${result_detail}" \
    '.status = $st | .processed_at = $ts | .result = $res | .result_detail = $det' \
    "${cmd_file}" > "${tmp}" && mv "${tmp}" "${cmd_file}"

  log "Command ${cmd_id} processed: ${result} - ${result_detail}"
}

main() {
  log "Command watcher starting (poll interval: ${POLL_INTERVAL}s)"
  mkdir -p "${COMMANDS_DIR}"

  while true; do
    for cmd_file in "${COMMANDS_DIR}"/*.json; do
      [[ -f "${cmd_file}" ]] || continue
      process_command "${cmd_file}"
    done

    # Clean up old processed commands (older than 1 hour)
    find "${COMMANDS_DIR}" -name "*.json" -mmin +60 -exec rm -f {} \; 2>/dev/null || true

    sleep "${POLL_INTERVAL}"
  done
}

main
