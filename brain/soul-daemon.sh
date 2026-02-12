#!/usr/bin/env bash
set -uo pipefail

NODE_NAME="${NODE_NAME:?NODE_NAME is required}"
SHARED_DIR="/shared"
BRAIN_DIR="/brain"
POLL_INTERVAL=10

source "${BRAIN_DIR}/lib/watcher.sh"
source "${BRAIN_DIR}/lib/discussion.sh"
source "${BRAIN_DIR}/lib/evaluation.sh"
source "${BRAIN_DIR}/lib/consensus.sh"
source "${BRAIN_DIR}/lib/worker-manager.sh"
source "${BRAIN_DIR}/lib/rebuild-manager.sh"
source "${BRAIN_DIR}/lib/proactive-suggestions.sh"
source "${BRAIN_DIR}/lib/unified-openclaw-monitor.sh"

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local msg="[${timestamp}] [${NODE_NAME}] $*"
  echo "${msg}"
  local log_dir="${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)"
  mkdir -p "${log_dir}"
  echo "${msg}" >> "${log_dir}/${NODE_NAME}.log"
}

load_params() {
  local params_file="${SHARED_DIR}/nodes/${NODE_NAME}/params.json"
  if [[ -f "${params_file}" ]]; then
    export RISK_TOLERANCE=$(jq -r '.risk_tolerance // 0.5' "${params_file}")
    export INNOVATION_WEIGHT=$(jq -r '.innovation_weight // 0.5' "${params_file}")
    export SAFETY_WEIGHT=$(jq -r '.safety_weight // 0.5' "${params_file}")
    export THOROUGHNESS=$(jq -r '.thoroughness // 0.5' "${params_file}")
    export CONSENSUS_FLEXIBILITY=$(jq -r '.consensus_flexibility // 0.5' "${params_file}")
    log "Params loaded: risk=${RISK_TOLERANCE} innovation=${INNOVATION_WEIGHT} safety=${SAFETY_WEIGHT}"
  fi
}

invoke_claude() {
  local prompt="$1"
  local context_file="${2:-}"
  local full_prompt="${prompt}"

  if [[ -n "${context_file}" && -f "${context_file}" ]]; then
    full_prompt="${prompt}

--- Context ---
$(cat "${context_file}")"
  fi

  local log_file="${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)/${NODE_NAME}_claude.log"
  local result
  local exit_code

  # First attempt
  result=$(claude -p "${full_prompt}" ${CLAUDE_MODEL:+--model "${CLAUDE_MODEL}"} --permission-mode bypassPermissions --output-format text 2>>"${log_file}")
  exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    log "WARN: Claude invocation failed (exit=${exit_code}), retrying in 5s..."
    sleep 5
    # Retry once
    result=$(claude -p "${full_prompt}" ${CLAUDE_MODEL:+--model "${CLAUDE_MODEL}"} --permission-mode bypassPermissions --output-format text 2>>"${log_file}")
    exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
      log "ERROR: Claude invocation failed after retry (exit=${exit_code})"
      echo '{"error": "claude invocation failed"}'
      return 1
    fi
  fi

  echo "${result}"
}

set_activity() {
  local status="$1"
  local detail="${2:-}"
  local activity_file="${SHARED_DIR}/nodes/${NODE_NAME}/activity.json"
  mkdir -p "$(dirname "${activity_file}")"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ "${status}" == "idle" ]]; then
    echo "{\"status\":\"idle\",\"updated_at\":\"${ts}\"}" > "${activity_file}"
  else
    echo "{\"status\":\"${status}\",${detail}\"updated_at\":\"${ts}\"}" > "${activity_file}"
  fi
}

ensure_dirs() {
  mkdir -p "${SHARED_DIR}/inbox"
  mkdir -p "${SHARED_DIR}/discussions"
  mkdir -p "${SHARED_DIR}/decisions"
  mkdir -p "${SHARED_DIR}/evaluations"
  mkdir -p "${SHARED_DIR}/logs"
  mkdir -p "${SHARED_DIR}/nodes/${NODE_NAME}"
  mkdir -p "${SHARED_DIR}/rebuild_requests"
  set_activity "idle"
}

main_loop() {
  log "Soul daemon starting for node: ${NODE_NAME}"
  load_params
  ensure_dirs

  log "Entering main loop (poll interval: ${POLL_INTERVAL}s)"

  while true; do
    # 1. Check for new tasks in inbox
    check_inbox || log "WARN: check_inbox error"

    # 2. Check for discussions that need our response
    check_pending_discussions || log "WARN: check_pending_discussions error"

    # 3. Check for rounds that are complete and need consensus check
    check_consensus_needed || log "WARN: check_consensus_needed error"

    # 4. Check for evaluation requests
    check_evaluation_requests || log "WARN: check_evaluation_requests error"

    # 5. Check for decisions pending announcement (triceratops only)
    check_pending_announcements || log "WARN: check_pending_announcements error"

    # 6. Check for announced decisions that need execution (triceratops)
    check_pending_decisions || log "WARN: check_pending_decisions error"

    # 7. Check for rebuild approvals (gorilla) and execution (panda)
    check_rebuild_approvals || log "WARN: check_rebuild_approvals error"
    check_rebuild_requests || log "WARN: check_rebuild_requests error"

    # 8. Pick up OpenClaw suggestions (triceratops only)
    check_openclaw_suggestions || log "WARN: check_openclaw_suggestions error"

    # 9. Proactive suggestion engine (triceratops only, self-throttled to 60s)
    check_proactive_suggestions || log "WARN: check_proactive_suggestions error"

    # 10. Unified OpenClaw monitor (panda only, self-throttled to 5min)
    # Consolidates policy, security, and integrity checks into a single monitor.
    check_unified_openclaw_monitor || log "WARN: check_unified_openclaw_monitor error"
    process_unified_approved_actions || log "WARN: process_unified_approved_actions error"

    sleep "${POLL_INTERVAL}"
  done
}

main_loop
