#!/usr/bin/env bash
# openclaw-remediation.sh - Staged remediation for Open Claw buddy system
# Handles backup, config restoration, and container restart with approval workflow

OPENCLAW_BACKUP_DIR="${SHARED_DIR}/openclaw/monitor/backups"
OPENCLAW_BACKUP_GENERATIONS=7
OPENCLAW_REMEDIATION_LOG="${SHARED_DIR}/openclaw/monitor/remediation.jsonl"

# Check if auto-remediation is enabled (disabled during first 2 weeks)
_is_auto_remediation_enabled() {
  local state_file="${SHARED_DIR}/openclaw/monitor/state.json"
  [[ -f "${state_file}" ]] || return 1

  local auto_remediation
  auto_remediation=$(jq -r '.auto_remediation // false' "${state_file}")
  [[ "${auto_remediation}" == "true" ]] && return 0

  return 1
}

# Check if manual approval period has expired
_is_manual_approval_period() {
  local state_file="${SHARED_DIR}/openclaw/monitor/state.json"
  [[ -f "${state_file}" ]] || return 0  # default to manual approval

  local until_date
  until_date=$(jq -r '.manual_approval_until // "2026-02-25T00:00:00Z"' "${state_file}")
  local until_epoch
  until_epoch=$(date -d "${until_date}" +%s 2>/dev/null || echo 9999999999)
  local now_epoch
  now_epoch=$(date +%s)

  [[ ${now_epoch} -lt ${until_epoch} ]] && return 0
  return 1
}

# Create a backup of the current config file before modification
backup_openclaw_config() {
  local filename="$1"
  mkdir -p "${OPENCLAW_BACKUP_DIR}"

  local timestamp
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  local backup_file="${OPENCLAW_BACKUP_DIR}/${filename}.${timestamp}"

  # Copy from container
  docker exec "${OPENCLAW_CONTAINER}" cat "${OPENCLAW_PERSONALITY_DIR}/${filename}" > "${backup_file}" 2>/dev/null || {
    log "ERROR: Failed to backup ${filename}"
    return 1
  }

  log "Backup created: ${backup_file}"

  # Prune old backups (keep OPENCLAW_BACKUP_GENERATIONS)
  local backups
  backups=$(ls -t "${OPENCLAW_BACKUP_DIR}/${filename}."* 2>/dev/null)
  local count=0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    ((count++))
    if [[ ${count} -gt ${OPENCLAW_BACKUP_GENERATIONS} ]]; then
      rm -f "${f}"
      log "Pruned old backup: ${f}"
    fi
  done <<< "${backups}"

  return 0
}

# Execute remediation based on severity
execute_remediation() {
  local severity="$1"
  local alert_type="$2"
  local description="$3"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  case "${severity}" in
    low)
      # Log only - no action needed
      _log_remediation "${timestamp}" "log_only" "${alert_type}" "${description}" "none"
      ;;
    medium)
      if _is_manual_approval_period; then
        # During manual approval period: create pending action
        _create_pending_action "${timestamp}" "config_restore" "${alert_type}" "${description}"
        _log_remediation "${timestamp}" "pending_approval" "${alert_type}" "${description}" "config_restore"
      elif _is_auto_remediation_enabled; then
        # Auto mode: backup and fix
        _auto_restore_config "${alert_type}" "${description}"
        _log_remediation "${timestamp}" "auto_restored" "${alert_type}" "${description}" "config_restore"
      else
        _create_pending_action "${timestamp}" "config_restore" "${alert_type}" "${description}"
        _log_remediation "${timestamp}" "pending_approval" "${alert_type}" "${description}" "config_restore"
      fi
      ;;
    high)
      # Always require manual approval for high severity
      _create_pending_action "${timestamp}" "container_restart" "${alert_type}" "${description}"
      _log_remediation "${timestamp}" "pending_approval" "${alert_type}" "${description}" "container_restart"
      # Also create a notification for Masaru
      _notify_masaru "${alert_type}" "${description}"
      ;;
  esac
}

_auto_restore_config() {
  local alert_type="$1"
  local description="$2"

  log "Auto-remediation: restoring config files for ${alert_type}"

  case "${alert_type}" in
    personality_tampered|agents_tampered)
      local filename
      [[ "${alert_type}" == "personality_tampered" ]] && filename="SOUL.md" || filename="AGENTS.md"
      backup_openclaw_config "${filename}"
      _restore_personality_file "${filename}"
      ;;
    identity_deviation|prompt_override_attempt)
      # For behavioral issues, restore both personality files
      backup_openclaw_config "SOUL.md"
      backup_openclaw_config "AGENTS.md"
      _restore_personality_file "SOUL.md"
      _restore_personality_file "AGENTS.md"
      ;;
  esac
}

