#!/usr/bin/env bash
# panda-openclaw-monitor.sh - Panda's policy compliance monitoring for Open Claw Bot
#
# Panda (safety-focused node) monitors Open Claw every 5 minutes to ensure:
# - Bot responses comply with Soul system mission and policies
# - No abnormal behavior patterns (rapid messages, high error rate, etc.)
# - Staged intervention: report → warn → command → force restart
#
# This is separate from triceratops' buddy-monitor.sh (security/integrity focus).
# Panda focuses on policy compliance and behavioral anomalies.

PANDA_MONITOR_DIR="${SHARED_DIR}/monitoring"
PANDA_MONITOR_INTERVAL=300  # 5 minutes in seconds
PANDA_POLICY_FILE="${SHARED_DIR}/monitoring/policy.json"
PANDA_STATE_FILE="${SHARED_DIR}/monitoring/latest.json"
PANDA_REPORTS_DIR="${SHARED_DIR}/monitoring/reports"
PANDA_ALERTS_DIR="${SHARED_DIR}/alerts"
PANDA_COMMANDS_DIR="${SHARED_DIR}/bot_commands"
PANDA_FALSE_POSITIVES="${SHARED_DIR}/monitoring/false_positives.json"
PANDA_OPENCLAW_CONTAINER="soul-openclaw"
PANDA_OPENCLAW_SESSIONS="/home/openclaw/.openclaw/agents/main/sessions"

