#!/usr/bin/env bash
# watcher.sh - Shared folder monitoring functions

ALL_NODES=("panda" "gorilla" "triceratops")

get_other_nodes() {
  local others=()
  for node in "${ALL_NODES[@]}"; do
    if [[ "${node}" != "${NODE_NAME}" ]]; then
      others+=("${node}")
    fi
  done
  echo "${others[@]}"
}

check_inbox() {
  local inbox_dir="${SHARED_DIR}/inbox"
  for task_file in "${inbox_dir}"/*.json; do
    [[ -f "${task_file}" ]] || continue

    local task_id
    task_id=$(jq -r '.id' "${task_file}")
    local discussion_dir="${SHARED_DIR}/discussions/${task_id}"

    # Skip if discussion already exists for this task
    if [[ -d "${discussion_dir}" ]]; then
      continue
    fi

    log "New task detected: ${task_id}"
    start_discussion "${task_file}" "${task_id}"
  done
}

# Unified: check_pending_discussions + check_consensus_needed in a single directory scan
check_discussions_unified() {
  local discussions_dir="${SHARED_DIR}/discussions"
  for discussion_dir in "${discussions_dir}"/*/; do
    [[ -d "${discussion_dir}" ]] || continue

    local task_id
    task_id=$(basename "${discussion_dir}")
    local status_file="${discussion_dir}/status.json"

    [[ -f "${status_file}" ]] || continue

    # Single jq call to read both status and current_round
    local status_data
    status_data=$(jq -r '[.status, (.current_round | tostring)] | @tsv' "${status_file}" 2>/dev/null) || continue
    local status current_round
    status=$(echo "${status_data}" | cut -f1)
    current_round=$(echo "${status_data}" | cut -f2)

    # Skip completed or executing discussions
    if [[ "${status}" == "decided" || "${status}" == "executing" ]]; then
      continue
    fi

    local round_dir="${discussion_dir}/round_${current_round}"

    # Part 1: Check if we need to respond (was check_pending_discussions)
    local my_response="${round_dir}/${NODE_NAME}.json"
    if [[ ! -f "${my_response}" ]]; then
      log "Responding to discussion ${task_id} round ${current_round}"
      respond_to_discussion "${task_id}" "${current_round}"
      # After responding, don't check consensus in the same cycle (let next poll pick it up)
      continue
    fi

    # Part 2: Check if consensus is needed (was check_consensus_needed)
    [[ "${status}" == "discussing" ]] || continue

    local response_count=0
    for node in "${ALL_NODES[@]}"; do
      if [[ -f "${round_dir}/${node}.json" ]]; then
        ((response_count++))
      fi
    done

    if [[ ${response_count} -eq ${#ALL_NODES[@]} ]]; then
      # Only triceratops runs consensus (as chairperson who renders final decisions)
      if [[ "${NODE_NAME}" == "triceratops" ]]; then
        log "All nodes responded in round ${current_round} for ${task_id}, checking consensus"
        evaluate_consensus "${task_id}" "${current_round}"
      fi
    fi
  done
}

# Legacy wrappers (kept for compatibility, now both delegate to unified)
check_pending_discussions() { check_discussions_unified; }
check_consensus_needed() { :; }  # No-op: handled by check_discussions_unified

# Unified: check_pending_announcements + check_pending_decisions in a single directory scan
check_decisions_unified() {
  local decisions_dir="${SHARED_DIR}/decisions"
  for decision_file in "${decisions_dir}"/*.json; do
    [[ -f "${decision_file}" ]] || continue
    # Skip non-decision files
    [[ "${decision_file}" != *_result.json ]] || continue
    [[ "${decision_file}" != *_history.json ]] || continue
    [[ "${decision_file}" != *_review.json ]] || continue
    [[ "${decision_file}" != *_progress.jsonl ]] || continue
    [[ "${decision_file}" != *_announce_progress.jsonl ]] || continue

    # Single jq call to read all needed fields at once
    local decision_data
    decision_data=$(jq -r '[.status, .task_id, (.executor // ""), (.execution_started_at // ""), (.announcement.announced_at // "")] | @tsv' "${decision_file}" 2>/dev/null) || continue
    local decision_status task_id executor execution_started_at announced_at
    decision_status=$(echo "${decision_data}" | cut -f1)
    task_id=$(echo "${decision_data}" | cut -f2)
    executor=$(echo "${decision_data}" | cut -f3)
    execution_started_at=$(echo "${decision_data}" | cut -f4)
    announced_at=$(echo "${decision_data}" | cut -f5)

    # --- Announcement handling (triceratops only) ---
    if [[ "${decision_status}" == "pending_announcement" && "${NODE_NAME}" == "triceratops" ]]; then
      log "Announcing decision for task: ${task_id}"
      announce_decision "${decision_file}"
      continue
    elif [[ "${decision_status}" == "announcing" && "${NODE_NAME}" == "triceratops" ]]; then
      # Check if already announced (has announced_at timestamp)
      if [[ -n "${announced_at}" ]]; then
        log "Task ${task_id} has announced_at but status is announcing, marking as announced"
        local tmp
        tmp=$(mktemp)
        jq '.status = "announced"' "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
        continue
      fi
      # Retry announcement if it was interrupted
      log "Retrying interrupted announcement for task: ${task_id}"
      announce_decision "${decision_file}"
      continue
    fi

    # --- Execution handling ---
    if [[ "${decision_status}" == "announced" ]]; then
      if [[ -z "${executor}" || "${executor}" == "${NODE_NAME}" ]]; then
        log "Executing decision for task: ${task_id}"
        execute_decision "${decision_file}"
      fi
    elif [[ "${decision_status}" == "executing" ]]; then
      if [[ -z "${executor}" || "${executor}" == "${NODE_NAME}" ]]; then

        # Check if result file already exists (task completed but status not updated)
        local result_file="${decisions_dir}/${task_id}_result.json"
        if [[ -f "${result_file}" ]]; then
          log "Task ${task_id} has result file but status is executing, marking as reviewing"
          local tmp
          tmp=$(mktemp)
          jq '.status = "reviewing" | .executed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
            "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
          continue
        fi

        # Only retry if execution started more than 5 minutes ago (avoid re-executing active tasks)
        if [[ -n "${execution_started_at}" ]]; then
          local start_epoch current_epoch age_seconds
          start_epoch=$(date -d "${execution_started_at}" +%s 2>/dev/null || echo 0)
          current_epoch=$(date +%s)
          age_seconds=$((current_epoch - start_epoch))

          # Skip if task was started less than 5 minutes ago (300 seconds)
          if [[ ${age_seconds} -lt 300 ]]; then
            continue
          fi

          # Skip if task is older than 2 hours (7200 seconds) - likely stale/failed
          if [[ ${age_seconds} -gt 7200 ]]; then
            log "Task ${task_id} execution started ${age_seconds}s ago (>2h), marking as failed"
            tmp=$(mktemp)
            jq '.status = "failed" | .failed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .failure_reason = "execution timeout (>2h)"' \
              "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
            continue
          fi
        fi

        log "Retrying stale execution for task: ${task_id} (started ${age_seconds}s ago)"
        execute_decision "${decision_file}"
      fi

    # --- Review handling (panda only) ---
    elif [[ "${decision_status}" == "reviewing" && "${NODE_NAME}" == "panda" ]]; then
      log "Reviewing execution for task: ${task_id}"
      review_execution "${decision_file}"

    # --- Remediation handling (executor only) ---
    elif [[ "${decision_status}" == "remediating" ]]; then
      if [[ -z "${executor}" || "${executor}" == "${NODE_NAME}" ]]; then
        log "Remediating task: ${task_id}"
        remediate_execution "${decision_file}"
      fi
    fi
  done
}

# Legacy wrappers (kept for compatibility, now both delegate to unified)
check_pending_announcements() { check_decisions_unified; }
check_pending_decisions() { :; }  # No-op: handled by check_decisions_unified

check_openclaw_suggestions() {
  # Only triceratops picks up OpenClaw suggestions
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  local suggestions_dir="/openclaw-suggestions"
  [[ -d "${suggestions_dir}" ]] || return 0

  # OWNER_DISCORD_ID is required for approval verification
  if [[ -z "${OWNER_DISCORD_ID:-}" ]]; then
    return 0
  fi

  for approval_file in "${suggestions_dir}"/approval_pending_suggestion_*.json; do
    [[ -f "${approval_file}" ]] || continue

    local approval_filename
    approval_filename=$(basename "${approval_file}")

    # Read approval response (single jq call for all fields)
    local approval_data suggestion_filename decision discord_user_id
    approval_data=$(jq -r '[(.suggestion_file // ""), (.decision // ""), (.discord_user_id // "")] | @tsv' "${approval_file}" 2>/dev/null) || continue
    suggestion_filename=$(printf '%s' "${approval_data}" | cut -f1)
    decision=$(printf '%s' "${approval_data}" | cut -f2)
    discord_user_id=$(printf '%s' "${approval_data}" | cut -f3)

    # Validate approval response
    if [[ -z "${suggestion_filename}" || -z "${decision}" || -z "${discord_user_id}" ]]; then
      log "OpenClaw approval ${approval_filename}: missing required fields, discarding"
      rm -f "${approval_file}"
      continue
    fi

    local suggestion_file="${suggestions_dir}/${suggestion_filename}"

    # Verify Discord user ID matches owner (NEVER trust display names)
    if [[ "${discord_user_id}" != "${OWNER_DISCORD_ID}" ]]; then
      log "OpenClaw approval REJECTED: Discord user ID mismatch (got: ${discord_user_id}, expected: ${OWNER_DISCORD_ID})"
      rm -f "${approval_file}"
      rm -f "${suggestion_file}"
      continue
    fi

    # Handle rejection
    if [[ "${decision}" == "reject" ]]; then
      log "OpenClaw suggestion rejected by owner: ${suggestion_filename}"
      rm -f "${approval_file}"
      rm -f "${suggestion_file}"
      continue
    fi

    # Handle approval — verify pending suggestion file exists
    if [[ "${decision}" != "approve" ]]; then
      log "OpenClaw approval ${approval_filename}: invalid decision '${decision}', discarding"
      rm -f "${approval_file}"
      continue
    fi

    if [[ ! -f "${suggestion_file}" ]]; then
      log "OpenClaw approval ${approval_filename}: pending suggestion not found, discarding"
      rm -f "${approval_file}"
      continue
    fi

    # Read and validate suggestion content (single jq call)
    local suggestion_data title description
    suggestion_data=$(jq -r '[(.title // ""), (.description // "")] | @tsv' "${suggestion_file}" 2>/dev/null) || {
      log "OpenClaw suggestion ${suggestion_filename}: failed to parse, discarding"
      rm -f "${approval_file}" "${suggestion_file}"
      continue
    }
    title=$(printf '%s' "${suggestion_data}" | cut -f1)
    description=$(printf '%s' "${suggestion_data}" | cut -f2)

    if [[ -z "${title}" ]]; then
      log "OpenClaw suggestion ${suggestion_filename}: missing title, discarding"
      rm -f "${approval_file}" "${suggestion_file}"
      continue
    fi

    # Sanitize: truncate long inputs
    title="${title:0:200}"
    description="${description:0:2000}"

    # Duplicate check: skip if an [OpenClaw] task with the same title already exists
    local openclaw_title="[OpenClaw] ${title}"
    local duplicate_found=false

    # Batch extract all inbox titles with single jq call, then grep for match
    local inbox_titles
    inbox_titles=$(cat "${SHARED_DIR}/inbox"/*.json 2>/dev/null | jq -r '.title // empty' 2>/dev/null || echo '')
    if echo "${inbox_titles}" | grep -qxF "${openclaw_title}"; then
      duplicate_found=true
    fi

    # Batch extract all decision titles (filter auxiliary files via glob, single jq call)
    if [[ "${duplicate_found}" == "false" ]]; then
      local decision_titles _bn
      decision_titles=$(for f in "${SHARED_DIR}/decisions"/task_*.json; do
        [[ -f "$f" ]] || continue
        _bn=$(basename "$f")
        [[ "$_bn" != *_result.json && "$_bn" != *_history.json ]] || continue
        cat "$f"
      done | jq -r '.title // empty' 2>/dev/null || echo '')
      if echo "${decision_titles}" | grep -qxF "${openclaw_title}"; then
        duplicate_found=true
      fi
    fi

    if [[ "${duplicate_found}" == "true" ]]; then
      log "OpenClaw suggestion duplicate detected, skipping: ${title}"
      rm -f "${approval_file}" "${suggestion_file}"
      continue
    fi

    # Generate task ID and register as inbox task
    local now_epoch ts rand task_id now_ts
    now_epoch=$(date +%s)
    ts="${now_epoch}"
    rand=$((RANDOM % 9000 + 1000))
    task_id="task_${ts}_${rand}"
    now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local task_json
    task_json=$(jq -n \
      --arg id "${task_id}" \
      --arg title "[OpenClaw] ${title}" \
      --arg desc "${description:-${title}}" \
      --arg created "${now_ts}" \
      '{
        id: $id,
        type: "task",
        title: $title,
        description: $desc,
        priority: "low",
        source: "openclaw",
        created_at: $created,
        status: "pending"
      }')

    # Write task to inbox atomically
    local inbox_file="${SHARED_DIR}/inbox/${task_id}.json"
    local tmp_inbox
    tmp_inbox=$(mktemp)
    echo "${task_json}" > "${tmp_inbox}"
    mv "${tmp_inbox}" "${inbox_file}"

    # Log suggestion record (include approval details)
    local suggestion_record
    suggestion_record=$(jq -n \
      --arg id "${task_id}" \
      --arg title "${title}" \
      --arg desc "${description}" \
      --arg task_id "${task_id}" \
      --arg created "${now_ts}" \
      --arg approved_by "${discord_user_id}" \
      '{
        id: $id,
        title: $title,
        description: $desc,
        task_id: $task_id,
        source: "openclaw-approved",
        approved_by_discord_id: $approved_by,
        created_at: $created
      }')

    local suggestions_log_dir="${SHARED_DIR}/openclaw/suggestions"
    mkdir -p "${suggestions_log_dir}"
    local tmp_sugg
    tmp_sugg=$(mktemp)
    echo "${suggestion_record}" > "${tmp_sugg}"
    mv "${tmp_sugg}" "${suggestions_log_dir}/${task_id}.json"

    # Remove processed files
    rm -f "${approval_file}" "${suggestion_file}"

    log "OpenClaw suggestion approved by owner (${discord_user_id}), registered as task ${task_id}: ${title}"
  done

  # Clean up stale pending suggestions without approval (older than 24 hours)
  for pending_file in "${suggestions_dir}"/pending_suggestion_*.json; do
    [[ -f "${pending_file}" ]] || continue
    local file_age
    file_age=$(( $(date +%s) - $(stat -c %Y "${pending_file}" 2>/dev/null || echo 0) ))
    if [[ ${file_age} -gt 86400 ]]; then
      log "Cleaning up stale pending suggestion: $(basename "${pending_file}")"
      rm -f "${pending_file}"
    fi
  done
}

check_openclaw_research_requests() {
  # Only triceratops picks up OpenClaw research requests
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  local suggestions_dir="/openclaw-suggestions"
  [[ -d "${suggestions_dir}" ]] || return 0

  for request_file in "${suggestions_dir}"/research_request_*.json; do
    [[ -f "${request_file}" ]] || continue

    local request_filename
    request_filename=$(basename "${request_file}")

    # Read all fields in single jq call
    local request_data status req_type title description reply_to
    request_data=$(jq -r '[(.status // ""), (.type // ""), (.title // ""), (.description // ""), (.reply_to // "")] | @tsv' "${request_file}" 2>/dev/null) || continue
    status=$(printf '%s' "${request_data}" | cut -f1)
    req_type=$(printf '%s' "${request_data}" | cut -f2)
    title=$(printf '%s' "${request_data}" | cut -f3)
    description=$(printf '%s' "${request_data}" | cut -f4)
    reply_to=$(printf '%s' "${request_data}" | cut -f5)

    # Skip already-submitted requests
    [[ "${status}" == "pending" ]] || continue

    # Validate type (research/design only)
    case "${req_type}" in
      research|design) ;;
      *)
        log "OpenClaw research request ${request_filename}: invalid type '${req_type}', discarding"
        rm -f "${request_file}"
        continue
        ;;
    esac

    # Validate title
    if [[ -z "${title}" ]]; then
      log "OpenClaw research request ${request_filename}: missing title, discarding"
      rm -f "${request_file}"
      continue
    fi

    # Validate description length
    if [[ "${#description}" -lt 10 ]]; then
      log "OpenClaw research request ${request_filename}: description too short, discarding"
      rm -f "${request_file}"
      continue
    fi

    # Sanitize: truncate long inputs
    title="${title:0:200}"
    description="${description:0:2000}"

    # Duplicate check (batch jq extraction)
    local openclaw_title="[OpenClaw Research] ${title}"
    local duplicate_found=false

    # Batch extract all inbox titles with single jq call
    local inbox_titles
    inbox_titles=$(cat "${SHARED_DIR}/inbox"/*.json 2>/dev/null | jq -r '.title // empty' 2>/dev/null || echo '')
    if echo "${inbox_titles}" | grep -qxF "${openclaw_title}"; then
      duplicate_found=true
    fi

    # Batch extract all decision titles (filter auxiliary files via glob, single jq call)
    if [[ "${duplicate_found}" == "false" ]]; then
      local decision_titles _bn
      decision_titles=$(for f in "${SHARED_DIR}/decisions"/task_*.json; do
        [[ -f "$f" ]] || continue
        _bn=$(basename "$f")
        [[ "$_bn" != *_result.json && "$_bn" != *_history.json ]] || continue
        cat "$f"
      done | jq -r '.title // empty' 2>/dev/null || echo '')
      if echo "${decision_titles}" | grep -qxF "${openclaw_title}"; then
        duplicate_found=true
      fi
    fi

    if [[ "${duplicate_found}" == "true" ]]; then
      log "OpenClaw research request duplicate detected, skipping: ${title}"
      # Mark as duplicate instead of deleting
      local tmp_dup
      tmp_dup=$(mktemp)
      jq --arg st "duplicate" '.status = $st' "${request_file}" > "${tmp_dup}" && mv "${tmp_dup}" "${request_file}"
      continue
    fi

    # Generate task ID and register as inbox task
    local now_epoch ts rand task_id now_ts
    now_epoch=$(date +%s)
    ts="${now_epoch}"
    rand=$((RANDOM % 9000 + 1000))
    task_id="task_${ts}_${rand}"
    now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local task_json
    task_json=$(jq -n \
      --arg id "${task_id}" \
      --arg title "[OpenClaw Research] ${title}" \
      --arg desc "${description}" \
      --arg req_type "${req_type}" \
      --arg created "${now_ts}" \
      --arg reply_to "${reply_to}" \
      '{
        id: $id,
        type: "task",
        title: $title,
        description: $desc,
        priority: "low",
        source: "openclaw",
        request_type: $req_type,
        created_at: $created,
        status: "pending"
      } | if $reply_to != "" then . + {reply_to: $reply_to} else . end')

    # Write task to inbox atomically
    local inbox_file="${SHARED_DIR}/inbox/${task_id}.json"
    local tmp_inbox
    tmp_inbox=$(mktemp)
    echo "${task_json}" > "${tmp_inbox}"
    mv "${tmp_inbox}" "${inbox_file}"

    # Update request file with task_id and submitted status
    local tmp_req
    tmp_req=$(mktemp)
    jq --arg st "submitted" --arg tid "${task_id}" --arg ts "${now_ts}" \
      '.status = $st | .task_id = $tid | .submitted_at_brain = $ts' \
      "${request_file}" > "${tmp_req}" && mv "${tmp_req}" "${request_file}"

    log "OpenClaw research request registered as task ${task_id}: [${req_type}] ${title}"
  done

  # Write back results for completed research tasks
  for request_file in "${suggestions_dir}"/research_request_*.json; do
    [[ -f "${request_file}" ]] || continue

    local req_data2 status task_id
    req_data2=$(jq -r '[(.status // ""), (.task_id // "")] | @tsv' "${request_file}" 2>/dev/null) || continue
    status=$(printf '%s' "${req_data2}" | cut -f1)
    task_id=$(printf '%s' "${req_data2}" | cut -f2)
    [[ "${status}" == "submitted" && -n "${task_id}" ]] || continue

    # Check if result exists
    local result_file="${SHARED_DIR}/decisions/${task_id}_result.json"
    [[ -f "${result_file}" ]] || continue

    # Check if we already wrote the result back
    local result_out="${suggestions_dir}/research_result_${task_id}.json"
    [[ -f "${result_out}" ]] && continue

    # Read decision and result (batch jq calls: 2 files, 1 call each)
    local decision_file="${SHARED_DIR}/decisions/${task_id}.json"
    local dec_data decision approach
    dec_data=$(jq -r '[(.decision // "unknown"), (.agreed_approach // "")] | @tsv' "${decision_file}" 2>/dev/null) || dec_data="unknown	"
    decision=$(printf '%s' "${dec_data}" | cut -f1)
    approach=$(printf '%s' "${dec_data}" | cut -f2)
    local res_data result_summary completed_at
    res_data=$(jq -r '[(.summary // .result // ""), (.completed_at // "")] | @tsv' "${result_file}" 2>/dev/null) || res_data="	"
    result_summary=$(printf '%s' "${res_data}" | cut -f1)
    completed_at=$(printf '%s' "${res_data}" | cut -f2)

    # Write result to suggestions dir for OpenClaw to read
    local tmp_result
    tmp_result=$(mktemp)
    jq -n \
      --arg tid "${task_id}" \
      --arg decision "${decision}" \
      --arg approach "${approach}" \
      --arg summary "${result_summary}" \
      --arg completed "${completed_at}" \
      '{
        task_id: $tid,
        decision: $decision,
        approach: $approach,
        result_summary: $summary,
        completed_at: $completed
      }' > "${tmp_result}" && mv "${tmp_result}" "${result_out}"

    # Update request status to completed
    local tmp_req
    tmp_req=$(mktemp)
    jq --arg st "completed" '.status = $st' "${request_file}" > "${tmp_req}" && mv "${tmp_req}" "${request_file}"

    log "OpenClaw research result written back for task ${task_id}"

    # Send LINE notification for completed research
    _notify_research_result_line "${task_id}" "${request_file}" "${result_summary}"
  done
}

# Send LINE notification when a research task completes
_notify_research_result_line() {
  local task_id="$1"
  local request_file="$2"
  local result_summary="$3"

  local line_token="${LINE_CHANNEL_ACCESS_TOKEN:-}"
  local owner_line_id="${OWNER_LINE_ID:-Ua78c97ab5f7b6090fc17656bc12f5c99}"

  # Use reply_to from request file if available (group ID or user ID)
  local reply_to
  reply_to=$(jq -r '.reply_to // ""' "${request_file}" 2>/dev/null)
  if [[ -z "${reply_to}" ]]; then
    # Fallback: check the inbox task for reply_to
    local inbox_task="${SHARED_DIR}/inbox/${task_id}.json"
    reply_to=$(jq -r '.reply_to // ""' "${inbox_task}" 2>/dev/null)
  fi
  if [[ -z "${reply_to}" ]]; then
    # Fallback: check the discussion task.json for reply_to
    local disc_task="${SHARED_DIR}/discussions/${task_id}/task.json"
    reply_to=$(jq -r '.reply_to // ""' "${disc_task}" 2>/dev/null)
  fi
  # Use reply_to if available, otherwise fall back to owner DM
  local destination="${reply_to:-${owner_line_id}}"

  if [[ -z "${line_token}" ]]; then
    log "WARN: LINE_CHANNEL_ACCESS_TOKEN not set, skipping research result notification"
    return 0
  fi

  # Get task title from request file or discussion
  local title
  title=$(jq -r '.title // ""' "${request_file}" 2>/dev/null)
  if [[ -z "${title}" ]]; then
    local task_json="${SHARED_DIR}/discussions/${task_id}/task.json"
    title=$(jq -r '.title // "調査タスク"' "${task_json}" 2>/dev/null || echo "調査タスク")
  fi

  # Build summary from result or workspace report
  local summary="${result_summary}"
  if [[ -z "${summary}" || "${summary}" == "null" || "${summary}" =~ ^不要 ]]; then
    # Try to read from the full result file
    local full_result
    full_result=$(jq -r '.result // ""' "${SHARED_DIR}/decisions/${task_id}_result.json" 2>/dev/null)
    if [[ -n "${full_result}" && "${full_result}" != "null" ]]; then
      summary="${full_result}"
    else
      summary="調査完了。詳細はWeb UIで確認してください。"
    fi
  fi

  # Truncate for LINE (max ~4000 chars for text message, keep to 1500 for readability)
  if [[ ${#summary} -gt 1500 ]]; then
    summary="${summary:0:1497}..."
  fi

  local message="調査完了通知

タスク: ${title}
ID: ${task_id}

${summary}

詳細はWeb UIの「Decisions」から確認できます。"

  # LINE text message max is 5000 chars
  if [[ ${#message} -gt 4900 ]]; then
    message="${message:0:4897}..."
  fi

  local payload
  payload=$(jq -n \
    --arg to "${destination}" \
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
    log "ERROR: LINE Push API request failed for research notification"
    rm -f "${response_body}"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Research result notification sent via LINE (HTTP ${http_code}, dest=${destination}) for task ${task_id}"
    rm -f "${response_body}"
    return 0
  else
    log "ERROR: LINE Push API returned HTTP ${http_code} for research notification: $(cat "${response_body}")"
    rm -f "${response_body}"
    return 1
  fi
}

check_evaluation_requests() {
  local evaluations_dir="${SHARED_DIR}/evaluations"
  for eval_dir in "${evaluations_dir}"/*/; do
    [[ -d "${eval_dir}" ]] || continue

    local cycle_id
    cycle_id=$(basename "${eval_dir}")

    # Early skip: if result.json exists, this cycle is already completed
    [[ ! -f "${eval_dir}/result.json" ]] || continue

    local request_file="${eval_dir}/request.json"

    [[ -f "${request_file}" ]] || continue

    # Quick status check via grep (avoids jq startup for non-matching cycles)
    grep -qE '"status"\s*:\s*"(pending|in_progress)"' "${request_file}" || continue

    # Check if we already submitted our evaluations
    local other_nodes
    read -ra other_nodes <<< "$(get_other_nodes)"
    local all_done=true
    for target in "${other_nodes[@]}"; do
      if [[ ! -f "${eval_dir}/${NODE_NAME}_evaluates_${target}.json" ]]; then
        all_done=false
        break
      fi
    done

    if [[ "${all_done}" == "false" ]]; then
      log "Evaluation cycle ${cycle_id}: submitting evaluations"
      run_evaluation "${cycle_id}"
    elif [[ "${NODE_NAME}" == "gorilla" ]]; then
      # All our evaluations are submitted; check if all 6 evaluations are in
      # and process results if so (gorilla is the coordinator for result processing)
      check_evaluation_results "${cycle_id}"
    fi
  done
}

# --- Stuck task recovery (triceratops only) ---

check_stuck_tasks() {
  # Triceratops only (executor/chairperson)
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  local stuck_dir="${SHARED_DIR}/stuck_tasks"
  [[ -d "${stuck_dir}" ]] || return 0

  for stuck_file in "${stuck_dir}"/*.json; do
    [[ -f "${stuck_file}" ]] || continue

    local stuck_data task_id current_status recommended_action source_file
    stuck_data=$(jq -r '[.task_id, .current_status, .recommended_action, .source_file] | @tsv' "${stuck_file}" 2>/dev/null) || continue
    task_id=$(echo "${stuck_data}" | cut -f1)
    current_status=$(echo "${stuck_data}" | cut -f2)
    recommended_action=$(echo "${stuck_data}" | cut -f3)
    source_file=$(echo "${stuck_data}" | cut -f4)

    # ソースファイルが存在しない場合は通知を削除
    if [[ ! -f "${source_file}" ]]; then
      log "STUCK_RECOVERY: ${task_id} source file gone, removing notification"
      rm -f "${stuck_file}"
      continue
    fi

    # 現在のステータスが変わっていれば既に解決済み
    local actual_status
    actual_status=$(jq -r '.status' "${source_file}" 2>/dev/null)
    if [[ "${actual_status}" != "${current_status}" ]]; then
      log "STUCK_RECOVERY: ${task_id} status changed (${current_status}→${actual_status}), resolved"
      rm -f "${stuck_file}"
      continue
    fi

    log "STUCK_RECOVERY: Handling ${task_id} (status=${current_status}, action=${recommended_action})"

    case "${recommended_action}" in
      retry_review)
        # reviewingステータスのまま → panda次ポーリングで再処理される
        log "STUCK_RECOVERY: ${task_id} review stuck, panda will retry on next poll"
        rm -f "${stuck_file}"
        ;;
      retry_remediation)
        # remediatingステータスのまま → executorが再処理
        log "STUCK_RECOVERY: ${task_id} remediation stuck, retrying"
        remediate_execution "${source_file}"
        rm -f "${stuck_file}"
        ;;
      retry_announcement)
        # pending_announcement → announce_decision再実行
        log "STUCK_RECOVERY: ${task_id} announcement stuck, retrying"
        announce_decision "${source_file}"
        rm -f "${stuck_file}"
        ;;
      retry_execution)
        # announced → execute_decision再実行
        log "STUCK_RECOVERY: ${task_id} execution stuck, retrying"
        execute_decision "${source_file}"
        rm -f "${stuck_file}"
        ;;
      escalate_discussion)
        # 2h+膠着 → LLMで打開策判断
        _escalate_stuck_discussion "${task_id}" "${source_file}" "${stuck_file}"
        ;;
      *)
        log "STUCK_RECOVERY: Unknown action '${recommended_action}' for ${task_id}"
        rm -f "${stuck_file}"
        ;;
    esac
  done
}

_escalate_stuck_discussion() {
  local task_id="$1" status_file="$2" stuck_file="$3"
  local discussion_dir
  discussion_dir=$(dirname "${status_file}")

  # 議論履歴を収集
  local history=""
  local current_round
  current_round=$(jq -r '.current_round' "${status_file}" 2>/dev/null)
  for (( r=0; r<=current_round; r++ )); do
    local round_dir="${discussion_dir}/round_${r}"
    [[ -d "${round_dir}" ]] || continue
    for node_file in "${round_dir}"/*.json; do
      [[ -f "${node_file}" ]] || continue
      local node_name
      node_name=$(basename "${node_file}" .json)
      local opinion
      opinion=$(jq -r '.response // .opinion // ""' "${node_file}" 2>/dev/null)
      history+="[Round ${r}] ${node_name}: ${opinion}

"
    done
  done

  local task_title
  task_title=$(jq -r '.title // ""' "${discussion_dir}/task.json" 2>/dev/null)

  local prompt="以下のタスク議論が2時間以上膠着しています。議長として打開策を決定してください。

タスク: ${task_title} (${task_id})
現在のラウンド: ${current_round}

議論履歴:
${history}

以下のいずれかの行動を選び、JSON形式で回答してください:
1. force_decide: 議長権限で最も合理的なアプローチを採用し決定する
2. new_round: 新しい論点を提示して追加ラウンドを開始する
3. reject: このタスクを却下する

回答形式: {\"action\": \"force_decide|new_round|reject\", \"reason\": \"理由\", \"approach\": \"採用するアプローチ(force_decideの場合)\"}"

  local response
  response=$(invoke_claude "${prompt}" 2>/dev/null) || {
    log "STUCK_RECOVERY: LLM escalation failed for ${task_id}"
    rm -f "${stuck_file}"
    return 1
  }

  local action
  action=$(echo "${response}" | jq -r '.action // "unknown"' 2>/dev/null)

  case "${action}" in
    force_decide)
      local approach
      approach=$(echo "${response}" | jq -r '.approach // ""' 2>/dev/null)
      log "STUCK_RECOVERY: Force deciding ${task_id}: ${approach}"
      finalize_decision "${task_id}" "approved" "${approach}" "" "triceratops"
      ;;
    new_round)
      local new_round=$(( current_round + 1 ))
      local tmp
      tmp=$(mktemp)
      jq --argjson r "${new_round}" '.current_round = $r' "${status_file}" > "${tmp}" && mv "${tmp}" "${status_file}"
      mkdir -p "${discussion_dir}/round_${new_round}"
      log "STUCK_RECOVERY: Starting new round ${new_round} for ${task_id}"
      ;;
    reject)
      local reason
      reason=$(echo "${response}" | jq -r '.reason // "膠着タイムアウト"' 2>/dev/null)
      log "STUCK_RECOVERY: Rejected stuck discussion ${task_id}"
      finalize_decision "${task_id}" "rejected" "" "${reason}" "triceratops"
      ;;
    *)
      log "STUCK_RECOVERY: LLM returned unknown action '${action}' for ${task_id}"
      ;;
  esac

  rm -f "${stuck_file}"
}
