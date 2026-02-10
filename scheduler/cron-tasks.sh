#!/usr/bin/env bash
set -euo pipefail

SHARED_DIR="/shared"
ACTION="${1:-}"

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local msg="[${timestamp}] [scheduler] $*"
  echo "${msg}"
  local log_dir="${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)"
  mkdir -p "${log_dir}"
  echo "${msg}" >> "${log_dir}/scheduler.log"
}

trigger_evaluation() {
  local cycle_id
  cycle_id="eval_$(date -u +%Y%m%d_%H%M%S)"
  local eval_dir="${SHARED_DIR}/evaluations/${cycle_id}"

  mkdir -p "${eval_dir}"

  cat > "${eval_dir}/request.json" <<EOF
{
  "cycle_id": "${cycle_id}",
  "type": "periodic_evaluation",
  "status": "pending",
  "triggered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "triggered_by": "scheduler"
}
EOF

  log "Evaluation cycle triggered: ${cycle_id}"
}

cleanup_old_logs() {
  local log_dir="${SHARED_DIR}/logs"
  # Keep logs for 30 days
  find "${log_dir}" -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true
  log "Old logs cleaned up"
}

healthcheck() {
  local now
  now=$(date +%s)
  local alert_count=0

  # --- 1. ノードのアクティビティ確認 ---
  for node in panda gorilla triceratops; do
    local activity_file="${SHARED_DIR}/nodes/${node}/activity.json"
    [[ -f "${activity_file}" ]] || continue

    local status updated_at
    status=$(jq -r '.status' "${activity_file}")
    updated_at=$(jq -r '.updated_at' "${activity_file}")

    [[ "${status}" == "idle" ]] && continue

    local updated_epoch
    updated_epoch=$(date -d "${updated_at}" +%s 2>/dev/null || echo 0)
    local age=$(( now - updated_epoch ))

    # 非idle状態で5分以上更新なし → スタックの可能性
    if [[ ${age} -gt 300 ]]; then
      log "ALERT: ${node} stuck in '${status}' for ${age}s (updated_at: ${updated_at})"
      ((alert_count++))
    fi
  done

  # --- 2. 議論の進行確認 ---
  for status_file in "${SHARED_DIR}"/discussions/*/status.json; do
    [[ -f "${status_file}" ]] || continue
    local disc_status task_id current_round
    disc_status=$(jq -r '.status' "${status_file}")
    [[ "${disc_status}" == "discussing" ]] || continue

    task_id=$(jq -r '.task_id' "${status_file}")
    current_round=$(jq -r '.current_round' "${status_file}")
    local disc_dir
    disc_dir=$(dirname "${status_file}")
    local round_dir="${disc_dir}/round_${current_round}"

    # 全ノード応答済みかチェック
    local responded=0
    for node in panda gorilla triceratops; do
      [[ -f "${round_dir}/${node}.json" ]] && ((responded++))
    done

    if [[ ${responded} -eq 3 ]]; then
      # 全員応答済みなのにまだ discussing → コンセンサスチェックが走っていない
      local latest=0
      for node in panda gorilla triceratops; do
        local ts
        ts=$(jq -r '.timestamp' "${round_dir}/${node}.json" 2>/dev/null)
        local ep
        ep=$(date -d "${ts}" +%s 2>/dev/null || echo 0)
        [[ ${ep} -gt ${latest} ]] && latest=${ep}
      done
      local stale=$(( now - latest ))
      if [[ ${stale} -gt 180 ]]; then
        log "ALERT: Discussion ${task_id} round ${current_round} - all nodes responded ${stale}s ago but still discussing"
        ((alert_count++))
      fi
    fi
  done

  # --- 3. Decision ステータス確認 ---
  for decision_file in "${SHARED_DIR}"/decisions/*.json; do
    [[ -f "${decision_file}" ]] || continue
    [[ "${decision_file}" != *_result.json ]] || continue
    [[ "${decision_file}" != *_history.json ]] || continue
    [[ "${decision_file}" != *_progress.jsonl ]] || continue
    [[ "${decision_file}" != *_announce_progress.jsonl ]] || continue

    local dec_status decided_at task_id
    dec_status=$(jq -r '.status' "${decision_file}")
    task_id=$(jq -r '.task_id' "${decision_file}")

    # Announcing スタック検出 (5分以上)
    if [[ "${dec_status}" == "announcing" ]]; then
      decided_at=$(jq -r '.decided_at' "${decision_file}")
      local dec_epoch
      dec_epoch=$(date -d "${decided_at}" +%s 2>/dev/null || echo 0)
      local age=$(( now - dec_epoch ))
      if [[ ${age} -gt 300 ]]; then
        log "ALERT: ${task_id} stuck in 'announcing' for ${age}s - resetting to pending_announcement"
        local tmp
        tmp=$(mktemp)
        jq '.status = "pending_announcement"' "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
        ((alert_count++))
      fi
    fi

    # Executing スタック検出 (30分以上)
    if [[ "${dec_status}" == "executing" ]]; then
      local exec_start
      exec_start=$(jq -r '.execution_started_at // .decided_at' "${decision_file}")
      local exec_epoch
      exec_epoch=$(date -d "${exec_start}" +%s 2>/dev/null || echo 0)
      local age=$(( now - exec_epoch ))
      if [[ ${age} -gt 1800 ]]; then
        log "ALERT: ${task_id} stuck in 'executing' for ${age}s"
        ((alert_count++))
      fi
    fi
  done

  # --- 4. ヘルスステータスファイル書き出し ---
  local health_file="${SHARED_DIR}/health.json"
  cat > "${health_file}" <<EOF
{
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "alerts": ${alert_count},
  "status": "$([ ${alert_count} -eq 0 ] && echo 'healthy' || echo 'warning')"
}
EOF

  if [[ ${alert_count} -gt 0 ]]; then
    log "Health check: ${alert_count} alert(s) detected"
  fi
}

case "${ACTION}" in
  evaluation)
    trigger_evaluation
    ;;
  cleanup)
    cleanup_old_logs
    ;;
  healthcheck)
    healthcheck
    ;;
  *)
    log "Unknown action: ${ACTION}. Usage: cron-tasks.sh [evaluation|cleanup|healthcheck]"
    exit 1
    ;;
esac
