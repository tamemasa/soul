#!/usr/bin/env bash
# unified-openclaw-monitor.sh - Unified OpenClaw monitoring (panda-operated)
#
# Consolidates three previously separate monitors into one:
# 1. Policy compliance (from panda-openclaw-monitor.sh) - every 5 min
# 2. Security/jailbreak detection (from buddy-monitor.sh + openclaw-monitor.sh) - every 10 min
# 3. Personality integrity (from openclaw-monitor.sh) - every 10 min
#
# Single 5-minute loop: policy check every time, security+integrity every 2nd check.
# Only panda runs this monitor.

UNIFIED_MONITOR_DIR="${SHARED_DIR}/monitoring"
UNIFIED_MONITOR_INTERVAL=300  # 5 minutes in seconds
UNIFIED_POLICY_FILE="${SHARED_DIR}/monitoring/policy.json"
UNIFIED_STATE_FILE="${SHARED_DIR}/monitoring/latest.json"
UNIFIED_INTEGRITY_FILE="${SHARED_DIR}/monitoring/integrity.json"
UNIFIED_REPORTS_DIR="${SHARED_DIR}/monitoring/reports"
UNIFIED_ALERTS_DIR="${SHARED_DIR}/alerts"
UNIFIED_COMMANDS_DIR="${SHARED_DIR}/bot_commands"
UNIFIED_FALSE_POSITIVES="${SHARED_DIR}/monitoring/false_positives.json"
UNIFIED_PENDING_DIR="${SHARED_DIR}/monitoring/pending_actions"
UNIFIED_REMEDIATION_LOG="${SHARED_DIR}/monitoring/remediation.jsonl"
UNIFIED_VALIDATION_DIR="${SHARED_DIR}/monitoring/validation"
UNIFIED_OPENCLAW_CONTAINER="soul-openclaw"
UNIFIED_OPENCLAW_SESSIONS="/home/openclaw/.openclaw/agents/main/sessions"
UNIFIED_OPENCLAW_PERSONALITY_DIR="/home/openclaw/.openclaw/workspace"

# Parallel mode disabled: unified monitor is now the sole monitor (legacy monitors removed)
UNIFIED_PARALLEL_MODE=false