# Main entry point - called from daemon loop
check_panda_openclaw_monitor() {
  # Only panda runs this monitor
  [[ "${NODE_NAME}" == "panda" ]] || return 0

  # Rate limit: check every 5 minutes
  local now_epoch
  now_epoch=$(date +%s)

  if [[ -f "${PANDA_STATE_FILE}" ]]; then
    local last_epoch
    last_epoch=$(jq -r '.last_check_epoch // 0' "${PANDA_STATE_FILE}")
    local elapsed=$((now_epoch - last_epoch))
    if [[ ${elapsed} -lt ${PANDA_MONITOR_INTERVAL} ]]; then
      return 0
    fi
  fi

  log "Panda monitor: starting 5-minute policy compliance check"
  set_activity "monitoring" "\"detail\":\"panda_policy_check\","

  mkdir -p "${PANDA_REPORTS_DIR}" "${PANDA_ALERTS_DIR}" "${PANDA_COMMANDS_DIR}"

  # 1. Check container is running
  local container_running
  container_running=$(docker ps --filter "name=${PANDA_OPENCLAW_CONTAINER}" --filter "status=running" --format "{{.Names}}" 2>/dev/null)
  if [[ -z "${container_running}" ]]; then
    log "WARN: Panda monitor - OpenClaw container not running"
    _panda_record_alert "critical" "container_down" "Open Clawコンテナが停止しています"
    _panda_update_state "${now_epoch}" "container_down" 0
    set_activity "idle"
    return 0
  fi

  # 2. Get recent conversation data
  local messages
  messages=$(_panda_get_recent_messages)
  if [[ -z "${messages}" || "${messages}" == "[]" ]]; then
    log "Panda monitor: No messages to check"
    _panda_update_state "${now_epoch}" "healthy" 0
    set_activity "idle"
    return 0
  fi

  # 3. Count messages and check for new activity
  local msg_count
  msg_count=$(echo "${messages}" | jq 'length' 2>/dev/null || echo 0)

  local last_msg_count=0
  if [[ -f "${PANDA_STATE_FILE}" ]]; then
    last_msg_count=$(jq -r '.last_message_count // 0' "${PANDA_STATE_FILE}")
  fi

  if [[ ${msg_count} -le ${last_msg_count} ]]; then
    log "Panda monitor: No new messages since last check (count: ${msg_count})"
    _panda_update_state "${now_epoch}" "healthy" "${msg_count}"
    set_activity "idle"
    return 0
  fi

  log "Panda monitor: Checking ${msg_count} messages (${last_msg_count} previously)"

  # 4. Run policy compliance checks
  local violations=0
  local report_entries="[]"

  # 4a. Forbidden pattern check
  local pattern_result
  pattern_result=$(_panda_check_forbidden_patterns "${messages}")
  local pattern_violations
  pattern_violations=$(echo "${pattern_result}" | jq 'length' 2>/dev/null || echo 0)
  if [[ ${pattern_violations} -gt 0 ]]; then
    violations=$((violations + pattern_violations))
    report_entries=$(echo "${report_entries}" | jq --argjson pv "${pattern_result}" '. + $pv')
  fi

  # 4b. Abnormal behavior check
  local behavior_result
  behavior_result=$(_panda_check_abnormal_behavior "${messages}")
  local behavior_violations
  behavior_violations=$(echo "${behavior_result}" | jq 'length' 2>/dev/null || echo 0)
  if [[ ${behavior_violations} -gt 0 ]]; then
    violations=$((violations + behavior_violations))
    report_entries=$(echo "${report_entries}" | jq --argjson bv "${behavior_result}" '. + $bv')
  fi

  # 4c. Filter out known false positives
  report_entries=$(_panda_filter_false_positives "${report_entries}")
  violations=$(echo "${report_entries}" | jq 'length' 2>/dev/null || echo 0)

  # 5. Determine overall status and intervention level
  local status="healthy"
  local max_level=0

  if [[ ${violations} -gt 0 ]]; then
    # Find highest severity
    local max_severity
    max_severity=$(echo "${report_entries}" | jq -r '[.[].severity] | sort | last // "info"')

    if [[ -f "${PANDA_POLICY_FILE}" ]]; then
      max_level=$(jq -r --arg sev "${max_severity}" '.severity_to_level[$sev] // 1' "${PANDA_POLICY_FILE}")
    fi

    case ${max_level} in
      1) status="info" ;;
      2) status="warning" ;;
      3) status="intervention" ;;
      4) status="critical" ;;
      *) status="info" ;;
    esac
  fi

  # 6. Save report
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local report_file="${PANDA_REPORTS_DIR}/report_$(date -u +%Y%m%d_%H%M%S).json"
  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg ts "${timestamp}" \
    --arg st "${status}" \
    --argjson vc "${violations}" \
    --argjson mc "${msg_count}" \
    --argjson lv "${max_level}" \
    --argjson entries "${report_entries}" \
    '{
      checked_at: $ts,
      status: $st,
      violation_count: $vc,
      message_count: $mc,
      intervention_level: $lv,
      violations: $entries
    }' > "${tmp}" && mv "${tmp}" "${report_file}"

  # 7. Execute intervention based on level
  if [[ ${max_level} -ge 2 ]]; then
    _panda_execute_intervention "${max_level}" "${status}" "${report_entries}"
  fi

  # 8. Prune old reports (keep last 100)
  local report_count
  report_count=$(ls -1 "${PANDA_REPORTS_DIR}"/report_*.json 2>/dev/null | wc -l)
  if [[ ${report_count} -gt 100 ]]; then
    ls -1t "${PANDA_REPORTS_DIR}"/report_*.json | tail -n +101 | xargs rm -f
  fi

  # 9. Update state
  _panda_update_state "${now_epoch}" "${status}" "${msg_count}"

  set_activity "idle"
  log "Panda monitor: Check complete (status: ${status}, violations: ${violations})"
}

