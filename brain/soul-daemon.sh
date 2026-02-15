#!/usr/bin/env bash
set -uo pipefail

# Disable core dumps (vendored ripgrep jemalloc crashes on ARM64 16KB page size)
ulimit -c 0 2>/dev/null || true

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
source "${BRAIN_DIR}/lib/personality-improvement.sh"

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local msg="[${timestamp}] [${NODE_NAME}] $*"
  echo "${msg}" >&2
  local log_dir="${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)"
  mkdir -p "${log_dir}"
  echo "${msg}" >> "${log_dir}/${NODE_NAME}.log"
}

load_params() {
  local params_file="${SHARED_DIR}/nodes/${NODE_NAME}/params.json"
  if [[ -f "${params_file}" ]]; then
    local params_data
    params_data=$(jq -r '[(.risk_tolerance // 0.5), (.innovation_weight // 0.5), (.safety_weight // 0.5), (.thoroughness // 0.5), (.consensus_flexibility // 0.5)] | @tsv' "${params_file}" 2>/dev/null) || return 0
    export RISK_TOLERANCE=$(echo "${params_data}" | cut -f1)
    export INNOVATION_WEIGHT=$(echo "${params_data}" | cut -f2)
    export SAFETY_WEIGHT=$(echo "${params_data}" | cut -f3)
    export THOROUGHNESS=$(echo "${params_data}" | cut -f4)
    export CONSENSUS_FLEXIBILITY=$(echo "${params_data}" | cut -f5)
    log "Params loaded: risk=${RISK_TOLERANCE} innovation=${INNOVATION_WEIGHT} safety=${SAFETY_WEIGHT}"
  fi
}

record_token_usage() {
  local json_file="$1"
  local task_id="${2:-}"
  local call_type="${3:-invoke}"

  if [[ ! -s "${json_file}" ]]; then
    return 0
  fi

  local usage_dir="${SHARED_DIR}/host_metrics"
  mkdir -p "${usage_dir}"
  local usage_file="${usage_dir}/token_usage.jsonl"

  local ts model input_tokens output_tokens cache_read cache_create cost_usd
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  model=$(jq -r '.modelUsage // {} | keys[0] // "unknown"' "${json_file}" 2>/dev/null || echo "unknown")
  input_tokens=$(jq -r '.usage.input_tokens // 0' "${json_file}" 2>/dev/null || echo 0)
  output_tokens=$(jq -r '.usage.output_tokens // 0' "${json_file}" 2>/dev/null || echo 0)
  cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' "${json_file}" 2>/dev/null || echo 0)
  cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' "${json_file}" 2>/dev/null || echo 0)
  cost_usd=$(jq -r '.total_cost_usd // 0' "${json_file}" 2>/dev/null || echo 0)

  local line
  line=$(jq -cn \
    --arg ts "${ts}" \
    --arg node "${NODE_NAME}" \
    --arg task_id "${task_id}" \
    --arg model "${model}" \
    --argjson input "${input_tokens}" \
    --argjson output "${output_tokens}" \
    --argjson cache_read "${cache_read}" \
    --argjson cache_create "${cache_create}" \
    --argjson cost "${cost_usd}" \
    --arg call_type "${call_type}" \
    '{timestamp:$ts, node:$node, task_id:$task_id, model:$model, input_tokens:$input, output_tokens:$output, cache_read_input_tokens:$cache_read, cache_creation_input_tokens:$cache_create, cost_usd:$cost, call_type:$call_type}' \
    2>/dev/null)

  if [[ -n "${line}" ]]; then
    echo "${line}" >> "${usage_file}" 2>/dev/null || log "WARN: Failed to write token usage"
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
  local tmp_json
  tmp_json=$(mktemp)
  local exit_code

  # First attempt - capture JSON output to temp file
  claude -p "${full_prompt}" ${CLAUDE_MODEL:+--model "${CLAUDE_MODEL}"} --permission-mode bypassPermissions --output-format json >"${tmp_json}" 2>/dev/null
  exit_code=$?

  # Append raw JSON to log file for record-keeping
  cat "${tmp_json}" >> "${log_file}" 2>/dev/null
  echo >> "${log_file}" 2>/dev/null

  if [[ ${exit_code} -ne 0 ]]; then
    log "WARN: Claude invocation failed (exit=${exit_code}), retrying in 5s..."
    rm -f "${tmp_json}"
    sleep 5
    tmp_json=$(mktemp)
    # Retry once
    claude -p "${full_prompt}" ${CLAUDE_MODEL:+--model "${CLAUDE_MODEL}"} --permission-mode bypassPermissions --output-format json >"${tmp_json}" 2>/dev/null
    exit_code=$?
    cat "${tmp_json}" >> "${log_file}" 2>/dev/null
    echo >> "${log_file}" 2>/dev/null
    if [[ ${exit_code} -ne 0 ]]; then
      log "ERROR: Claude invocation failed after retry (exit=${exit_code})"
      rm -f "${tmp_json}"
      echo '{"error": "claude invocation failed"}'
      return 1
    fi
  fi

  # Extract text result from JSON
  local result
  result=$(jq -r '.result // ""' "${tmp_json}" 2>/dev/null)
  if [[ -z "${result}" ]]; then
    # Fallback: try reading raw content
    result=$(cat "${tmp_json}" 2>/dev/null)
    log "WARN: Failed to extract .result from JSON, using raw output"
  fi

  # Record token usage (non-blocking, failures are logged but don't affect main flow)
  record_token_usage "${tmp_json}" "" "invoke" || true

  rm -f "${tmp_json}"
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
  mkdir -p "${SHARED_DIR}/personality_improvement/history"
  mkdir -p "${SHARED_DIR}/host_metrics"
  set_activity "idle"
}

