#!/usr/bin/env bash
set -euo pipefail

# Archive completed/failed/rejected tasks
# Moves discussion dirs and decision files to /shared/archive/YYYY-MM/task_id/
# Appends metadata to /shared/archive/index.jsonl

SHARED_DIR="/shared"
ARCHIVE_DIR="${SHARED_DIR}/archive"
INDEX_FILE="${ARCHIVE_DIR}/index.jsonl"
MIN_AGE_DAYS="${1:-7}"  # Default: archive tasks completed 7+ days ago

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local msg="[${timestamp}] [archive] $*"
  echo "${msg}"
  local log_dir="${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)"
  mkdir -p "${log_dir}"
  echo "${msg}" >> "${log_dir}/scheduler.log"
}

is_archivable() {
  local task_id="$1"
  local decision_file="${SHARED_DIR}/decisions/${task_id}.json"

  # Must have a decision file
  [[ -f "${decision_file}" ]] || return 1

  local status decision
  status=$(jq -r '.status // ""' "${decision_file}" 2>/dev/null)
  decision=$(jq -r '.decision // ""' "${decision_file}" 2>/dev/null)

  # Only archive completed, failed, or rejected tasks
  case "${status}" in
    completed|failed) ;;
    *)
      case "${decision}" in
        rejected) ;;
        *) return 1 ;;
      esac
      ;;
  esac

  # Check age - must be older than MIN_AGE_DAYS
  if [[ "${MIN_AGE_DAYS}" -gt 0 ]]; then
    local decided_at
    decided_at=$(jq -r '.decided_at // .created_at // ""' "${decision_file}" 2>/dev/null)
    if [[ -n "${decided_at}" ]]; then
      local decided_epoch now_epoch
      decided_epoch=$(date -d "${decided_at}" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      local age_days=$(( (now_epoch - decided_epoch) / 86400 ))
      if [[ ${age_days} -lt ${MIN_AGE_DAYS} ]]; then
        return 1
      fi
    fi
  fi

  return 0
}

archive_task() {
  local task_id="$1"
  local decision_file="${SHARED_DIR}/decisions/${task_id}.json"

  # Determine archive month from decision date
  local decided_at
  decided_at=$(jq -r '.decided_at // .created_at // ""' "${decision_file}" 2>/dev/null)
  local archive_month
  archive_month=$(date -d "${decided_at}" +%Y-%m 2>/dev/null || date -u +%Y-%m)

  local task_archive_dir="${ARCHIVE_DIR}/${archive_month}/${task_id}"
  mkdir -p "${task_archive_dir}"

  # Move discussion directory
  if [[ -d "${SHARED_DIR}/discussions/${task_id}" ]]; then
    mv "${SHARED_DIR}/discussions/${task_id}" "${task_archive_dir}/discussion"
    log "  Moved discussions/${task_id}/"
  fi

  # Move all decision-related files
  local moved_files=0
  for f in "${SHARED_DIR}/decisions/${task_id}"*.json "${SHARED_DIR}/decisions/${task_id}"*.jsonl; do
    [[ -f "$f" ]] || continue
    mv "$f" "${task_archive_dir}/"
    moved_files=$((moved_files + 1))
  done
  if [[ ${moved_files} -gt 0 ]]; then
    log "  Moved ${moved_files} decision file(s)"
  fi

  # Move inbox file if it still exists
  if [[ -f "${SHARED_DIR}/inbox/${task_id}.json" ]]; then
    mv "${SHARED_DIR}/inbox/${task_id}.json" "${task_archive_dir}/"
    log "  Moved inbox/${task_id}.json"
  fi

  # Build index entry
  local title status decision
  # Read title from task metadata (discussion/task.json), not decision file
  title=$(jq -r '.title // ""' "${task_archive_dir}/discussion/task.json" 2>/dev/null || echo "")
  if [[ -z "${title}" ]]; then
    # Fallback: try decision file (older format)
    title=$(jq -r '.title // ""' "${task_archive_dir}/${task_id}.json" 2>/dev/null || echo "")
  fi
  status=$(jq -r '.status // ""' "${task_archive_dir}/${task_id}.json" 2>/dev/null || echo "")
  decision=$(jq -r '.decision // ""' "${task_archive_dir}/${task_id}.json" 2>/dev/null || echo "")

  local index_entry
  index_entry=$(jq -nc \
    --arg id "${task_id}" \
    --arg title "${title}" \
    --arg status "${status}" \
    --arg decision "${decision}" \
    --arg decided_at "${decided_at}" \
    --arg archive_path "${archive_month}/${task_id}" \
    --arg archived_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task_id: $id, title: $title, status: $status, decision: $decision, decided_at: $decided_at, archive_path: $archive_path, archived_at: $archived_at}')

  echo "${index_entry}" >> "${INDEX_FILE}"
}