# Main entry point - called from daemon loop
check_unified_openclaw_monitor() {
  # Only panda runs this monitor
  [[ "${NODE_NAME}" == "panda" ]] || return 0

  # Force check: UI手動トリガーによるintervalバイパス
  local force_check_file="${UNIFIED_MONITOR_DIR}/force_check.json"
  local force_check=false
  if [[ -f "${force_check_file}" ]]; then
    force_check=true
    log "Unified monitor: Force check triggered from UI"
  fi

  # Rate limit: check every 5 minutes (force_checkの場合はバイパス)
  local now_epoch
  now_epoch=$(date +%s)

  local check_count=0
  if [[ -f "${UNIFIED_STATE_FILE}" ]]; then
    local last_epoch
    last_epoch=$(jq -r '.last_check_epoch // 0' "${UNIFIED_STATE_FILE}")
    local elapsed=$((now_epoch - last_epoch))
    if [[ "${force_check}" != "true" && ${elapsed} -lt ${UNIFIED_MONITOR_INTERVAL} ]]; then
      return 0
    fi
    check_count=$(jq -r '.check_count // 0' "${UNIFIED_STATE_FILE}")
  fi

  # force_checkの場合はフルチェック実行のためcheck_countを偶数に設定
  if [[ "${force_check}" == "true" ]]; then
    check_count=$(( (check_count / 2) * 2 ))  # 偶数にして do_full_check=true を強制
    rm -f "${force_check_file}"
    log "Unified monitor: Force check file consumed, running full check"
  fi

  log "Unified monitor: starting check #$((check_count + 1))"
  set_activity "monitoring" "\"detail\":\"unified_openclaw_check\","

  mkdir -p "${UNIFIED_REPORTS_DIR}" "${UNIFIED_ALERTS_DIR}" "${UNIFIED_COMMANDS_DIR}" \
           "${UNIFIED_PENDING_DIR}" "${UNIFIED_VALIDATION_DIR}"

  # 1. Check container is running
  local container_running
  container_running=$(docker ps --filter "name=${UNIFIED_OPENCLAW_CONTAINER}" --filter "status=running" --format "{{.Names}}" 2>/dev/null)
  if [[ -z "${container_running}" ]]; then
    log "WARN: Unified monitor - OpenClaw container not running"
    _unified_record_alert "critical" "container_down" "Open Clawコンテナが停止しています" "policy"
    _unified_update_state "${now_epoch}" "container_down" 0
    set_activity "idle"
    return 0
  fi

  # 2. Get recent conversation data
  local messages
  messages=$(_unified_get_recent_messages)
  if [[ -z "${messages}" || "${messages}" == "[]" ]]; then
    log "Unified monitor: No messages to check"
    _unified_update_state "${now_epoch}" "healthy" 0
    set_activity "idle"
    return 0
  fi

  # 3. Count messages and check for new activity
  local msg_count
  msg_count=$(echo "${messages}" | jq 'length' 2>/dev/null || echo 0)

  local last_msg_count=0
  if [[ -f "${UNIFIED_STATE_FILE}" ]]; then
    last_msg_count=$(jq -r '.last_message_count // 0' "${UNIFIED_STATE_FILE}")
  fi

  if [[ "${force_check}" != "true" && ${msg_count} -le ${last_msg_count} ]]; then
    log "Unified monitor: No new messages since last check (count: ${msg_count})"
    _unified_update_state "${now_epoch}" "healthy" "${msg_count}"
    set_activity "idle"
    return 0
  fi

  log "Unified monitor: Checking ${msg_count} messages (${last_msg_count} previously)"

  # === POLICY CHECK (every 5 min) ===
  local violations=0
  local report_entries="[]"

  # 4a. Forbidden pattern check (policy compliance)
  local pattern_result
  pattern_result=$(_unified_check_forbidden_patterns "${messages}")
  local pattern_violations
  pattern_violations=$(echo "${pattern_result}" | jq 'length' 2>/dev/null || echo 0)
  if [[ ${pattern_violations} -gt 0 ]]; then
    violations=$((violations + pattern_violations))
    report_entries=$(echo "${report_entries}" | jq --argjson pv "${pattern_result}" '. + $pv')
  fi

  # 4b. Abnormal behavior check (policy compliance)
  local behavior_result
  behavior_result=$(_unified_check_abnormal_behavior "${messages}")
  local behavior_violations
  behavior_violations=$(echo "${behavior_result}" | jq 'length' 2>/dev/null || echo 0)
  if [[ ${behavior_violations} -gt 0 ]]; then
    violations=$((violations + behavior_violations))
    report_entries=$(echo "${report_entries}" | jq --argjson bv "${behavior_result}" '. + $bv')
  fi

  # 4c. Filter false positives
  report_entries=$(_unified_filter_false_positives "${report_entries}")
  violations=$(echo "${report_entries}" | jq 'length' 2>/dev/null || echo 0)

  # === SECURITY + INTEGRITY CHECK (every 10 min = every 2nd check) ===
  local security_violations=0
  local security_entries="[]"
  local integrity_status="ok"
  local do_full_check=false

  if [[ $((check_count % 2)) -eq 0 ]]; then
    do_full_check=true
    log "Unified monitor: Running full security + integrity check"

    # 5a. Jailbreak/threat pattern scan (from buddy-monitor.sh + openclaw-monitor.sh)
    local threat_result
    threat_result=$(_unified_scan_security_threats "${messages}")
    security_violations=$(echo "${threat_result}" | jq 'length' 2>/dev/null || echo 0)
    if [[ ${security_violations} -gt 0 ]]; then
      security_entries="${threat_result}"
    fi

    # 5b. LLM deep analysis if suspicious patterns found (from buddy-monitor.sh)
    if [[ ${security_violations} -gt 0 ]]; then
      local llm_result
      llm_result=$(_unified_llm_analysis "${messages}" "${security_entries}")
      local llm_status
      llm_status=$(echo "${llm_result}" | jq -r '.status // "healthy"' 2>/dev/null)
      if [[ "${llm_status}" == "critical" || "${llm_status}" == "warning" ]]; then
        local llm_entry
        llm_entry=$(echo "${llm_result}" | jq '{
          type: "llm_analysis",
          severity: (if .status == "critical" then "high" else "medium" end),
          description: .summary,
          category: "security",
          llm_status: .status,
          issues: .issues
        }' 2>/dev/null)
        if [[ -n "${llm_entry}" && "${llm_entry}" != "null" ]]; then
          security_entries=$(echo "${security_entries}" | jq --argjson e "${llm_entry}" '. + [$e]')
          security_violations=$((security_violations + 1))
        fi
      fi
    fi

    # 5c. Personality file integrity (from openclaw-monitor.sh)
    integrity_status=$(_unified_check_personality_integrity)

    # 5d. LLM-based identity compliance check (unconditional, every 10 min)
    log "Unified monitor: Running LLM identity compliance check"
    local identity_compliance
    identity_compliance=$(_unified_llm_identity_compliance_check "${messages}")
    local compliance_status
    compliance_status=$(echo "${identity_compliance}" | jq -r '.compliance_status // "compliant"' 2>/dev/null)
    if [[ "${compliance_status}" == "major_deviation" || "${compliance_status}" == "minor_deviation" ]]; then
      local compliance_entry
      compliance_entry=$(echo "${identity_compliance}" | jq '{
        type: "identity_compliance",
        severity: (if .compliance_status == "major_deviation" then "high" else "medium" end),
        description: .summary,
        category: "identity",
        compliance_status: .compliance_status,
        overall_score: .overall_score,
        tone_analysis: .tone_analysis,
        personality_match: .personality_match,
        issues: .issues
      }' 2>/dev/null)
      if [[ -n "${compliance_entry}" && "${compliance_entry}" != "null" ]]; then
        security_entries=$(echo "${security_entries}" | jq --argjson e "${compliance_entry}" '. + [$e]')
        security_violations=$((security_violations + 1))
      fi
    fi
    log "Unified monitor: Identity compliance: ${compliance_status}"
  fi

  # === COMBINE RESULTS ===
  local all_violations=$((violations + security_violations))
  local all_entries
  all_entries=$(echo "${report_entries}" | jq --argjson se "${security_entries}" '. + $se')

  # Determine overall status and intervention level
  local status="healthy"
  local max_level=0

  if [[ ${all_violations} -gt 0 ]]; then
    local max_severity
    max_severity=$(echo "${all_entries}" | jq -r '[.[].severity] | sort | last // "info"')

    if [[ -f "${UNIFIED_POLICY_FILE}" ]]; then
      max_level=$(jq -r --arg sev "${max_severity}" '.severity_to_level[$sev] // 1' "${UNIFIED_POLICY_FILE}")
    fi

    case ${max_level} in
      1) status="info" ;;
      2) status="warning" ;;
      3) status="intervention" ;;
      4) status="critical" ;;
      *) status="info" ;;
    esac
  fi

  # Save report
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local report_file="${UNIFIED_REPORTS_DIR}/report_$(date -u +%Y%m%d_%H%M%S).json"

  # Prepare identity compliance data for report
  local compliance_json="null"
  if [[ "${do_full_check}" == "true" && -n "${identity_compliance:-}" ]]; then
    compliance_json=$(echo "${identity_compliance}" | jq '{
      compliance_status: (.compliance_status // "unknown"),
      overall_score: (.overall_score // -1),
      tone_analysis: (.tone_analysis // null),
      personality_match: (.personality_match // null),
      buddy_stance: (.buddy_stance // null),
      security_compliance: (.security_compliance // null),
      summary: (.summary // "")
    }' 2>/dev/null || echo "null")
  fi

  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg ts "${timestamp}" \
    --arg st "${status}" \
    --argjson vc "${all_violations}" \
    --argjson mc "${msg_count}" \
    --argjson lv "${max_level}" \
    --argjson entries "${all_entries}" \
    --argjson policy_v "${violations}" \
    --argjson security_v "${security_violations}" \
    --arg integrity "${integrity_status}" \
    --argjson full "${do_full_check}" \
    --argjson compliance "${compliance_json}" \
    '{
      checked_at: $ts,
      status: $st,
      violation_count: $vc,
      message_count: $mc,
      intervention_level: $lv,
      violations: $entries,
      breakdown: {
        policy_violations: $policy_v,
        security_violations: $security_v,
        integrity_status: $integrity
      },
      full_check: $full,
      identity_compliance: $compliance
    }' > "${tmp}" && mv "${tmp}" "${report_file}"

  # Record alerts for policy violations (always active)
  if [[ ${violations} -gt 0 && ${max_level} -ge 2 ]]; then
    _unified_execute_intervention "${max_level}" "${status}" "${report_entries}" "policy"
  fi

  # Record alerts for security violations
  if [[ ${security_violations} -gt 0 ]]; then
    if [[ "${UNIFIED_PARALLEL_MODE}" == "true" ]]; then
      # Parallel mode: log to validation dir only, don't trigger alerts/intervention
      local validation_file="${UNIFIED_VALIDATION_DIR}/security_$(date -u +%Y%m%d_%H%M%S).json"
      echo "${security_entries}" | jq --arg ts "${timestamp}" '{timestamp: $ts, entries: .}' > "${validation_file}"
      log "Unified monitor: Security findings logged to validation (parallel mode)"
    else
      # Active mode: record security alerts and intervene
      local sec_max_severity
      sec_max_severity=$(echo "${security_entries}" | jq -r '[.[].severity] | sort | last // "info"')
      local sec_level=1
      case "${sec_max_severity}" in
        high) sec_level=3 ;;
        medium) sec_level=2 ;;
        *) sec_level=1 ;;
      esac
      if [[ ${sec_level} -ge 2 ]]; then
        _unified_execute_intervention "${sec_level}" "security_alert" "${security_entries}" "security"
      fi
      # Record individual security alerts
      while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue
        local sev desc atype
        sev=$(echo "${entry}" | jq -r '.severity // "medium"')
        desc=$(echo "${entry}" | jq -r '.description // "Security issue detected"')
        atype=$(echo "${entry}" | jq -r '.type // "security"')
        _unified_record_alert "${sev}" "${atype}" "${desc}" "security"
      done < <(echo "${security_entries}" | jq -c '.[]' 2>/dev/null)
    fi
  fi

  # Integrity alert
  if [[ "${integrity_status}" != "ok" && "${integrity_status}" != "" ]]; then
    if [[ "${UNIFIED_PARALLEL_MODE}" == "true" ]]; then
      local validation_file="${UNIFIED_VALIDATION_DIR}/integrity_$(date -u +%Y%m%d_%H%M%S).json"
      jq -n --arg ts "${timestamp}" --arg st "${integrity_status}" \
        '{timestamp: $ts, integrity_status: $st}' > "${validation_file}"
      log "Unified monitor: Integrity issue logged to validation (parallel mode)"
    else
      _unified_record_alert "high" "personality_integrity" "${integrity_status}" "integrity"
    fi
  fi

  # Prune old reports (keep last 100)
  local report_count
  report_count=$(ls -1 "${UNIFIED_REPORTS_DIR}"/report_*.json 2>/dev/null | wc -l)
  if [[ ${report_count} -gt 100 ]]; then
    ls -1t "${UNIFIED_REPORTS_DIR}"/report_*.json | tail -n +101 | xargs rm -f
  fi

  # Update state
  _unified_update_state "${now_epoch}" "${status}" "${msg_count}"

  # Append identity compliance to latest.json (if full check was run)
  if [[ "${do_full_check}" == "true" && -f "${UNIFIED_STATE_FILE}" ]]; then
    local cs="${compliance_status:-unknown}"
    local os=-1
    if [[ -n "${identity_compliance:-}" ]]; then
      os=$(echo "${identity_compliance}" | jq -r '.overall_score // -1' 2>/dev/null)
    fi
    local tmp_state
    tmp_state=$(mktemp)
    jq --arg cs "${cs}" --argjson os "${os}" \
       '.identity_compliance_status = $cs | .identity_compliance_score = $os' \
       "${UNIFIED_STATE_FILE}" > "${tmp_state}" && mv "${tmp_state}" "${UNIFIED_STATE_FILE}"
  fi

  set_activity "idle"
  log "Unified monitor: Check complete (status: ${status}, policy: ${violations}, security: ${security_violations}, integrity: ${integrity_status})"
}

# ============================================================
# Message Retrieval
# ============================================================

_unified_get_recent_messages() {
  local sessions_json
  sessions_json=$(docker exec "${UNIFIED_OPENCLAW_CONTAINER}" cat "${UNIFIED_OPENCLAW_SESSIONS}/sessions.json" 2>/dev/null) || {
    log "WARN: Unified monitor - Cannot read OpenClaw sessions"
    echo "[]"
    return 1
  }

  local session_files
  session_files=$(echo "${sessions_json}" | jq -r '
    to_entries[] |
    select((.value.channel == "discord" or .value.channel == "line") and .value.sessionFile != null) |
    .value.sessionFile
  ' 2>/dev/null)

  [[ -n "${session_files}" ]] || { echo "[]"; return 0; }

  local latest_session
  latest_session=$(echo "${session_files}" | head -1)
  [[ -n "${latest_session}" ]] || { echo "[]"; return 0; }

  docker exec "${UNIFIED_OPENCLAW_CONTAINER}" tail -n 50 "${latest_session}" 2>/dev/null | \
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

# ============================================================
# Policy Compliance Checks (from panda-openclaw-monitor.sh)
# ============================================================

_unified_check_forbidden_patterns() {
  local messages="$1"
  local violations="[]"

  [[ -f "${UNIFIED_POLICY_FILE}" ]] || { echo "[]"; return 0; }

  local pattern_count
  pattern_count=$(jq '.forbidden_patterns.patterns | length' "${UNIFIED_POLICY_FILE}" 2>/dev/null || echo 0)

  for ((i=0; i<pattern_count; i++)); do
    local pattern_id pattern_regex severity check_role
    pattern_id=$(jq -r ".forbidden_patterns.patterns[$i].id" "${UNIFIED_POLICY_FILE}")
    pattern_regex=$(jq -r ".forbidden_patterns.patterns[$i].pattern" "${UNIFIED_POLICY_FILE}")
    severity=$(jq -r ".forbidden_patterns.patterns[$i].severity" "${UNIFIED_POLICY_FILE}")
    check_role=$(jq -r ".forbidden_patterns.patterns[$i].check_role // \"all\"" "${UNIFIED_POLICY_FILE}")

    local texts_to_check
    if [[ "${check_role}" == "assistant" ]]; then
      texts_to_check=$(echo "${messages}" | jq -r '[.[] | select(.role == "assistant") | .content] | join("\n")' 2>/dev/null)
    elif [[ "${check_role}" == "user" ]]; then
      texts_to_check=$(echo "${messages}" | jq -r '[.[] | select(.role == "user") | .content] | join("\n")' 2>/dev/null)
    else
      texts_to_check=$(echo "${messages}" | jq -r '[.[].content] | join("\n")' 2>/dev/null)
    fi

    [[ -n "${texts_to_check}" ]] || continue

    local match_count
    match_count=$(echo "${texts_to_check}" | grep -icP "${pattern_regex}" 2>/dev/null || echo 0)
    match_count=$(echo "${match_count}" | tr -dc '0-9')
    match_count=${match_count:-0}

    if [[ ${match_count} -gt 0 ]]; then
      local desc
      desc=$(jq -r ".forbidden_patterns.patterns[$i].description" "${UNIFIED_POLICY_FILE}")
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
          match_count: $cnt,
          category: "policy"
        }]')
    fi
  done

  echo "${violations}"
}

_unified_check_abnormal_behavior() {
  local messages="$1"
  local violations="[]"

  [[ -f "${UNIFIED_POLICY_FILE}" ]] || { echo "[]"; return 0; }

  # 1. Rapid message check
  local rapid_threshold
  rapid_threshold=$(jq -r '.abnormal_behavior.rapid_messages.threshold // 20' "${UNIFIED_POLICY_FILE}")
  local rapid_window
  rapid_window=$(jq -r '.abnormal_behavior.rapid_messages.window_minutes // 5' "${UNIFIED_POLICY_FILE}")

  local now_epoch
  now_epoch=$(date +%s)
  local window_start=$((now_epoch - rapid_window * 60))

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
        count: $cnt,
        category: "policy"
      }]')
  fi

  # 2. Empty response check
  local empty_threshold
  empty_threshold=$(jq -r '.abnormal_behavior.empty_responses.threshold // 3' "${UNIFIED_POLICY_FILE}")
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
        count: $cnt,
        category: "policy"
      }]')
  fi

  # 3. Error rate check from container logs
  local error_lines
  error_lines=$(docker logs "${UNIFIED_OPENCLAW_CONTAINER}" --since "${UNIFIED_MONITOR_INTERVAL}s" 2>&1 | grep -ic "error\|exception\|fatal\|crash" 2>/dev/null || echo 0)
  error_lines=$(echo "${error_lines}" | tr -dc '0-9')
  error_lines=${error_lines:-0}

  local consecutive_err_warn
  consecutive_err_warn=$(jq -r '.abnormal_behavior.consecutive_errors.warn_threshold // 3' "${UNIFIED_POLICY_FILE}")
  local consecutive_err_intervene
  consecutive_err_intervene=$(jq -r '.abnormal_behavior.consecutive_errors.intervene_threshold // 5' "${UNIFIED_POLICY_FILE}")

  if [[ ${error_lines} -ge ${consecutive_err_intervene} ]]; then
    violations=$(echo "${violations}" | jq \
      --argjson cnt "${error_lines}" \
      '. + [{
        type: "high_error_rate",
        severity: "high",
        description: ("直近5分間にエラーを" + ($cnt | tostring) + "件検知（介入閾値超過）"),
        count: $cnt,
        category: "policy"
      }]')
  elif [[ ${error_lines} -ge ${consecutive_err_warn} ]]; then
    violations=$(echo "${violations}" | jq \
      --argjson cnt "${error_lines}" \
      '. + [{
        type: "elevated_error_rate",
        severity: "medium",
        description: ("直近5分間にエラーを" + ($cnt | tostring) + "件検知（警告閾値超過）"),
        count: $cnt,
        category: "policy"
      }]')
  fi

  echo "${violations}"
}