# Get recent messages from OpenClaw sessions
_panda_get_recent_messages() {
  # Get sessions list from container
  local sessions_json
  sessions_json=$(docker exec "${PANDA_OPENCLAW_CONTAINER}" cat "${PANDA_OPENCLAW_SESSIONS}/sessions.json" 2>/dev/null) || {
    log "WARN: Panda monitor - Cannot read OpenClaw sessions"
    echo "[]"
    return 1
  }

  # Find active Discord session files
  local session_files
  session_files=$(echo "${sessions_json}" | jq -r '
    to_entries[] |
    select(.value.channel == "discord" and .value.sessionFile != null) |
    .value.sessionFile
  ' 2>/dev/null)

  [[ -n "${session_files}" ]] || { echo "[]"; return 0; }

  # Read the most recent session (last 50 messages for policy check)
  local latest_session
  latest_session=$(echo "${session_files}" | head -1)
  [[ -n "${latest_session}" ]] || { echo "[]"; return 0; }

  docker exec "${PANDA_OPENCLAW_CONTAINER}" tail -n 50 "${latest_session}" 2>/dev/null | \
    jq -s '[.[] | select(.type == "message") | {
      role: .message.role,
      timestamp: .timestamp,
      content: (
        if .message.content | type == "array" then
          [.message.content[] | select(.type == "text") | .text] | join("\n")
        elif .message.content | type == "string" then
          .message.content
        else
          ""
        end
      )
    }]' 2>/dev/null || echo "[]"
}

# Check messages against forbidden patterns defined in policy.json
_panda_check_forbidden_patterns() {
  local messages="$1"
  local violations="[]"

  [[ -f "${PANDA_POLICY_FILE}" ]] || { echo "[]"; return 0; }

  # Load patterns from policy
  local pattern_count
  pattern_count=$(jq '.forbidden_patterns.patterns | length' "${PANDA_POLICY_FILE}" 2>/dev/null || echo 0)

  for ((i=0; i<pattern_count; i++)); do
    local pattern_id pattern_regex severity check_role
    pattern_id=$(jq -r ".forbidden_patterns.patterns[$i].id" "${PANDA_POLICY_FILE}")
    pattern_regex=$(jq -r ".forbidden_patterns.patterns[$i].pattern" "${PANDA_POLICY_FILE}")
    severity=$(jq -r ".forbidden_patterns.patterns[$i].severity" "${PANDA_POLICY_FILE}")
    check_role=$(jq -r ".forbidden_patterns.patterns[$i].check_role // \"all\"" "${PANDA_POLICY_FILE}")

    # Extract text based on role filter
    local texts_to_check
    if [[ "${check_role}" == "assistant" ]]; then
      texts_to_check=$(echo "${messages}" | jq -r '[.[] | select(.role == "assistant") | .content] | join("\n")' 2>/dev/null)
    elif [[ "${check_role}" == "user" ]]; then
      texts_to_check=$(echo "${messages}" | jq -r '[.[] | select(.role == "user") | .content] | join("\n")' 2>/dev/null)
    else
      texts_to_check=$(echo "${messages}" | jq -r '[.[].content] | join("\n")' 2>/dev/null)
    fi

    [[ -n "${texts_to_check}" ]] || continue

    # Check for pattern match
    local match_count
    match_count=$(echo "${texts_to_check}" | grep -icP "${pattern_regex}" 2>/dev/null || echo 0)
    match_count=$(echo "${match_count}" | tr -dc '0-9')
    match_count=${match_count:-0}

    if [[ ${match_count} -gt 0 ]]; then
      local desc
      desc=$(jq -r ".forbidden_patterns.patterns[$i].description" "${PANDA_POLICY_FILE}")
      violations=$(echo "${violations}" | jq \
        --arg pid "${pattern_id}" \
        --arg sev "${severity}" \
        --arg desc "${desc}" \
        --argjson cnt "${match_count}" \
        '. + [{
          type: "forbidden_pattern",
          pattern_id: $pid,
          severity: $sev,
          description: $desc,
          match_count: $cnt
        }]')
    fi
  done

  echo "${violations}"
}

