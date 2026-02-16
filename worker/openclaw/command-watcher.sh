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
    personality_manual_trigger*.json|personality_rollback_trigger*.json|personality_answer*.json|personality_external_trigger*.json|personality_external_answer*.json|personality_freeform_trigger*.json|personality_external_freeform_trigger*.json|line_pending_*.json)
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

  local owner_line_id="${OWNER_LINE_ID:-Ua78c97ab5f7b6090fc17656bc12f5c99}"

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

  # Write to pending file instead of Push API
  local line_pending="/bot_commands/line_pending_${owner_line_id}.json"
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local msg_id="msg_$(date +%s)_${RANDOM}"

  local new_msg
  new_msg=$(jq -n \
    --arg id "${msg_id}" \
    --arg text "${message}" \
    --arg source "personality_questions" \
    --arg created_at "${now_ts}" \
    '{id: $id, text: $text, source: $source, created_at: $created_at}')

  local tmp
  tmp=$(mktemp)

  if [[ -f "${line_pending}" ]]; then
    jq --argjson new_msg "${new_msg}" --arg ts "${now_ts}" \
      '.pending_messages += [$new_msg] | .updated_at = $ts' \
      "${line_pending}" > "${tmp}" && chmod 666 "${tmp}" && mv "${tmp}" "${line_pending}"
  else
    jq -n \
      --arg target_id "${owner_line_id}" \
      --argjson new_msg "${new_msg}" \
      --arg ts "${now_ts}" \
      '{target_id: $target_id, pending_messages: [$new_msg], updated_at: $ts}' \
      > "${tmp}" && chmod 666 "${tmp}" && mv "${tmp}" "${line_pending}"
  fi

  log "Personality questions written to pending file for ${owner_line_id} (${msg_id})"

  # Write a marker file so Brain knows questions are pending delivery
  local marker_tmp
  marker_tmp=$(mktemp)
  jq -n \
    --arg ts "${now_ts}" \
    --arg pending_file "${pending_file}" \
    --argjson questions "${questions}" \
    --arg question_count "${i}" \
    '{
      status: "questions_pending_delivery",
      sent_at: $ts,
      pending_file: $pending_file,
      questions: $questions,
      question_count: ($question_count | tonumber),
      answers_collected: 0
    }' > "${marker_tmp}" && mv "${marker_tmp}" "${COMMANDS_DIR}/personality_q_status.json"

  return 0
}

main() {
  log "Command watcher starting (poll interval: ${POLL_INTERVAL}s)"
  mkdir -p "${COMMANDS_DIR}"

  while true; do
    for cmd_file in "${COMMANDS_DIR}"/*.json; do
      [[ -f "${cmd_file}" ]] || continue
      process_command "${cmd_file}"
    done

    # Clean up old processed commands (older than 1 hour, except status and pending files)
    find "${COMMANDS_DIR}" -name "*.json" ! -name "*_status.json" ! -name "line_pending_*.json" -mmin +60 -exec rm -f {} \; 2>/dev/null || true

    sleep "${POLL_INTERVAL}"
  done
}

main