_unified_filter_false_positives() {
  local entries="$1"

  [[ -f "${UNIFIED_FALSE_POSITIVES}" ]] || { echo "${entries}"; return 0; }

  local fp_count
  fp_count=$(jq '.entries | length' "${UNIFIED_FALSE_POSITIVES}" 2>/dev/null || echo 0)
  [[ ${fp_count} -gt 0 ]] || { echo "${entries}"; return 0; }

  local fp_ids
  fp_ids=$(jq -r '[.entries[].pattern_id // empty] | join("|")' "${UNIFIED_FALSE_POSITIVES}" 2>/dev/null)
  [[ -n "${fp_ids}" ]] || { echo "${entries}"; return 0; }

  echo "${entries}" | jq --arg fps "${fp_ids}" '
    [.[] | select(
      (.pattern_id // "") as $pid |
      ($fps | split("|")) as $fp_list |
      ($fp_list | index($pid)) == null
    )]
  ' 2>/dev/null || echo "${entries}"
}

# ============================================================
# Security / Jailbreak Detection (from buddy-monitor.sh + openclaw-monitor.sh)
# ============================================================

_unified_scan_security_threats() {
  local messages="$1"
  local threats="[]"

  local user_messages
  user_messages=$(echo "${messages}" | jq -r '[.[] | select(.role == "user") | .content] | join("\n")' 2>/dev/null)
  local assistant_messages
  assistant_messages=$(echo "${messages}" | jq -r '[.[] | select(.role == "assistant") | .content] | join("\n")' 2>/dev/null)

  # --- Jailbreak patterns (from buddy-monitor.sh, 15 patterns) ---
  local jailbreak_patterns=(
    "ignore.*previous.*instructions"
    "ignore.*system.*prompt"
    "ignore.*all.*rules"
    "forget.*everything"
    "new.*persona"
    "developer.*mode"
    "act.*as.*if"
    "pretend.*you.*are"
    "DAN.*mode"
    "bypass.*restrictions"
    "override.*safety"
    "reveal.*system.*prompt"
    "show.*config"
    "change.*personality"
    "reset.*identity"
  )

  for pattern in "${jailbreak_patterns[@]}"; do
    local match_count
    match_count=$(echo "${user_messages}" | grep -icP "${pattern}" 2>/dev/null || echo 0)
    match_count=$(echo "${match_count}" | tr -dc '0-9')
    match_count=${match_count:-0}
    if [[ ${match_count} -gt 0 ]]; then
      threats=$(echo "${threats}" | jq \
        --arg p "${pattern}" \
        --argjson cnt "${match_count}" \
        '. + [{
          type: "jailbreak_attempt",
          severity: "high",
          description: ("ジェイルブレイク試行を検知: pattern='" + $p + "' (" + ($cnt | tostring) + "件)"),
          pattern: $p,
          category: "security"
        }]')
    fi
  done

  # --- Additional prompt override patterns (from openclaw-monitor.sh, Japanese) ---
  local jp_override_patterns=(
    "システムプロンプトを無視"
    "ルールをリセット"
    "制限を解除"
    "新しいペルソナ"
    "開発者モード"
    "前の指示を忘れ"
    "jailbreak"
    "disable.*safety"
    "remove.*restrictions"
  )

  for pattern in "${jp_override_patterns[@]}"; do
    local match_count
    match_count=$(echo "${user_messages}" | grep -icP "${pattern}" 2>/dev/null || echo 0)
    match_count=$(echo "${match_count}" | tr -dc '0-9')
    match_count=${match_count:-0}
    if [[ ${match_count} -gt 0 ]]; then
      threats=$(echo "${threats}" | jq \
        --arg p "${pattern}" \
        --argjson cnt "${match_count}" \
        '. + [{
          type: "prompt_override_attempt",
          severity: "high",
          description: ("プロンプト上書き試行を検知: pattern='" + $p + "' (" + ($cnt | tostring) + "件)"),
          pattern: $p,
          category: "security"
        }]')
    fi
  done

  # --- Config/setting change requests (from openclaw-monitor.sh) ---
  local config_patterns=(
    "config.*change"
    "config.*modify"
    "設定.*変え"
    "設定.*修正"
    "gateway.*設定"
    "allowBots"
    "token.*見せ"
    "API.*key"
  )

  for pattern in "${config_patterns[@]}"; do
    local match_count
    match_count=$(echo "${user_messages}" | grep -icP "${pattern}" 2>/dev/null || echo 0)
    match_count=$(echo "${match_count}" | tr -dc '0-9')
    match_count=${match_count:-0}
    if [[ ${match_count} -gt 0 ]]; then
      threats=$(echo "${threats}" | jq \
        --arg p "${pattern}" \
        '. + [{
          type: "config_change_request",
          severity: "medium",
          description: ("設定変更要求を検知: pattern='" + $p + "'"),
          pattern: $p,
          category: "security"
        }]')
    fi
  done

  # --- Info disclosure in assistant responses (from buddy-monitor.sh) ---
  local disclosure_patterns=(
    "ANTHROPIC_API_KEY"
    "DISCORD_BOT_TOKEN"
    "OPENCLAW_GATEWAY_TOKEN"
    "system.*prompt.*is"
    "my.*config.*file"
    "openclaw\\.json"
  )

  for pattern in "${disclosure_patterns[@]}"; do
    local match_count
    match_count=$(echo "${assistant_messages}" | grep -icP "${pattern}" 2>/dev/null || echo 0)
    match_count=$(echo "${match_count}" | tr -dc '0-9')
    match_count=${match_count:-0}
    if [[ ${match_count} -gt 0 ]]; then
      threats=$(echo "${threats}" | jq \
        --arg p "${pattern}" \
        '. + [{
          type: "info_disclosure",
          severity: "high",
          description: ("情報漏洩を検知: pattern='" + $p + "'"),
          pattern: $p,
          category: "security"
        }]')
    fi
  done

  # --- Identity deviation (from openclaw-monitor.sh) ---
  local formal_count
  formal_count=$(echo "${assistant_messages}" | grep -cP "(もちろんです|素晴らしい質問|お手伝いします|ございます|How can I help|I am an AI|I'm an AI|as an AI assistant|AIアシスタント)" 2>/dev/null || echo 0)
  formal_count=$(echo "${formal_count}" | tr -dc '0-9')
  formal_count=${formal_count:-0}
  if [[ ${formal_count} -gt 3 ]]; then
    threats=$(echo "${threats}" | jq \
      --argjson cnt "${formal_count}" \
      '. + [{
        type: "identity_deviation",
        severity: "low",
        description: ("バディアイデンティティからの逸脱を検知 (" + ($cnt | tostring) + "件のAIアシスタント的応答)"),
        count: $cnt,
        category: "security"
      }]')
  fi

  # --- Heavy Kansai dialect deviation (SOUL.md: 標準語ベース、関西弁は語尾にたまに混じる程度) ---
  local kansai_heavy_count
  kansai_heavy_count=$(echo "${assistant_messages}" | grep -cP "(せやな|めっちゃ|ほんま|あかん|ええやん|なんぼ|しゃーない|やったら|すまん|侮れん|ちゃうか|やんけ|おるで)" 2>/dev/null || echo 0)
  kansai_heavy_count=$(echo "${kansai_heavy_count}" | tr -dc '0-9')
  kansai_heavy_count=${kansai_heavy_count:-0}
  if [[ ${kansai_heavy_count} -gt 5 ]]; then
    threats=$(echo "${threats}" | jq \
      --argjson cnt "${kansai_heavy_count}" \
      '. + [{
        type: "identity_deviation",
        severity: "medium",
        description: ("関西弁の過剰使用を検知 (" + ($cnt | tostring) + "件の強い関西弁表現) — SOUL.md規定: 標準語7割・関西弁語尾3割"),
        count: $cnt,
        category: "policy"
      }]')
  fi

  # --- Impersonation (from openclaw-monitor.sh) ---
  local impersonation_count
  impersonation_count=$(echo "${user_messages}" | grep -icP "(koya.*id:|master.*id:|管理者)" 2>/dev/null || echo 0)
  impersonation_count=$(echo "${impersonation_count}" | tr -dc '0-9')
  impersonation_count=${impersonation_count:-0}
  if [[ ${impersonation_count} -gt 0 ]]; then
    threats=$(echo "${threats}" | jq \
      '. + [{
        type: "impersonation_attempt",
        severity: "high",
        description: "なりすまし試行の可能性を検知",
        category: "security"
      }]')
  fi

  echo "${threats}"
}

