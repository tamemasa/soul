#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:?WORKER_NAME is required}"
SHARED_DIR="/shared"
WORKER_DIR="/worker"
CONFIG_DIR="${WORKER_DIR}/config"
POLL_INTERVAL=30

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local msg="[${timestamp}] [worker:${WORKER_NAME}] $*"
  echo "${msg}"
  local log_dir="${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)"
  mkdir -p "${log_dir}"
  echo "${msg}" >> "${log_dir}/worker_${WORKER_NAME}.log"
}

update_status() {
  local status="$1"
  local status_file="${SHARED_DIR}/workers/${WORKER_NAME}/status.json"
  mkdir -p "$(dirname "${status_file}")"
  local tmp
  tmp=$(mktemp)
  if [[ -f "${status_file}" ]]; then
    jq '.status = "'"${status}"'" | .updated_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
      "${status_file}" > "${tmp}" && mv "${tmp}" "${status_file}"
  else
    cat > "${status_file}" <<EOF
{
  "worker": "${WORKER_NAME}",
  "status": "${status}",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  fi
}

check_worker_tasks() {
  local task_dir="${SHARED_DIR}/workers/${WORKER_NAME}/tasks"
  mkdir -p "${task_dir}"

  for task_file in "${task_dir}"/*.json; do
    [[ -f "${task_file}" ]] || continue

    local task_status
    task_status=$(jq -r '.status' "${task_file}")
    [[ "${task_status}" == "pending" ]] || continue

    local task_id
    task_id=$(jq -r '.id' "${task_file}")
    log "Executing worker task: ${task_id}"

    # Mark as running
    local tmp
    tmp=$(mktemp)
    jq '.status = "running" | .started_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
      "${task_file}" > "${tmp}" && mv "${tmp}" "${task_file}"

    local description
    description=$(jq -r '.description' "${task_file}")

    # Execute via Claude Code
    local result
    result=$(claude -p "${description}" --output-format text 2>&1) || true

    # Mark as completed
    local escaped_result
    escaped_result=$(echo "${result}" | jq -Rs .)
    tmp=$(mktemp)
    jq '.status = "completed" | .completed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .result = '"${escaped_result}"'' \
      "${task_file}" > "${tmp}" && mv "${tmp}" "${task_file}"

    log "Worker task ${task_id} completed"
  done
}

main() {
  log "Worker ${WORKER_NAME} starting"
  update_status "running"

  # Run setup script if exists
  if [[ -f "${CONFIG_DIR}/setup.sh" ]]; then
    log "Running setup script"
    bash "${CONFIG_DIR}/setup.sh"
  fi

  # Main loop
  while true; do
    check_worker_tasks
    update_status "running"
    sleep "${POLL_INTERVAL}"
  done
}

main