# Check for abnormal behavior patterns
_panda_check_abnormal_behavior() {
  local messages="$1"
  local violations="[]"

  [[ -f "${PANDA_POLICY_FILE}" ]] || { echo "[]"; return 0; }

  # 1. Rapid message check
  local rapid_threshold
  rapid_threshold=$(jq -r '.abnormal_behavior.rapid_messages.threshold // 20' "${PANDA_POLICY_FILE}")
  local rapid_window
  rapid_window=$(jq -r '.abnormal_behavior.rapid_messages.window_minutes // 5' "${PANDA_POLICY_FILE}")

  local now_epoch
  now_epoch=$(date +%s)
  local window_start=$((now_epoch - rapid_window * 60))

  # Count assistant messages in the window
  local recent_assistant_count
  recent_assistant_count=$(echo "${messages}" | jq --argjson ws "${window_start}" '
    [.[] | select(.role == "assistant") |
      select((.timestamp // "") | if . == "" then false else (. | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > $ws end)
    ] | length
  ' 2>/dev/null || echo 0)
  recent_assistant_count=$(echo "${recent_assistant_count}" | tr -dc '0-9')
  recent_assistant_count=${recent_assistant_count:-0}

  if [[ ${recent_assistant_count} -ge ${rapid_threshold} ]]; then
    violations=$(echo "${violations}" | jq \
      --argjson cnt "${recent_assistant_count}" \
      --argjson thr "${rapid_threshold}" \
      '. + [{
        type: "rapid_messages",
        severity: "high",
        description: ("5分間に" + ($cnt | tostring) + "件のBot応答を検知（閾値: " + ($thr | tostring) + "）"),
        count: $cnt
      }]')
  fi

  # 2. Empty response check
  local empty_threshold
  empty_threshold=$(jq -r '.abnormal_behavior.empty_responses.threshold // 3' "${PANDA_POLICY_FILE}")
  local empty_count
  empty_count=$(echo "${messages}" | jq '[.[] | select(.role == "assistant" and (.content == "" or .content == null))] | length' 2>/dev/null || echo 0)
  empty_count=$(echo "${empty_count}" | tr -dc '0-9')
  empty_count=${empty_count:-0}

  if [[ ${empty_count} -ge ${empty_threshold} ]]; then
    violations=$(echo "${violations}" | jq \
      --argjson cnt "${empty_count}" \
      '. + [{
        type: "empty_responses",
        severity: "medium",
        description: ("空レスポンスを" + ($cnt | tostring) + "件検知"),
        count: $cnt
      }]')
  fi

  # 3. Check for error patterns in container logs
  local error_lines
  error_lines=$(docker logs "${PANDA_OPENCLAW_CONTAINER}" --since "${PANDA_MONITOR_INTERVAL}s" 2>&1 | grep -ic "error\|exception\|fatal\|crash" 2>/dev/null || echo 0)
  error_lines=$(echo "${error_lines}" | tr -dc '0-9')
  error_lines=${error_lines:-0}

  local consecutive_err_warn
  consecutive_err_warn=$(jq -r '.abnormal_behavior.consecutive_errors.warn_threshold // 3' "${PANDA_POLICY_FILE}")
  local consecutive_err_intervene
  consecutive_err_intervene=$(jq -r '.abnormal_behavior.consecutive_errors.intervene_threshold // 5' "${PANDA_POLICY_FILE}")

  if [[ ${error_lines} -ge ${consecutive_err_intervene} ]]; then
    violations=$(echo "${violations}" | jq \
      --argjson cnt "${error_lines}" \
      '. + [{
        type: "high_error_rate",
        severity: "high",
        description: ("直近5分間にエラーを" + ($cnt | tostring) + "件検知（介入閾値超過）"),
        count: $cnt
      }]')
  elif [[ ${error_lines} -ge ${consecutive_err_warn} ]]; then
    violations=$(echo "${violations}" | jq \
      --argjson cnt "${error_lines}" \
      '. + [{
        type: "elevated_error_rate",
        severity: "medium",
        description: ("直近5分間にエラーを" + ($cnt | tostring) + "件検知（警告閾値超過）"),
        count: $cnt
      }]')
  fi

  echo "${violations}"
}