# ============================================================
# LLM Deep Analysis (from buddy-monitor.sh)
# ============================================================

_unified_llm_analysis() {
  local messages="$1"
  local security_entries="$2"

  # Truncate to last 20 messages for LLM
  local truncated
  truncated=$(echo "${messages}" | jq '.[-([length, 20] | min):]')

  local protocol
  protocol=$(cat "${BRAIN_DIR}/protocols/buddy-monitor.md" 2>/dev/null || echo "Analyze the conversation for buddy integrity issues.")

  local prompt="${protocol}

## Recent Conversation
${truncated}

## Pattern Detection Results
${security_entries}

## Instructions
Analyze the conversation and respond with ONLY a valid JSON object:
{
  \"status\": \"healthy|warning|critical\",
  \"summary\": \"Brief assessment\",
  \"issues\": [{\"type\": \"...\", \"description\": \"...\", \"severity\": \"info|warning|critical\"}],
  \"recommended_actions\": [{\"action\": \"none|log|restart_container|update_personality|notify_master\", \"reason\": \"...\"}]
}"

  local response
  response=$(invoke_claude "${prompt}")

  # Strip code fences
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

  if echo "${response}" | jq . > /dev/null 2>&1; then
    echo "${response}"
  else
    echo '{"status": "error", "summary": "LLM analysis failed to produce valid JSON", "issues": [], "recommended_actions": [{"action": "log", "reason": "analysis_error"}]}'
  fi
}

