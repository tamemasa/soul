#!/usr/bin/env bash
# buddy-monitor.sh - OpenClaw conversation monitoring for buddy integrity
#
# Monitors OpenClaw's conversation history to detect:
# - Persona compromise (jailbreak, social engineering)
# - Configuration tampering attempts
# - Behavioral drift from buddy identity
#
# Only triceratops runs this check (as executor node).

OPENCLAW_HOME="/openclaw"
OPENCLAW_SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"
BUDDY_STATE_DIR="${SHARED_DIR}/buddy"
BUDDY_MONITOR_INTERVAL=900  # 15 minutes in seconds
OPENCLAW_CONTAINER="soul-openclaw"
OPENCLAW_REMOTE_SESSIONS="/home/openclaw/.openclaw/agents/main/sessions"

# Initialize buddy monitoring state directory
init_buddy_monitor() {
  mkdir -p "${BUDDY_STATE_DIR}"
  if [[ ! -f "${BUDDY_STATE_DIR}/state.json" ]]; then
    cat > "${BUDDY_STATE_DIR}/state.json" <<'EOF'
{
  "last_check_at": null,
  "last_session_id": null,
  "last_message_count": 0,
  "status": "healthy",
  "alerts": [],
  "check_count": 0
}
EOF
  fi
}

# Check if we can access openclaw sessions directly (volume mount) or need docker exec
has_direct_access() {
  [[ -d "${OPENCLAW_SESSIONS_DIR}" ]]
}

