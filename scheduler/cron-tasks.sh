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

_notify_stuck() {
  local task_id="$1" status="$2" since="$3" duration="$4" source_file="$5" action="$6"
  local stuck_dir="${SHARED_DIR}/stuck_tasks"
  local stuck_file="${stuck_dir}/${task_id}.json"

  # 既に通知済みなら再通知しない
  [[ -f "${stuck_file}" ]] && return 0

  mkdir -p "${stuck_dir}"
  local tmp
  tmp=$(mktemp)
  cat > "${tmp}" <<STUCK_EOF
{
  "task_id": "${task_id}",
  "current_status": "${status}",
  "stuck_since": "${since}",
  "stuck_duration_seconds": ${duration},
  "detected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_file": "${source_file}",
  "recommended_action": "${action}"
}
STUCK_EOF
  mv "${tmp}" "${stuck_file}"
  log "STUCK: ${task_id} stuck in '${status}' for ${duration}s → ${action}"
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

archive_completed_tasks() {
  /scheduler/archive-tasks.sh 0
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

    # Discussing > 2h (全体経過時間) → brain にエスカレート
    local started_at
    started_at=$(jq -r '.started_at // ""' "${status_file}" 2>/dev/null)
    if [[ -n "${started_at}" && "${started_at}" != "null" ]]; then
      local start_epoch
      start_epoch=$(date -d "${started_at}" +%s 2>/dev/null || echo 0)
      local total_age=$(( now - start_epoch ))
      if [[ ${total_age} -gt 7200 ]]; then
        _notify_stuck "${task_id}" "discussing" "${started_at}" "${total_age}" "${status_file}" "escalate_discussion"
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

    # --- 3.1 reviewing/remediating/announced/pending_announcement スタック検出 ---

    # Reviewing > 10min
    if [[ "${dec_status}" == "reviewing" ]]; then
      local review_since
      review_since=$(jq -r '.executed_at // .decided_at' "${decision_file}")
      local review_epoch
      review_epoch=$(date -d "${review_since}" +%s 2>/dev/null || echo 0)
      local age=$(( now - review_epoch ))
      if [[ ${age} -gt 600 ]]; then
        _notify_stuck "${task_id}" "reviewing" "${review_since}" "${age}" "${decision_file}" "retry_review"
        ((alert_count++))
      fi
    fi

    # Remediating > 30min
    if [[ "${dec_status}" == "remediating" ]]; then
      local remediate_since
      remediate_since=$(jq -r '.review_completed_at // .executed_at // .decided_at' "${decision_file}")
      local remediate_epoch
      remediate_epoch=$(date -d "${remediate_since}" +%s 2>/dev/null || echo 0)
      local age=$(( now - remediate_epoch ))
      if [[ ${age} -gt 1800 ]]; then
        _notify_stuck "${task_id}" "remediating" "${remediate_since}" "${age}" "${decision_file}" "retry_remediation"
        ((alert_count++))
      fi
    fi

    # pending_announcement > 5min
    if [[ "${dec_status}" == "pending_announcement" ]]; then
      decided_at=$(jq -r '.decided_at' "${decision_file}")
      local pa_epoch
      pa_epoch=$(date -d "${decided_at}" +%s 2>/dev/null || echo 0)
      local age=$(( now - pa_epoch ))
      if [[ ${age} -gt 300 ]]; then
        _notify_stuck "${task_id}" "pending_announcement" "${decided_at}" "${age}" "${decision_file}" "retry_announcement"
        ((alert_count++))
      fi
    fi

    # announced > 5min
    if [[ "${dec_status}" == "announced" ]]; then
      local announced_at
      announced_at=$(jq -r '.announcement.announced_at // .decided_at' "${decision_file}")
      local announced_epoch
      announced_epoch=$(date -d "${announced_at}" +%s 2>/dev/null || echo 0)
      local age=$(( now - announced_epoch ))
      if [[ ${age} -gt 300 ]]; then
        _notify_stuck "${task_id}" "announced" "${announced_at}" "${age}" "${decision_file}" "retry_execution"
        ((alert_count++))
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
  local trigger_file="${pi_dir}/trigger.json"

  mkdir -p "${pi_dir}"

  # Check if a trigger is already active (pending/questions_sent/answers_received/processing)
  if [[ -f "${trigger_file}" ]]; then
    local current_status
    current_status=$(jq -r '.status // ""' "${trigger_file}" 2>/dev/null)
    case "${current_status}" in
      pending|questions_sent|answers_received|processing)
        log "Personality improvement: Skipping scheduled trigger - already in progress (status: ${current_status})"
        return 0
        ;;
    esac
  fi

  # Check cooldown (6 hours since last trigger)
  if [[ -f "${trigger_file}" ]]; then
    local last_triggered
    last_triggered=$(jq -r '.triggered_at // ""' "${trigger_file}" 2>/dev/null)
    if [[ -n "${last_triggered}" ]]; then
      local last_epoch now_epoch
      last_epoch=$(date -d "${last_triggered}" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      if (( now_epoch - last_epoch < 21600 )); then
        log "Personality improvement: Skipping scheduled trigger - within 6h cooldown"
        return 0
      fi
    fi
  fi

  # Create the trigger
  local tmp
  tmp=$(mktemp)
  cat > "${tmp}" <<EOF
{
  "type": "personality_improvement",
  "status": "pending",
  "triggered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "triggered_by": "scheduler_daily_1230"
}
EOF
  mv "${tmp}" "${trigger_file}"

  log "Personality improvement: Daily 12:30 trigger created"
}

cleanup_archive_dirs() {
  local archive_dir="${SHARED_DIR}/archive"
  local cutoff_epoch
  cutoff_epoch=$(date -d "90 days ago" +%s)
  local deleted=0

  # 1. Monthly dirs (YYYY-MM) older than 90 days
  if [[ -d "${archive_dir}" ]]; then
    for month_dir in "${archive_dir}"/????-??; do
      [[ -d "${month_dir}" ]] || continue
      local dir_name
      dir_name=$(basename "${month_dir}")
      local last_day_epoch
      last_day_epoch=$(date -d "${dir_name}-01 +1 month -1 day" +%s 2>/dev/null) || continue
      if [[ ${last_day_epoch} -lt ${cutoff_epoch} ]]; then
        local count
        count=$(find "${month_dir}" -maxdepth 1 -mindepth 1 -type d | wc -l)
        rm -rf "${month_dir}"
        deleted=$((deleted + count))
        log "[CLEANUP] archive monthly dir removed: ${dir_name} (${count} tasks)"
      fi
    done
  fi

  # 2. Evaluation archives (YYYY-MM monthly dirs under evaluations/)
  local eval_archive="${archive_dir}/evaluations"
  if [[ -d "${eval_archive}" ]]; then
    for month_dir in "${eval_archive}"/????-??; do
      [[ -d "${month_dir}" ]] || continue
      local dir_name
      dir_name=$(basename "${month_dir}")
      local last_day_epoch
      last_day_epoch=$(date -d "${dir_name}-01 +1 month -1 day" +%s 2>/dev/null) || continue
      if [[ ${last_day_epoch} -lt ${cutoff_epoch} ]]; then
        local count
        count=$(find "${month_dir}" -maxdepth 1 -mindepth 1 | wc -l)
        rm -rf "${month_dir}"
        deleted=$((deleted + count))
        log "[CLEANUP] archive/evaluations monthly dir removed: ${dir_name} (${count} entries)"
      fi
    done
  fi

  # 3. Trim index.jsonl (remove entries older than 90 days)
  local index_file="${archive_dir}/index.jsonl"
  if [[ -f "${index_file}" ]]; then
    local before_count
    before_count=$(wc -l < "${index_file}")
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      local archived_at
      archived_at=$(echo "${line}" | jq -r '.archived_at // ""' 2>/dev/null)
      if [[ -z "${archived_at}" ]]; then
        echo "${line}" >> "${tmp}"
        continue
      fi
      local entry_epoch
      entry_epoch=$(date -d "${archived_at}" +%s 2>/dev/null || echo 0)
      if [[ ${entry_epoch} -ge ${cutoff_epoch} ]]; then
        echo "${line}" >> "${tmp}"
      fi
    done < "${index_file}"
    mv "${tmp}" "${index_file}"
    local after_count
    after_count=$(wc -l < "${index_file}")
    local trimmed=$((before_count - after_count))
    if [[ ${trimmed} -gt 0 ]]; then
      log "[CLEANUP] archive/index.jsonl trimmed: ${trimmed} entries removed (${before_count} -> ${after_count})"
    fi
  fi

  log "[CLEANUP] cleanup_archive_dirs completed: ${deleted} items removed"
}

cleanup_subdirectory_archives() {
  local deleted=0

  # alerts/archive: 30 days
  local dir="${SHARED_DIR}/alerts/archive"
  if [[ -d "${dir}" ]]; then
    local count
    count=$(find "${dir}" -maxdepth 1 -type f -name "*.json" -mtime +30 | wc -l)
    find "${dir}" -maxdepth 1 -type f -name "*.json" -mtime +30 -delete
    if [[ ${count} -gt 0 ]]; then
      log "[CLEANUP] alerts/archive: ${count} files deleted (>30 days)"
      deleted=$((deleted + count))
    fi
  fi

  # rebuild_requests/archive: 7 days
  dir="${SHARED_DIR}/rebuild_requests/archive"
  if [[ -d "${dir}" ]]; then
    local count
    count=$(find "${dir}" -maxdepth 1 -type f -name "*.json" -mtime +7 | wc -l)
    find "${dir}" -maxdepth 1 -type f -name "*.json" -mtime +7 -delete
    if [[ ${count} -gt 0 ]]; then
      log "[CLEANUP] rebuild_requests/archive: ${count} files deleted (>7 days)"
      deleted=$((deleted + count))
    fi
  fi

  # personality_improvement/archive: 30 days
  dir="${SHARED_DIR}/personality_improvement/archive"
  if [[ -d "${dir}" ]]; then
    local count
    count=$(find "${dir}" -maxdepth 1 -type f -name "*.json" -mtime +30 | wc -l)
    find "${dir}" -maxdepth 1 -type f -name "*.json" -mtime +30 -delete
    if [[ ${count} -gt 0 ]]; then
      log "[CLEANUP] personality_improvement/archive: ${count} files deleted (>30 days)"
      deleted=$((deleted + count))
    fi
  fi

  # workspace/archive: 30 days
  dir="${SHARED_DIR}/workspace/archive"
  if [[ -d "${dir}" ]]; then
    local count
    count=$(find "${dir}" -maxdepth 1 -type f -mtime +30 | wc -l)
    find "${dir}" -maxdepth 1 -type f -mtime +30 -delete
    if [[ ${count} -gt 0 ]]; then
      log "[CLEANUP] workspace/archive: ${count} files deleted (>30 days)"
      deleted=$((deleted + count))
    fi
  fi

  # monitoring/reports: 90 days
  dir="${SHARED_DIR}/monitoring/reports"
  if [[ -d "${dir}" ]]; then
    local count
    count=$(find "${dir}" -maxdepth 1 -type f -name "*.json" -mtime +90 | wc -l)
    find "${dir}" -maxdepth 1 -type f -name "*.json" -mtime +90 -delete
    if [[ ${count} -gt 0 ]]; then
      log "[CLEANUP] monitoring/reports: ${count} files deleted (>90 days)"
      deleted=$((deleted + count))
    fi
  fi

  log "[CLEANUP] cleanup_subdirectory_archives completed: ${deleted} items removed"
}

rotate_jsonl_files() {
  local max_lines=1000
  local rotated=0

  # token_usage.jsonl
  local file="${SHARED_DIR}/host_metrics/token_usage.jsonl"
  if [[ -f "${file}" ]]; then
    local lines
    lines=$(wc -l < "${file}")
    if [[ ${lines} -gt ${max_lines} ]]; then
      local tmp
      tmp=$(mktemp)
      tail -n "${max_lines}" "${file}" > "${tmp}" && mv "${tmp}" "${file}"
      log "[CLEANUP] token_usage.jsonl rotated: ${lines} -> ${max_lines} lines"
      ((rotated++))
    fi
  fi

  # monitoring/alerts.jsonl
  file="${SHARED_DIR}/monitoring/alerts.jsonl"
  if [[ -f "${file}" ]]; then
    local lines
    lines=$(wc -l < "${file}")
    if [[ ${lines} -gt ${max_lines} ]]; then
      local tmp
      tmp=$(mktemp)
      tail -n "${max_lines}" "${file}" > "${tmp}" && mv "${tmp}" "${file}"
      log "[CLEANUP] monitoring/alerts.jsonl rotated: ${lines} -> ${max_lines} lines"
      ((rotated++))
    fi
  fi

  log "[CLEANUP] rotate_jsonl_files completed: ${rotated} files rotated"
}

case "${ACTION}" in
  evaluation)
    trigger_evaluation
    ;;
  cleanup)
    cleanup_old_logs
    archive_completed_tasks
    cleanup_archive_dirs
    cleanup_subdirectory_archives
    rotate_jsonl_files
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