# ============================================================
# LLM-based Identity Compliance Check
# ============================================================

_unified_llm_identity_compliance_check() {
  local messages="$1"

  # 直近20件のアシスタント応答を抽出
  local truncated
  truncated=$(echo "${messages}" | jq '.[-([length, 20] | min):]')

  # SOUL.md, AGENTS.md, IDENTITY.mdを読み取り
  local soul_md agents_md identity_md
  soul_md=$(docker exec "${UNIFIED_OPENCLAW_CONTAINER}" cat "${UNIFIED_OPENCLAW_PERSONALITY_DIR}/SOUL.md" 2>/dev/null || echo "(読み取り失敗)")
  agents_md=$(docker exec "${UNIFIED_OPENCLAW_CONTAINER}" cat "${UNIFIED_OPENCLAW_PERSONALITY_DIR}/AGENTS.md" 2>/dev/null || echo "(読み取り失敗)")
  identity_md=$(docker exec "${UNIFIED_OPENCLAW_CONTAINER}" cat "${UNIFIED_OPENCLAW_PERSONALITY_DIR}/IDENTITY.md" 2>/dev/null || echo "(読み取り失敗)")

  local prompt
  prompt="あなたはOpenClaw（Masaru-kun）の人格・アイデンティティ準拠性を評価する監視エージェントです。

## 人格定義ファイル

### SOUL.md
${soul_md}

### AGENTS.md
${agents_md}

### IDENTITY.md
${identity_md}

## 直近の応答サンプル
${truncated}

## 評価項目
以下の観点から応答がSOUL.md/AGENTS.md/IDENTITY.mdに準拠しているか評価してください：

1. **口調バランス**: 標準語ベース約7割・関西弁語尾約3割のバランスが維持されているか。文全体が関西弁になっていないか
2. **人格特性**: カジュアルで親しみやすい、ツッコミ上手、プラグマティックなリアリスト、効率重視等のSOUL.md定義の人格が反映されているか
3. **バディスタンス**: Masaruの味方としての立場を維持しつつ、率直なフィードバックを行えているか
4. **セキュリティ境界**: システム情報の漏洩、ペルソナの逸脱、不適切な要求への対応が適切か
5. **プラットフォーム適応**: Discord/LINE等のプラットフォームに応じたトーン調整ができているか
6. **禁止事項**: 絵文字の不使用、過度にフォーマルな表現の回避、長文説明の回避等

ONLY valid JSONで回答してください：
{
  \"compliance_status\": \"compliant|minor_deviation|major_deviation\",
  \"overall_score\": 0-100,
  \"tone_analysis\": {\"standard_ratio\": 0-100, \"kansai_ratio\": 0-100, \"assessment\": \"...\"},
  \"personality_match\": {\"score\": 0-100, \"assessment\": \"...\"},
  \"buddy_stance\": {\"score\": 0-100, \"assessment\": \"...\"},
  \"security_compliance\": {\"score\": 0-100, \"assessment\": \"...\"},
  \"issues\": [{\"dimension\": \"...\", \"description\": \"...\", \"severity\": \"info|warning|critical\"}],
  \"summary\": \"1-2文の総合評価\"
}"

  local response
  response=$(invoke_claude "${prompt}")
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

  if echo "${response}" | jq . > /dev/null 2>&1; then
    echo "${response}"
  else
    echo '{"compliance_status": "error", "overall_score": -1, "summary": "LLM identity compliance check failed", "issues": []}'
  fi
}