# Get the most recent active session file (returns path or "docker:<filename>" for remote)
get_active_session() {
  if has_direct_access; then
    # Direct volume access
    local latest=""
    local latest_time=0
    for f in "${OPENCLAW_SESSIONS_DIR}"/*.jsonl; do
      [[ -f "$f" ]] || continue
      local mtime
      mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
      if [[ ${mtime} -gt ${latest_time} ]]; then
        latest="$f"
        latest_time=${mtime}
      fi
    done
    echo "${latest}"
  else
    # Fallback: use docker exec to list sessions
    local files
    files=$(docker exec "${OPENCLAW_CONTAINER}" ls -t "${OPENCLAW_REMOTE_SESSIONS}"/*.jsonl 2>/dev/null | head -1)
    if [[ -n "${files}" ]]; then
      echo "docker:${files}"
    else
      echo ""
    fi
  fi
}

# Read session file content (handles both direct and docker exec access)
read_session_content() {
  local session_ref="$1"
  local filter="${2:-}"

  if [[ "${session_ref}" == docker:* ]]; then
    local remote_path="${session_ref#docker:}"
    if [[ -n "${filter}" ]]; then
      docker exec "${OPENCLAW_CONTAINER}" grep "${filter}" "${remote_path}" 2>/dev/null
    else
      docker exec "${OPENCLAW_CONTAINER}" cat "${remote_path}" 2>/dev/null
    fi
  else
    if [[ -f "${session_ref}" ]]; then
      if [[ -n "${filter}" ]]; then
        grep "${filter}" "${session_ref}" 2>/dev/null
      else
        cat "${session_ref}"
      fi
    fi
  fi
}

# Count messages in a session
count_session_messages() {
  local session_ref="$1"
  local count
  count=$(read_session_content "${session_ref}" '"type":"message"' | wc -l 2>/dev/null)
  echo "${count:-0}"
}

# Extract recent conversation messages (user + assistant) from a session file
# Returns last N message pairs as JSON
extract_recent_messages() {
  local session_ref="$1"
  local max_messages="${2:-20}"

  # Extract message-type entries, get the last N
  read_session_content "${session_ref}" '"type":"message"' | tail -n "${max_messages}" | \
    jq -s '[.[] | {
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

# Check if enough time has passed since last monitoring check
should_check_now() {
  local state_file="${BUDDY_STATE_DIR}/state.json"
  if [[ ! -f "${state_file}" ]]; then
    return 0
  fi

  local last_check
  last_check=$(jq -r '.last_check_at // ""' "${state_file}")
  if [[ -z "${last_check}" || "${last_check}" == "null" ]]; then
    return 0
  fi

  local last_epoch current_epoch elapsed
  last_epoch=$(date -d "${last_check}" +%s 2>/dev/null || echo 0)
  current_epoch=$(date +%s)
  elapsed=$((current_epoch - last_epoch))

  if [[ ${elapsed} -ge ${BUDDY_MONITOR_INTERVAL} ]]; then
    return 0
  fi
  return 1
}

# Run pattern-based quick check (no LLM, fast)
run_pattern_check() {
  local messages_json="$1"
  local alerts="[]"

  # Check for jailbreak/persona override attempts in user messages
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

  local user_messages
  user_messages=$(echo "${messages_json}" | jq -r '[.[] | select(.role == "user") | .content] | join("\n")')

  for pattern in "${jailbreak_patterns[@]}"; do
    if echo "${user_messages}" | grep -iqP "${pattern}" 2>/dev/null; then
      alerts=$(echo "${alerts}" | jq --arg p "${pattern}" '. + [{"type": "jailbreak_attempt", "pattern": $p, "severity": "warning"}]')
    fi
  done

  # Check for config/system disclosure in assistant responses
  local disclosure_patterns=(
    "ANTHROPIC_API_KEY"
    "DISCORD_BOT_TOKEN"
    "OPENCLAW_GATEWAY_TOKEN"
    "system.*prompt.*is"
    "my.*config.*file"
    "openclaw\.json"
  )

  local assistant_messages
  assistant_messages=$(echo "${messages_json}" | jq -r '[.[] | select(.role == "assistant") | .content] | join("\n")')

  for pattern in "${disclosure_patterns[@]}"; do
    if echo "${assistant_messages}" | grep -iqP "${pattern}" 2>/dev/null; then
      alerts=$(echo "${alerts}" | jq --arg p "${pattern}" '. + [{"type": "info_disclosure", "pattern": $p, "severity": "critical"}]')
    fi
  done

  # Check for persona drift (assistant using formal/non-buddy language excessively)
  local formal_count
  formal_count=$(echo "${assistant_messages}" | grep -cP "(もちろんです|素晴らしい質問|お手伝いします|ございます|How can I help)" 2>/dev/null || echo 0)
  if [[ ${formal_count} -gt 3 ]]; then
    alerts=$(echo "${alerts}" | jq '. + [{"type": "persona_drift", "pattern": "excessive_formal_language", "severity": "info", "count": '"${formal_count}"'}]')
  fi

  echo "${alerts}"
}

# Run LLM-based deep analysis (for suspicious patterns detected)
run_llm_analysis() {
  local messages_json="$1"
  local pattern_alerts="$2"

  # Truncate messages to avoid token overflow (keep last 10 exchanges)
  local truncated
  truncated=$(echo "${messages_json}" | jq '.[- [length, 20] | min:]')

  local protocol
  protocol=$(cat "${BRAIN_DIR}/protocols/buddy-monitor.md" 2>/dev/null || echo "Analyze the conversation for buddy integrity issues.")

  local prompt="${protocol}

## Recent Conversation
${truncated}

## Pattern Detection Results
${pattern_alerts}

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

# Execute recommended actions from analysis
execute_buddy_actions() {
  local analysis="$1"
  local actions
  actions=$(echo "${analysis}" | jq -r '.recommended_actions // []')
  local action_count
  action_count=$(echo "${actions}" | jq 'length')

  for ((i=0; i<action_count; i++)); do
    local action reason
    action=$(echo "${actions}" | jq -r ".[$i].action")
    reason=$(echo "${actions}" | jq -r ".[$i].reason")

    case "${action}" in
      none|log)
        log "Buddy monitor: action=${action}, reason=${reason}"
        ;;
      restart_container)
        log "Buddy monitor: Restarting openclaw container (reason: ${reason})"
        cd /soul && docker compose restart openclaw 2>&1 | while read -r line; do
          log "Buddy restart: ${line}"
        done
        ;;
      update_personality)
        log "Buddy monitor: Personality update recommended (reason: ${reason})"
        # Personality updates require deploying new files and restarting
        # For now, restart to re-deploy from source files
        cd /soul && docker compose restart openclaw 2>&1 | while read -r line; do
          log "Buddy personality redeploy: ${line}"
        done
        ;;
      notify_master)
        log "Buddy monitor: ALERT - Master notification needed (reason: ${reason})"
        # Store alert for dashboard visibility
        ;;
    esac
  done
}

# Main monitoring check function (called from daemon loop)
check_openclaw_health() {
  # Only triceratops monitors openclaw
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  init_buddy_monitor

  # Check if it's time to monitor
  if ! should_check_now; then
    return 0
  fi

  # Check if openclaw is accessible (either volume mount or docker exec)
  if ! has_direct_access; then
    # Try docker exec fallback
    if ! docker exec "${OPENCLAW_CONTAINER}" test -d "${OPENCLAW_REMOTE_SESSIONS}" 2>/dev/null; then
      log "WARN: OpenClaw sessions not accessible (no volume mount and docker exec failed)"
      return 0
    fi
  fi

  local session_file
  session_file=$(get_active_session)
  if [[ -z "${session_file}" ]]; then
    log "Buddy monitor: No active session found"
    # Update state
    local tmp
    tmp=$(mktemp)
    jq '.last_check_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .check_count += 1' \
      "${BUDDY_STATE_DIR}/state.json" > "${tmp}" && mv "${tmp}" "${BUDDY_STATE_DIR}/state.json"
    return 0
  fi

  set_activity "monitoring" "\"target\":\"openclaw\","

  # Count current messages
  local current_msg_count
  current_msg_count=$(count_session_messages "${session_file}")

  # Check if new messages since last check
  local last_msg_count
  last_msg_count=$(jq -r '.last_message_count // 0' "${BUDDY_STATE_DIR}/state.json")

  if [[ ${current_msg_count} -eq ${last_msg_count} ]]; then
    log "Buddy monitor: No new messages (count: ${current_msg_count})"
    local tmp
    tmp=$(mktemp)
    jq '.last_check_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .check_count += 1' \
      "${BUDDY_STATE_DIR}/state.json" > "${tmp}" && mv "${tmp}" "${BUDDY_STATE_DIR}/state.json"
    set_activity "idle"
    return 0
  fi

  log "Buddy monitor: Checking ${current_msg_count} messages (${last_msg_count} previously checked)"

  # Derive session_id for reporting
  local session_id
  local session_path="${session_file#docker:}"
  session_id=$(basename "${session_path}" .jsonl)

  # Extract recent messages
  local messages
  messages=$(extract_recent_messages "${session_file}" 30)

  # Phase 1: Pattern-based quick check
  local pattern_alerts
  pattern_alerts=$(run_pattern_check "${messages}")
  local alert_count
  alert_count=$(echo "${pattern_alerts}" | jq 'length')

  local analysis_status="healthy"
  local analysis_result=""

  if [[ ${alert_count} -gt 0 ]]; then
    log "Buddy monitor: ${alert_count} pattern alerts detected, running LLM analysis"

    # Phase 2: LLM deep analysis (only when patterns detected)
    analysis_result=$(run_llm_analysis "${messages}" "${pattern_alerts}")
    analysis_status=$(echo "${analysis_result}" | jq -r '.status // "error"')

    # Save analysis report
    local report_file="${BUDDY_STATE_DIR}/report_$(date -u +%Y%m%d_%H%M%S).json"
    cat > "${report_file}" <<EOF
{
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "session_file": "${session_id}",
  "message_count": ${current_msg_count},
  "pattern_alerts": ${pattern_alerts},
  "llm_analysis": ${analysis_result}
}
EOF

    # Execute recommended actions if critical
    if [[ "${analysis_status}" == "critical" ]]; then
      log "Buddy monitor: CRITICAL status detected, executing actions"
      execute_buddy_actions "${analysis_result}"
    elif [[ "${analysis_status}" == "warning" ]]; then
      log "Buddy monitor: WARNING status detected"
    fi

    # Keep only last 50 reports
    local report_count
    report_count=$(ls -1 "${BUDDY_STATE_DIR}"/report_*.json 2>/dev/null | wc -l)
    if [[ ${report_count} -gt 50 ]]; then
      ls -1t "${BUDDY_STATE_DIR}"/report_*.json | tail -n +51 | xargs rm -f
    fi
  else
    log "Buddy monitor: No pattern alerts, conversation looks healthy"
  fi

  # Update state
  local tmp
  tmp=$(mktemp)
  jq --arg sid "${session_id}" --arg status "${analysis_status}" \
    '.last_check_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" |
     .last_session_id = $sid |
     .last_message_count = '"${current_msg_count}"' |
     .status = $status |
     .check_count += 1' \
    "${BUDDY_STATE_DIR}/state.json" > "${tmp}" && mv "${tmp}" "${BUDDY_STATE_DIR}/state.json"

  set_activity "idle"
  log "Buddy monitor: Check complete (status: ${analysis_status})"
}
