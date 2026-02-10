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

case "${ACTION}" in
  evaluation)
    trigger_evaluation
    ;;
  cleanup)
    cleanup_old_logs
    ;;
  *)
    log "Unknown action: ${ACTION}. Usage: cron-tasks.sh [evaluation|cleanup]"
    exit 1
    ;;
esac