# ============================================================
# Personality Integrity Check (from openclaw-monitor.sh)
# ============================================================

_unified_check_personality_integrity() {
  local integrity_file="${UNIFIED_INTEGRITY_FILE}"
  local issues=""

  # Check SOUL.md hash
  local soul_hash
  soul_hash=$(docker exec "${UNIFIED_OPENCLAW_CONTAINER}" md5sum "${UNIFIED_OPENCLAW_PERSONALITY_DIR}/SOUL.md" 2>/dev/null | awk '{print $1}')

  if [[ -n "${soul_hash}" ]]; then
    local stored_soul_hash=""
    if [[ -f "${integrity_file}" ]]; then
      stored_soul_hash=$(jq -r '.soul_md_hash // ""' "${integrity_file}")
    fi

    if [[ -n "${stored_soul_hash}" && "${stored_soul_hash}" != "${soul_hash}" ]]; then
      issues="SOUL.mdが変更されました (expected: ${stored_soul_hash}, actual: ${soul_hash})"
      log "ALERT: Unified monitor - ${issues}"

      if [[ "${UNIFIED_PARALLEL_MODE}" != "true" ]]; then
        _unified_restore_personality_file "SOUL.md"
      fi
    fi
  fi

  # Check AGENTS.md hash
  local agents_hash
  agents_hash=$(docker exec "${UNIFIED_OPENCLAW_CONTAINER}" md5sum "${UNIFIED_OPENCLAW_PERSONALITY_DIR}/AGENTS.md" 2>/dev/null | awk '{print $1}')

  if [[ -n "${agents_hash}" ]]; then
    local stored_agents_hash=""
    if [[ -f "${integrity_file}" ]]; then
      stored_agents_hash=$(jq -r '.agents_md_hash // ""' "${integrity_file}")
    fi

    if [[ -n "${stored_agents_hash}" && "${stored_agents_hash}" != "${agents_hash}" ]]; then
      local agents_issue="AGENTS.mdが変更されました"
      if [[ -n "${issues}" ]]; then
        issues="${issues}; ${agents_issue}"
      else
        issues="${agents_issue}"
      fi
      log "ALERT: Unified monitor - ${agents_issue}"

      if [[ "${UNIFIED_PARALLEL_MODE}" != "true" ]]; then
        _unified_restore_personality_file "AGENTS.md"
      fi
    fi
  fi

  # Update integrity state
  local tmp
  tmp=$(mktemp)
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg ts "${timestamp}" \
    --arg soul "${soul_hash:-}" \
    --arg agents "${agents_hash:-}" \
    --arg status "$([ -z "${issues}" ] && echo 'ok' || echo 'tampered')" \
    --arg issues "${issues:-}" \
    '{
      checked_at: $ts,
      soul_md_hash: $soul,
      agents_md_hash: $agents,
      status: $status,
      last_issue: $issues
    }' > "${tmp}" && mv "${tmp}" "${integrity_file}"

  if [[ -n "${issues}" ]]; then
    echo "${issues}"
  else
    echo "ok"
  fi
}