# Filter out known false positives
_panda_filter_false_positives() {
  local entries="$1"

  [[ -f "${PANDA_FALSE_POSITIVES}" ]] || { echo "${entries}"; return 0; }

  local fp_count
  fp_count=$(jq '.entries | length' "${PANDA_FALSE_POSITIVES}" 2>/dev/null || echo 0)
  [[ ${fp_count} -gt 0 ]] || { echo "${entries}"; return 0; }

  # Load false positive pattern IDs
  local fp_ids
  fp_ids=$(jq -r '[.entries[].pattern_id // empty] | join("|")' "${PANDA_FALSE_POSITIVES}" 2>/dev/null)
  [[ -n "${fp_ids}" ]] || { echo "${entries}"; return 0; }

  # Filter entries that match false positive IDs
  echo "${entries}" | jq --arg fps "${fp_ids}" '
    [.[] | select(
      (.pattern_id // "") as $pid |
      ($fps | split("|")) as $fp_list |
      ($fp_list | index($pid)) == null
    )]
  ' 2>/dev/null || echo "${entries}"
}

# Execute intervention based on level
_panda_execute_intervention() {
  local level="$1"
  local status="$2"
  local violations="$3"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  case ${level} in
    2)
      # Level 2: Warning - alert file + notify other nodes
      log "Panda monitor: Level 2 intervention - creating alert"
      _panda_record_alert "medium" "policy_violation" "ポリシー違反を検知（警告レベル）"
      _panda_notify_nodes "${status}" "${violations}"
      ;;
    3)
      # Level 3: Command - send command to bot
      log "Panda monitor: Level 3 intervention - sending bot command"
      _panda_record_alert "high" "policy_violation" "ポリシー違反を検知（コマンド介入レベル）"
      _panda_notify_nodes "${status}" "${violations}"

      # Determine appropriate command based on violation type
      local primary_type
      primary_type=$(echo "${violations}" | jq -r '.[0].type // "unknown"')

      case "${primary_type}" in
        rapid_messages)
          _panda_send_bot_command "pause" '{"duration_minutes": 5}' "急速なメッセージ送信を検知。5分間一時停止"
          ;;
        high_error_rate)
          _panda_send_bot_command "adjust_params" '{"reduce_activity": true}' "高エラー率を検知。活動を抑制"
          ;;
        *)
          _panda_send_bot_command "adjust_params" '{"safety_mode": true}' "ポリシー違反を検知。安全モードへ移行"
          ;;
      esac
      ;;
    4)
      # Level 4: Force restart - but require human approval
      log "Panda monitor: Level 4 intervention - requesting human approval for restart"
      _panda_record_alert "critical" "policy_violation_critical" "重大なポリシー違反を検知。コンテナ再起動の承認を要求"
      _panda_notify_nodes "${status}" "${violations}"

      # Create pending action (same pattern as openclaw-remediation.sh)
      local pending_dir="${SHARED_DIR}/openclaw/monitor/pending_actions"
      mkdir -p "${pending_dir}"
      local action_id="panda_action_$(date +%s)_$((RANDOM % 10000))"
      local tmp
      tmp=$(mktemp)
      jq -n \
        --arg id "${action_id}" \
        --arg ts "${timestamp}" \
        --arg desc "パンダ監視: 重大なポリシー違反によりコンテナ再起動を推奨" \
        '{
          id: $id,
          created_at: $ts,
          action_type: "container_restart",
          alert_type: "policy_violation_critical",
          description: $desc,
          status: "pending",
          source: "panda_monitor",
          approved_by: null,
          approved_at: null,
          executed_at: null
        }' > "${tmp}" && mv "${tmp}" "${pending_dir}/${action_id}.json"
      log "Panda monitor: Pending restart action created: ${action_id}"
      ;;
  esac
}

