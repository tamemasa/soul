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
  if [[ -f "${BRAIN_DIR}/params.json" ]]; then
    export RISK_TOLERANCE=$(jq -r '.risk_tolerance // 0.5' "${BRAIN_DIR}/params.json")
    export INNOVATION_WEIGHT=$(jq -r '.innovation_weight // 0.5' "${BRAIN_DIR}/params.json")
    export SAFETY_WEIGHT=$(jq -r '.safety_weight // 0.5' "${BRAIN_DIR}/params.json")
    export THOROUGHNESS=$(jq -r '.thoroughness // 0.5' "${BRAIN_DIR}/params.json")
    export CONSENSUS_FLEXIBILITY=$(jq -r '.consensus_flexibility // 0.5' "${BRAIN_DIR}/params.json")
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

  claude -p "${full_prompt}" --output-format text 2>>"${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)/${NODE_NAME}_claude.log" || {
    log "ERROR: Claude invocation failed"
    echo '{"error": "claude invocation failed"}'
  }
}

ensure_dirs() {
  mkdir -p "${SHARED_DIR}/inbox"
  mkdir -p "${SHARED_DIR}/discussions"
  mkdir -p "${SHARED_DIR}/decisions"
  mkdir -p "${SHARED_DIR}/evaluations"
  mkdir -p "${SHARED_DIR}/logs"
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

    # 5. Check for decisions that need execution
    check_pending_decisions || log "WARN: check_pending_decisions error"

    sleep "${POLL_INTERVAL}"
  done
}

main_loop