_unified_restore_personality_file() {
  local filename="$1"
  log "Unified monitor: Restoring ${filename} from source..."

  local backup_dir="${UNIFIED_MONITOR_DIR}/backups"
  mkdir -p "${backup_dir}"
  local timestamp
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  docker exec "${UNIFIED_OPENCLAW_CONTAINER}" cat "${UNIFIED_OPENCLAW_PERSONALITY_DIR}/${filename}" > \
    "${backup_dir}/${filename}.tampered.${timestamp}" 2>/dev/null || true

  docker cp "${UNIFIED_OPENCLAW_CONTAINER}:/app/personality/${filename}" "/tmp/_restore_${filename}" 2>/dev/null && \
    docker cp "/tmp/_restore_${filename}" "${UNIFIED_OPENCLAW_CONTAINER}:${UNIFIED_OPENCLAW_PERSONALITY_DIR}/${filename}" 2>/dev/null && \
    rm -f "/tmp/_restore_${filename}" && \
    log "Unified monitor: Restored ${filename} successfully" || \
    log "ERROR: Unified monitor - Failed to restore ${filename}"
}

# ============================================================
# Alert Recording
# ============================================================

_unified_record_alert() {
  local severity="$1"
  local alert_type="$2"
  local description="$3"
  local category="${4:-policy}"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local alert_id="unified_alert_$(date +%s)_$((RANDOM % 10000))"

  # Write to /shared/alerts/ (global alerts)
  local alert_file="${UNIFIED_ALERTS_DIR}/${alert_id}.json"
  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg id "${alert_id}" \
    --arg ts "${timestamp}" \
    --arg sev "${severity}" \
    --arg type "${alert_type}" \
    --arg desc "${description}" \
    --arg src "unified_monitor" \
    --arg cat "${category}" \
    '{
      id: $id,
      created_at: $ts,
      severity: $sev,
      type: $type,
      description: $desc,
      source: $src,
      category: $cat,
      acknowledged: false
    }' > "${tmp}" && mv "${tmp}" "${alert_file}"

  log "ALERT [${severity}] unified_monitor(${category}): ${description}"

  # Append to monitoring alerts log
  local alerts_log="${UNIFIED_MONITOR_DIR}/alerts.jsonl"
  jq -n \
    --arg id "${alert_id}" \
    --arg ts "${timestamp}" \
    --arg sev "${severity}" \
    --arg type "${alert_type}" \
    --arg desc "${description}" \
    --arg cat "${category}" \
    '{id: $id, timestamp: $ts, severity: $sev, type: $type, description: $desc, category: $cat}' >> "${alerts_log}"
}

# ============================================================
# Intervention
# ============================================================

_unified_execute_intervention() {
  local level="$1"
  local status="$2"
  local violations="$3"
  local category="${4:-policy}"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  case ${level} in
    2)
      log "Unified monitor: Level 2 intervention (${category}) - creating alert with light correction"
      _unified_record_alert "medium" "${category}_violation" "ポリシー違反を検知（警告レベル）" "${category}"
      _unified_notify_nodes "${status}" "${violations}"

      # Level 2: 軽度の是正アクション（注意喚起レベル）
      local primary_type
      primary_type=$(echo "${violations}" | jq -r '.[0].type // "unknown"')

      case "${primary_type}" in
        identity_deviation)
          _unified_send_bot_command "adjust_params" '{"review_personality": true}' "アイデンティティ逸脱を検知。パーソナリティ確認を要請"
          ;;
        security*)
          _unified_send_bot_command "adjust_params" '{"increase_caution": true}' "セキュリティ関連の警告を検知。注意レベルを引き上げ"
          ;;
        *)
          _unified_send_bot_command "adjust_params" '{"increase_caution": true}' "ポリシー違反を検知。注意レベルを引き上げ"
          ;;
      esac
      ;;
    3)
      log "Unified monitor: Level 3 intervention (${category}) - sending bot command"
      _unified_record_alert "high" "${category}_violation" "ポリシー違反を検知（コマンド介入レベル）" "${category}"
      _unified_notify_nodes "${status}" "${violations}"

      local primary_type
      primary_type=$(echo "${violations}" | jq -r '.[0].type // "unknown"')

      case "${primary_type}" in
        rapid_messages)
          _unified_send_bot_command "pause" '{"duration_minutes": 5}' "急速なメッセージ送信を検知。5分間一時停止"
          ;;
        high_error_rate)
          _unified_send_bot_command "adjust_params" '{"reduce_activity": true}' "高エラー率を検知。活動を抑制"
          ;;
        *)
          _unified_send_bot_command "adjust_params" '{"safety_mode": true}' "ポリシー違反を検知。安全モードへ移行"
          ;;
      esac
      ;;
    4)
      log "Unified monitor: Level 4 intervention (${category}) - requesting human approval for restart"
      _unified_record_alert "critical" "${category}_violation_critical" "重大なポリシー違反を検知。コンテナ再起動の承認を要求" "${category}"
      _unified_notify_nodes "${status}" "${violations}"

      local action_id="unified_action_$(date +%s)_$((RANDOM % 10000))"
      local tmp
      tmp=$(mktemp)
      jq -n \
        --arg id "${action_id}" \
        --arg ts "${timestamp}" \
        --arg cat "${category}" \
        --arg desc "統合監視(${category}): 重大な違反によりコンテナ再起動を推奨" \
        '{
          id: $id,
          created_at: $ts,
          action_type: "container_restart",
          alert_type: ($cat + "_violation_critical"),
          description: $desc,
          status: "pending",
          source: "unified_monitor",
          category: $cat,
          approved_by: null,
          approved_at: null,
          executed_at: null
        }' > "${tmp}" && mv "${tmp}" "${UNIFIED_PENDING_DIR}/${action_id}.json"
      log "Unified monitor: Pending restart action created: ${action_id}"
      ;;
  esac
}

