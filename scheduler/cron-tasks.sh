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

    # Executing スタック検出 + 自動復旧 (30分以上)
    if [[ "${dec_status}" == "executing" ]]; then
      local exec_start executor
      exec_start=$(jq -r '.execution_started_at // .decided_at' "${decision_file}")
      executor=$(jq -r '.executor // "triceratops"' "${decision_file}")
      local exec_epoch
      exec_epoch=$(date -d "${exec_start}" +%s 2>/dev/null || echo 0)
      local age=$(( now - exec_epoch ))

      if [[ ${age} -gt 1800 ]]; then
        local container_name="soul-brain-${executor}"
        local container_running
        container_running=$(docker ps --filter "name=^/${container_name}$" --filter "status=running" --format '{{.Names}}' 2>/dev/null || true)

        if [[ -z "${container_running}" ]]; then
          # Executor container is dead - restart it
          log "WATCHDOG: ${container_name} is dead, task ${task_id} stuck for ${age}s. Restarting."
          if docker compose -f /soul/docker-compose.yml up -d "brain-${executor}" 2>/dev/null; then
            log "WATCHDOG: ${container_name} restart initiated via compose"
          elif docker start "${container_name}" 2>/dev/null; then
            log "WATCHDOG: ${container_name} started via docker start"
          else
            log "WATCHDOG: Failed to restart ${container_name}"
          fi
          ((alert_count++))
        elif [[ ${age} -gt 7200 ]]; then
          # Container alive but task stuck >2h - mark as failed
          log "WATCHDOG: ${task_id} stuck for ${age}s (>2h), container alive. Marking as failed."
          local tmp
          tmp=$(mktemp)
          jq '.status = "failed" | .failed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .failure_reason = "watchdog timeout (>2h, container alive)"' \
            "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
          ((alert_count++))
        else
          log "ALERT: ${task_id} executing for ${age}s, ${container_name} is running"
          ((alert_count++))
        fi
      fi
    fi
  done

  # --- 3.5 コンテナヘルス確認 ---
  for node in panda gorilla triceratops; do
    local container_name="soul-brain-${node}"
    local health_status
    health_status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${container_name}" 2>/dev/null || echo "not-found")

    if [[ "${health_status}" == "unhealthy" ]]; then
      log "WATCHDOG: ${container_name} is unhealthy, restarting"
      docker restart "${container_name}" 2>/dev/null \
        || log "WATCHDOG: Failed to restart unhealthy ${container_name}"
      ((alert_count++))
    elif [[ "${health_status}" == "not-found" ]]; then
      local container_exists
      container_exists=$(docker ps -a --filter "name=^/${container_name}$" --format '{{.Names}}' 2>/dev/null || true)
      if [[ -z "${container_exists}" ]]; then
        log "WATCHDOG: ${container_name} does not exist, creating"
        docker compose -f /soul/docker-compose.yml up -d "brain-${node}" 2>/dev/null \
          || log "WATCHDOG: Failed to create ${container_name}"
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

trigger_personality_improvement() {
  local pi_dir="${SHARED_DIR}/personality_improvement"
  mkdir -p "${pi_dir}"

  local trigger_file="${pi_dir}/trigger.json"

  # 連続トリガー防止: 最終実行から6時間以内は無視
  if [[ -f "${trigger_file}" ]]; then
    local last_triggered
    last_triggered=$(jq -r '.triggered_at // ""' "${trigger_file}" 2>/dev/null)
    if [[ -n "${last_triggered}" ]]; then
      local last_epoch
      last_epoch=$(date -d "${last_triggered}" +%s 2>/dev/null || echo 0)
      local now_epoch
      now_epoch=$(date +%s)
      if (( now_epoch - last_epoch < 21600 )); then
        log "Personality improvement: skipped (last trigger was ${last_triggered}, within 6h cooldown)"
        return 0
      fi
    fi
  fi

  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg src "scheduler" \
    '{
      type: "personality_improvement",
      status: "pending",
      triggered_at: $ts,
      triggered_by: $src
    }' > "${tmp}" && mv "${tmp}" "${trigger_file}"

  log "Personality improvement trigger created"
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
  personality_improvement)
    trigger_personality_improvement
    ;;
  *)
    log "Unknown action: ${ACTION}. Usage: cron-tasks.sh [evaluation|cleanup|healthcheck|personality_improvement]"
    exit 1
    ;;
esac