_create_pending_action() {
  local timestamp="$1"
  local action_type="$2"
  local alert_type="$3"
  local description="$4"

  local pending_dir="${SHARED_DIR}/openclaw/monitor/pending_actions"
  mkdir -p "${pending_dir}"

  local action_id="action_$(date +%s)_$((RANDOM % 10000))"
  local action_file="${pending_dir}/${action_id}.json"

  jq -n \
    --arg id "${action_id}" \
    --arg ts "${timestamp}" \
    --arg action "${action_type}" \
    --arg alert "${alert_type}" \
    --arg desc "${description}" \
    '{
      id: $id,
      created_at: $ts,
      action_type: $action,
      alert_type: $alert,
      description: $desc,
      status: "pending",
      approved_by: null,
      approved_at: null,
      executed_at: null
    }' > "${action_file}"

  log "Pending action created: ${action_id} (${action_type})"
}

# Process approved actions (called from daemon loop or UI trigger)
process_approved_actions() {
  local pending_dir="${SHARED_DIR}/openclaw/monitor/pending_actions"
  [[ -d "${pending_dir}" ]] || return 0

  for action_file in "${pending_dir}"/*.json; do
    [[ -f "${action_file}" ]] || continue

    local status
    status=$(jq -r '.status' "${action_file}")
    [[ "${status}" == "approved" ]] || continue

    local action_id action_type alert_type
    action_id=$(jq -r '.id' "${action_file}")
    action_type=$(jq -r '.action_type' "${action_file}")
    alert_type=$(jq -r '.alert_type' "${action_file}")

    log "Executing approved action: ${action_id} (${action_type})"

    case "${action_type}" in
      config_restore)
        _auto_restore_config "${alert_type}" "approved remediation"
        ;;
      container_restart)
        _restart_openclaw_container
        ;;
    esac

    # Mark as executed
    local tmp
    tmp=$(mktemp)
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq --arg ts "${ts}" '.status = "executed" | .executed_at = $ts' "${action_file}" > "${tmp}" && mv "${tmp}" "${action_file}"

    _log_remediation "${ts}" "executed" "${alert_type}" "Approved action ${action_id}" "${action_type}"
  done
}

_restart_openclaw_container() {
  log "Restarting Open Claw container..."

  # Check if container is running before restart
  local running
  running=$(docker ps --filter "name=${OPENCLAW_CONTAINER}" --filter "status=running" -q 2>/dev/null)

  if [[ -z "${running}" ]]; then
    log "WARN: Open Claw container is not running, starting..."
    docker compose -f /soul/docker-compose.yml up -d openclaw 2>&1 | while IFS= read -r line; do log "docker: ${line}"; done
  else
    docker compose -f /soul/docker-compose.yml restart openclaw 2>&1 | while IFS= read -r line; do log "docker: ${line}"; done
  fi

  # Wait and verify
  sleep 5
  local check
  check=$(docker ps --filter "name=${OPENCLAW_CONTAINER}" --filter "status=running" -q 2>/dev/null)
  if [[ -n "${check}" ]]; then
    log "Open Claw container restarted successfully"
  else
    log "ERROR: Open Claw container failed to start after restart"
  fi
}

_notify_masaru() {
  local alert_type="$1"
  local description="$2"

  # Create a notification file that the dashboard can pick up
  local notifications_dir="${SHARED_DIR}/openclaw/monitor/notifications"
  mkdir -p "${notifications_dir}"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local notification_id="notif_$(date +%s)_$((RANDOM % 10000))"

  jq -n \
    --arg id "${notification_id}" \
    --arg ts "${timestamp}" \
    --arg alert "${alert_type}" \
    --arg desc "${description}" \
    '{
      id: $id,
      created_at: $ts,
      alert_type: $alert,
      description: $desc,
      read: false
    }' > "${notifications_dir}/${notification_id}.json"

  log "Notification created for Masaru: ${notification_id}"
}

_log_remediation() {
  local timestamp="$1"
  local action="$2"
  local alert_type="$3"
  local description="$4"
  local remediation_type="$5"

  local entry
  entry=$(jq -n \
    --arg ts "${timestamp}" \
    --arg action "${action}" \
    --arg alert "${alert_type}" \
    --arg desc "${description}" \
    --arg rtype "${remediation_type}" \
    '{timestamp: $ts, action: $action, alert_type: $alert, description: $desc, remediation_type: $rtype}')

  echo "${entry}" >> "${OPENCLAW_REMEDIATION_LOG}"
}