# Record an alert to /shared/alerts/
_panda_record_alert() {
  local severity="$1"
  local alert_type="$2"
  local description="$3"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local alert_id="panda_alert_$(date +%s)_$((RANDOM % 10000))"
  local alert_file="${PANDA_ALERTS_DIR}/${alert_id}.json"

  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg id "${alert_id}" \
    --arg ts "${timestamp}" \
    --arg sev "${severity}" \
    --arg type "${alert_type}" \
    --arg desc "${description}" \
    --arg src "panda_monitor" \
    '{
      id: $id,
      created_at: $ts,
      severity: $sev,
      type: $type,
      description: $desc,
      source: $src,
      acknowledged: false
    }' > "${tmp}" && mv "${tmp}" "${alert_file}"

  log "ALERT [${severity}] panda_monitor: ${description}"

  # Also append to monitoring alerts log
  local alerts_log="${PANDA_MONITOR_DIR}/alerts.jsonl"
  jq -n \
    --arg id "${alert_id}" \
    --arg ts "${timestamp}" \
    --arg sev "${severity}" \
    --arg type "${alert_type}" \
    --arg desc "${description}" \
    '{id: $id, timestamp: $ts, severity: $sev, type: $type, description: $desc}' >> "${alerts_log}"
}

# Notify other brain nodes about issues
_panda_notify_nodes() {
  local status="$1"
  local violations="$2"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Write notification to each node's directory
  for node in gorilla triceratops; do
    local node_dir="${SHARED_DIR}/nodes/${node}"
    mkdir -p "${node_dir}"
    local notif_file="${node_dir}/panda_monitor_notification.json"
    local tmp
    tmp=$(mktemp)
    jq -n \
      --arg ts "${timestamp}" \
      --arg st "${status}" \
      --argjson v "${violations}" \
      '{
        from: "panda",
        type: "openclaw_policy_alert",
        timestamp: $ts,
        status: $st,
        violations: $v
      }' > "${tmp}" && mv "${tmp}" "${notif_file}"
  done

  log "Panda monitor: Notified gorilla and triceratops about ${status} status"
}

# Send a command to Open Claw via /shared/bot_commands/
_panda_send_bot_command() {
  local action="$1"
  local params="$2"
  local reason="$3"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local cmd_id="cmd_$(date +%s)_$((RANDOM % 10000))"
  local cmd_file="${PANDA_COMMANDS_DIR}/${cmd_id}.json"

  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg id "${cmd_id}" \
    --arg action "${action}" \
    --argjson params "${params}" \
    --arg ts "${timestamp}" \
    --arg reason "${reason}" \
    --arg src "panda_monitor" \
    '{
      id: $id,
      action: $action,
      params: $params,
      timestamp: $ts,
      reason: $reason,
      source: $src,
      status: "pending"
    }' > "${tmp}" && mv "${tmp}" "${cmd_file}"

  log "Panda monitor: Bot command sent: ${cmd_id} (action: ${action})"
}

# Update the monitoring state (latest.json)
_panda_update_state() {
  local now_epoch="$1"
  local status="$2"
  local msg_count="$3"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ -f "${PANDA_STATE_FILE}" ]]; then
    local tmp
    tmp=$(mktemp)
    jq --argjson epoch "${now_epoch}" \
       --arg ts "${timestamp}" \
       --arg st "${status}" \
       --argjson mc "${msg_count}" \
       '.last_check_epoch = $epoch |
        .last_check_at = $ts |
        .status = $st |
        .last_message_count = $mc |
        .check_count = ((.check_count // 0) + 1)' \
       "${PANDA_STATE_FILE}" > "${tmp}" && mv "${tmp}" "${PANDA_STATE_FILE}"
  else
    local tmp
    tmp=$(mktemp)
    jq -n \
      --argjson epoch "${now_epoch}" \
      --arg ts "${timestamp}" \
      --arg st "${status}" \
      --argjson mc "${msg_count}" \
      '{
        last_check_epoch: $epoch,
        last_check_at: $ts,
        status: $st,
        last_message_count: $mc,
        check_count: 1,
        monitor_type: "panda_policy_compliance",
        interval_seconds: 300
      }' > "${tmp}" && mv "${tmp}" "${PANDA_STATE_FILE}"
  fi
}