recover_stalled_discussions() {
  # Only triceratops runs consensus evaluation
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  local discussions_dir="${SHARED_DIR}/discussions"
  local recovered=0

  for discussion_dir in "${discussions_dir}"/*/; do
    [[ -d "${discussion_dir}" ]] || continue

    local task_id
    task_id=$(basename "${discussion_dir}")
    local status_file="${discussion_dir}/status.json"
    [[ -f "${status_file}" ]] || continue

    local status_data
    status_data=$(jq -r '[.status, (.current_round | tostring)] | @tsv' "${status_file}" 2>/dev/null) || continue
    local status current_round
    status=$(echo "${status_data}" | cut -f1)
    current_round=$(echo "${status_data}" | cut -f2)

    [[ "${status}" == "discussing" ]] || continue

    local round_dir="${discussion_dir}/round_${current_round}"
    local response_count=0
    for node in "${ALL_NODES[@]}"; do
      [[ -f "${round_dir}/${node}.json" ]] && ((response_count++))
    done

    if [[ ${response_count} -eq ${#ALL_NODES[@]} ]]; then
      log "RECOVERY: Discussion ${task_id} round ${current_round} has all votes, running consensus"
      evaluate_consensus "${task_id}" "${current_round}"
      recovered=$((recovered + 1))
    fi
  done

  [[ ${recovered} -gt 0 ]] && log "RECOVERY: Processed ${recovered} stalled discussion(s)"
  return 0
}

recover_interrupted_tasks() {
  local decisions_dir="${SHARED_DIR}/decisions"
  local recovered=0

  for decision_file in "${decisions_dir}"/task_*[0-9].json; do
    [[ -f "${decision_file}" ]] || continue

    local data
    data=$(jq -r '[.status, .task_id, (.executor // "")] | @tsv' "${decision_file}" 2>/dev/null) || continue
    local status task_id executor
    status=$(echo "${data}" | cut -f1)
    task_id=$(echo "${data}" | cut -f2)
    executor=$(echo "${data}" | cut -f3)

    # このノードが担当で "executing" 状態のタスクのみ対象
    [[ "${status}" == "executing" ]] || continue
    [[ "${executor}" == "${NODE_NAME}" || -z "${executor}" ]] || continue

    local execution_started_at start_epoch current_epoch age_seconds
    execution_started_at=$(jq -r '.execution_started_at // ""' "${decision_file}" 2>/dev/null)
    if [[ -n "${execution_started_at}" ]]; then
      start_epoch=$(date -d "${execution_started_at}" +%s 2>/dev/null || echo 0)
      current_epoch=$(date +%s)
      age_seconds=$((current_epoch - start_epoch))
    else
      age_seconds=0
    fi

    if [[ ${age_seconds} -gt 7200 ]]; then
      # 2時間超 → 失敗としてマーク
      log "RECOVERY: Task ${task_id} timed out (${age_seconds}s >2h), marking as failed"
      local tmp
      tmp=$(mktemp)
      jq '.status = "failed" | .failed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .failure_reason = "execution interrupted by container restart, exceeded 2h timeout"' \
        "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
    else
      # 即座に再実行（execute_decisionがretry_count管理・continuation contextを処理）
      log "RECOVERY: Task ${task_id} was interrupted (${age_seconds}s elapsed), retrying now"
      execute_decision "${decision_file}"
      recovered=$((recovered + 1))
    fi
  done

  [[ ${recovered} -gt 0 ]] && log "RECOVERY: Recovered ${recovered} interrupted task(s)"
  return 0
}

main_loop() {
  log "Soul daemon starting for node: ${NODE_NAME}"
  load_params
  ensure_dirs

  recover_stalled_discussions  # 1. Consensus check first (short, unblocks stalled discussions)
  recover_interrupted_tasks    # 2. Task re-execution second (may block for 30min+)

  log "Entering main loop (poll interval: ${POLL_INTERVAL}s)"

  while true; do
    # 1. Check for new tasks in inbox
    check_inbox || log "WARN: check_inbox error"

    # 2+3. Unified: check pending discussions + consensus in single scan
    check_discussions_unified || log "WARN: check_discussions_unified error"

    # 4. Check for evaluation requests
    check_evaluation_requests || log "WARN: check_evaluation_requests error"

    # 5+6. Unified: check announcements + pending decisions in single scan
    check_decisions_unified || log "WARN: check_decisions_unified error"

    # 7. Check for rebuild approvals (gorilla) and execution (panda)
    check_rebuild_approvals || log "WARN: check_rebuild_approvals error"
    check_rebuild_requests || log "WARN: check_rebuild_requests error"

    # 8. Pick up OpenClaw suggestions and research requests (triceratops only)
    check_openclaw_suggestions || log "WARN: check_openclaw_suggestions error"
    check_openclaw_research_requests || log "WARN: check_openclaw_research_requests error"

    # 9. Proactive suggestion engine (triceratops only, self-throttled to 60s)
    check_proactive_suggestions || log "WARN: check_proactive_suggestions error"

    # 10. Unified OpenClaw monitor (panda only, self-throttled to 5min)
    # Consolidates policy, security, and integrity checks into a single monitor.
    check_unified_openclaw_monitor || log "WARN: check_unified_openclaw_monitor error"
    process_unified_approved_actions || log "WARN: process_unified_approved_actions error"

    # 11. Personality improvement engine (triceratops only)
    check_personality_improvement || log "WARN: check_personality_improvement error"
    check_personality_manual_trigger || log "WARN: check_personality_manual_trigger error"
    check_personality_rollback_trigger || log "WARN: check_personality_rollback_trigger error"
    check_personality_external_trigger || log "WARN: check_personality_external_trigger error"
    check_personality_freeform_trigger || log "WARN: check_personality_freeform_trigger error"

    sleep "${POLL_INTERVAL}"
  done
}

main_loop