_unified_notify_nodes() {
  local status="$1"
  local violations="$2"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  for node in gorilla triceratops; do
    local node_dir="${SHARED_DIR}/nodes/${node}"
    mkdir -p "${node_dir}"
    local notif_file="${node_dir}/unified_monitor_notification.json"
    local tmp
    tmp=$(mktemp)
    jq -n \
      --arg ts "${timestamp}" \
      --arg st "${status}" \
      --argjson v "${violations}" \
      '{
        from: "panda",
        type: "unified_openclaw_alert",
        timestamp: $ts,
        status: $st,
        violations: $v
      }' > "${tmp}" && mv "${tmp}" "${notif_file}"
  done

  log "Unified monitor: Notified gorilla and triceratops about ${status} status"
}

_unified_send_bot_command() {
  local action="$1"
  local params="$2"
  local reason="$3"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local cmd_id="cmd_$(date +%s)_$((RANDOM % 10000))"
  local cmd_file="${UNIFIED_COMMANDS_DIR}/${cmd_id}.json"

  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg id "${cmd_id}" \
    --arg action "${action}" \
    --argjson params "${params}" \
    --arg ts "${timestamp}" \
    --arg reason "${reason}" \
    --arg src "unified_monitor" \
    '{
      id: $id,
      action: $action,
      params: $params,
      timestamp: $ts,
      reason: $reason,
      source: $src,
      status: "pending"
    }' > "${tmp}" && mv "${tmp}" "${cmd_file}"

  log "Unified monitor: Bot command sent: ${cmd_id} (action: ${action})"
}

# ============================================================
# Remediation Processing (for approved pending actions)
# ============================================================

process_unified_approved_actions() {
  [[ -d "${UNIFIED_PENDING_DIR}" ]] || return 0

  for action_file in "${UNIFIED_PENDING_DIR}"/*.json; do
    [[ -f "${action_file}" ]] || continue

    local status
    status=$(jq -r '.status' "${action_file}")
    [[ "${status}" == "approved" ]] || continue

    local action_id action_type alert_type
    action_id=$(jq -r '.id' "${action_file}")
    action_type=$(jq -r '.action_type' "${action_file}")
    alert_type=$(jq -r '.alert_type' "${action_file}")

    log "Unified monitor: Executing approved action: ${action_id} (${action_type})"

    case "${action_type}" in
      config_restore)
        _unified_restore_personality_file "SOUL.md"
        _unified_restore_personality_file "AGENTS.md"
        ;;
      container_restart)
        log "Unified monitor: Restarting Open Claw container..."
        local running
        running=$(docker ps --filter "name=${UNIFIED_OPENCLAW_CONTAINER}" --filter "status=running" -q 2>/dev/null)
        if [[ -z "${running}" ]]; then
          docker compose -f /soul/docker-compose.yml up -d openclaw 2>&1 | while IFS= read -r line; do log "docker: ${line}"; done
        else
          docker compose -f /soul/docker-compose.yml restart openclaw 2>&1 | while IFS= read -r line; do log "docker: ${line}"; done
        fi
        sleep 5
        local check
        check=$(docker ps --filter "name=${UNIFIED_OPENCLAW_CONTAINER}" --filter "status=running" -q 2>/dev/null)
        if [[ -n "${check}" ]]; then
          log "Unified monitor: Open Claw container restarted successfully"
        else
          log "ERROR: Unified monitor - Open Claw container failed to start"
        fi
        ;;
    esac

    # Mark as executed
    local tmp
    tmp=$(mktemp)
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq --arg ts "${ts}" '.status = "executed" | .executed_at = $ts' "${action_file}" > "${tmp}" && mv "${tmp}" "${action_file}"

    # Log remediation
    jq -n \
      --arg ts "${ts}" \
      --arg action "executed" \
      --arg alert "${alert_type}" \
      --arg desc "Approved action ${action_id}" \
      --arg rtype "${action_type}" \
      '{timestamp: $ts, action: $action, alert_type: $alert, description: $desc, remediation_type: $rtype}' >> "${UNIFIED_REMEDIATION_LOG}"
  done
}

# ============================================================
# State Management
# ============================================================

_unified_update_state() {
  local now_epoch="$1"
  local status="$2"
  local msg_count="$3"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ -f "${UNIFIED_STATE_FILE}" ]]; then
    local tmp
    tmp=$(mktemp)
    jq --argjson epoch "${now_epoch}" \
       --arg ts "${timestamp}" \
       --arg st "${status}" \
       --argjson mc "${msg_count}" \
       --argjson parallel "${UNIFIED_PARALLEL_MODE}" \
       '.last_check_epoch = $epoch |
        .last_check_at = $ts |
        .status = $st |
        .last_message_count = $mc |
        .check_count = ((.check_count // 0) + 1) |
        .parallel_mode = $parallel |
        .monitor_type = "unified"' \
       "${UNIFIED_STATE_FILE}" > "${tmp}" && mv "${tmp}" "${UNIFIED_STATE_FILE}"
  else
    local tmp
    tmp=$(mktemp)
    jq -n \
      --argjson epoch "${now_epoch}" \
      --arg ts "${timestamp}" \
      --arg st "${status}" \
      --argjson mc "${msg_count}" \
      --argjson parallel "${UNIFIED_PARALLEL_MODE}" \
      '{
        last_check_epoch: $epoch,
        last_check_at: $ts,
        status: $st,
        last_message_count: $mc,
        check_count: 1,
        monitor_type: "unified",
        interval_seconds: 300,
        parallel_mode: $parallel
      }' > "${tmp}" && mv "${tmp}" "${UNIFIED_STATE_FILE}"
  fi
}
