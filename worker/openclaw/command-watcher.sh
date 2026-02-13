#!/usr/bin/env bash
# command-watcher.sh - Watches /bot_commands/ for instructions from Brain nodes
# Runs as a background process alongside the OpenClaw gateway
# Polls every 10 seconds for new command files

COMMANDS_DIR="/bot_commands"
POLL_INTERVAL=10

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [command-watcher] $*"
}

process_command() {
  local cmd_file="$1"
  [[ -f "${cmd_file}" ]] || return 0

  # Skip trigger files handled directly by Brain nodes (not command-watcher)
  local basename
  basename=$(basename "${cmd_file}")
  case "${basename}" in
    personality_manual_trigger.json|personality_rollback_trigger.json|personality_answer.json)
      return 0
      ;;
  esac

  local status
  status=$(jq -r '.status // ""' "${cmd_file}" 2>/dev/null)
  [[ "${status}" == "pending" ]] || return 0

  local cmd_id action reason
  cmd_id=$(jq -r '.id // "unknown"' "${cmd_file}")
  action=$(jq -r '.action // ""' "${cmd_file}")
  reason=$(jq -r '.reason // ""' "${cmd_file}")

  log "Processing command: ${cmd_id} (action: ${action}, reason: ${reason})"

  local result="success"
  local result_detail=""

  case "${action}" in
    pause)
      local duration
      duration=$(jq -r '.params.duration_minutes // 5' "${cmd_file}")
      log "Pausing activity for ${duration} minutes"
      # Create a pause marker file that OpenClaw can check
      local pause_until
      pause_until=$(date -u -d "+${duration} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                    date -u +%Y-%m-%dT%H:%M:%SZ)
      echo "{\"paused_until\": \"${pause_until}\", \"reason\": \"${reason}\"}" > /tmp/openclaw-pause.json
      result_detail="Paused until ${pause_until}"
      ;;
    resume)
      log "Resuming activity"
      rm -f /tmp/openclaw-pause.json
      result_detail="Pause cleared"
      ;;
    adjust_params)
      local params
      params=$(jq -r '.params // {}' "${cmd_file}")
      log "Adjusting parameters: ${params}"
      # Store parameter adjustments for OpenClaw to pick up
      echo "${params}" > /tmp/openclaw-adjusted-params.json
      result_detail="Parameters adjusted"
      ;;
    restart)
      log "Restart requested - this will be handled by container orchestration"
      result="acknowledged"
      result_detail="Restart must be executed externally via docker"
      ;;
    personality_questions)
      process_personality_questions "${cmd_file}"
      result=$?
      if [[ ${result} -eq 0 ]]; then
        result="success"
        result_detail="Personality questions sent via LINE"
      else
        result="error"
        result_detail="Failed to send personality questions"
      fi
      ;;
    *)
      log "Unknown action: ${action}"
      result="error"
      result_detail="Unknown action: ${action}"
      ;;
  esac

  # Mark command as processed
  local tmp
  tmp=$(mktemp)
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg st "processed" --arg ts "${ts}" --arg res "${result}" --arg det "${result_detail}" \
    '.status = $st | .processed_at = $ts | .result = $res | .result_detail = $det' \
    "${cmd_file}" > "${tmp}" && mv "${tmp}" "${cmd_file}"

  log "Command ${cmd_id} processed: ${result} - ${result_detail}"
}

# ============================================================
# Personality Questions Handler
# ============================================================

process_personality_questions() {
  local cmd_file="$1"

  local line_token="${LINE_CHANNEL_ACCESS_TOKEN:-}"
  local owner_line_id="${OWNER_LINE_ID:-Ua78c97ab5f7b6090fc17656bc12f5c99}"

  if [[ -z "${line_token}" ]]; then
    log "ERROR: LINE_CHANNEL_ACCESS_TOKEN not set, cannot send personality questions"
    return 1
  fi

  # Extract questions from command
  local questions
  questions=$(jq -r '.params.questions' "${cmd_file}" 2>/dev/null)

  if [[ -z "${questions}" || "${questions}" == "null" ]]; then
    log "ERROR: No questions found in personality command"
    return 1
  fi

  local pending_file
  pending_file=$(jq -r '.params.pending_file // ""' "${cmd_file}" 2>/dev/null)

  local analysis
  analysis=$(jq -r '.params.analysis // ""' "${cmd_file}" 2>/dev/null)

  # Format questions for LINE message
  local message="パーソナリティ改善の質問です！
おれのことをもっと正確に再現するために、以下の質問に答えてくれ。番号付きで回答してくれると助かる（例: 1. 回答内容）

"

  local i=0
  while true; do
    local q
    q=$(echo "${questions}" | jq -r ".[${i}].question // empty" 2>/dev/null)
    [[ -z "${q}" ]] && break
    local qnum=$((i + 1))
    message="${message}${qnum}. ${q}
"
    ((i++))
  done

  message="${message}
※回答は番号付きでお願いします
※全問じゃなくても答えられる分だけでOK
※48時間以内に回答してください"

  # Send via LINE Push API
  local payload
  payload=$(jq -n \
    --arg to "${owner_line_id}" \
    --arg text "${message}" \
    '{
      to: $to,
      messages: [{
        type: "text",
        text: $text
      }]
    }')

  local http_code response_body
  response_body=$(mktemp)
  http_code=$(curl -s -o "${response_body}" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${line_token}" \
    -d "${payload}" \
    "https://api.line.me/v2/bot/message/push" 2>/dev/null) || {
    log "ERROR: LINE Push API request failed"
    rm -f "${response_body}"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Personality questions sent to Masaru via LINE (HTTP ${http_code})"
    rm -f "${response_body}"

    # Write a marker file so Brain knows questions were sent
    # Include the timestamp for answer matching
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local marker_tmp
    marker_tmp=$(mktemp)
    jq -n \
      --arg ts "${ts}" \
      --arg pending_file "${pending_file}" \
      --argjson questions "${questions}" \
      --arg question_count "${i}" \
      '{
        status: "questions_sent",
        sent_at: $ts,
        pending_file: $pending_file,
        questions: $questions,
        question_count: ($question_count | tonumber),
        answers_collected: 0
      }' > "${marker_tmp}" && mv "${marker_tmp}" "${COMMANDS_DIR}/personality_q_status.json"

    return 0
  else
    log "ERROR: LINE Push API returned HTTP ${http_code}: $(cat "${response_body}")"
    rm -f "${response_body}"
    return 1
  fi
}

main() {
  log "Command watcher starting (poll interval: ${POLL_INTERVAL}s)"
  mkdir -p "${COMMANDS_DIR}"

  while true; do
    for cmd_file in "${COMMANDS_DIR}"/*.json; do
      [[ -f "${cmd_file}" ]] || continue
      process_command "${cmd_file}"
    done

    # Clean up old processed commands (older than 1 hour, except status files)
    find "${COMMANDS_DIR}" -name "*.json" ! -name "*_status.json" -mmin +60 -exec rm -f {} \; 2>/dev/null || true

    sleep "${POLL_INTERVAL}"
  done
}

main