archive_evaluations() {
  local eval_dir="${SHARED_DIR}/evaluations"
  [[ -d "${eval_dir}" ]] || return 0

  local archived=0
  local now_epoch
  now_epoch=$(date +%s)

  for cycle_dir in "${eval_dir}"/*/; do
    [[ -d "${cycle_dir}" ]] || continue
    local cycle_id
    cycle_id=$(basename "${cycle_dir}")

    local should_archive=false
    local eval_status="unknown"

    if [[ -f "${cycle_dir}/result.json" ]]; then
      # Completed evaluation - archive immediately
      should_archive=true
      eval_status="completed"
    elif [[ -f "${cycle_dir}/request.json" ]]; then
      # No result - check if request is older than 7 days (stale/abandoned)
      local triggered_at
      triggered_at=$(jq -r '.triggered_at // ""' "${cycle_dir}/request.json" 2>/dev/null)
      if [[ -n "${triggered_at}" ]]; then
        local triggered_epoch
        triggered_epoch=$(date -d "${triggered_at}" +%s 2>/dev/null || echo 0)
        local age_days=$(( (now_epoch - triggered_epoch) / 86400 ))
        if [[ ${age_days} -ge 7 ]]; then
          should_archive=true
          eval_status="stale"
        fi
      fi
    fi

    if [[ "${should_archive}" == "true" ]]; then
      # Determine archive month from request timestamp
      local triggered_at
      triggered_at=$(jq -r '.triggered_at // ""' "${cycle_dir}/request.json" 2>/dev/null)
      local archive_month
      archive_month=$(date -d "${triggered_at}" +%Y-%m 2>/dev/null || date -u +%Y-%m)

      local eval_archive_dir="${ARCHIVE_DIR}/evaluations/${archive_month}/${cycle_id}"
      mkdir -p "${eval_archive_dir}"

      # Move all files from the cycle directory
      mv "${cycle_dir}"* "${eval_archive_dir}/" 2>/dev/null || true
      rmdir "${cycle_dir}" 2>/dev/null || true

      # Append to index
      local index_entry
      index_entry=$(jq -nc \
        --arg type "evaluation" \
        --arg cycle_id "${cycle_id}" \
        --arg status "${eval_status}" \
        --arg archive_path "evaluations/${archive_month}/${cycle_id}" \
        --arg archived_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{type: $type, cycle_id: $cycle_id, status: $status, archive_path: $archive_path, archived_at: $archived_at}')
      echo "${index_entry}" >> "${INDEX_FILE}"

      log "Archived evaluation: ${cycle_id} (status=${eval_status})"
      archived=$((archived + 1))
    fi
  done

  if [[ ${archived} -gt 0 ]]; then
    log "Evaluations archived: ${archived}"
  fi
}

main() {
  log "Archive process started (min_age_days=${MIN_AGE_DAYS})"

  local archived=0 skipped=0

  # Collect archivable task IDs from decisions directory
  for decision_file in "${SHARED_DIR}/decisions/"*.json; do
    [[ -f "${decision_file}" ]] || continue
    # Skip non-decision files
    local basename
    basename=$(basename "${decision_file}")
    [[ "${basename}" == *_result.json ]] && continue
    [[ "${basename}" == *_history.json ]] && continue
    [[ "${basename}" == *_progress.jsonl ]] && continue
    [[ "${basename}" == *_announce_progress.jsonl ]] && continue

    local task_id
    task_id=$(basename "${decision_file}" .json)

    if is_archivable "${task_id}"; then
      log "Archiving: ${task_id}"
      archive_task "${task_id}"
      archived=$((archived + 1))
    else
      skipped=$((skipped + 1))
    fi
  done

  log "Archive complete: archived=${archived}, skipped=${skipped}"

  # Archive completed evaluations
  archive_evaluations
}

main
