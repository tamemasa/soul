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

check_pending_discussions() {
  local discussions_dir="${SHARED_DIR}/discussions"
  for discussion_dir in "${discussions_dir}"/*/; do
    [[ -d "${discussion_dir}" ]] || continue

    local task_id
    task_id=$(basename "${discussion_dir}")
    local status_file="${discussion_dir}/status.json"

    [[ -f "${status_file}" ]] || continue

    local status current_round
    status=$(jq -r '.status' "${status_file}")
    current_round=$(jq -r '.current_round' "${status_file}")

    # Skip completed or executing discussions
    if [[ "${status}" == "decided" || "${status}" == "executing" ]]; then
      continue
    fi

    local round_dir="${discussion_dir}/round_${current_round}"
    local my_response="${round_dir}/${NODE_NAME}.json"

    # Skip if we already responded this round
    if [[ -f "${my_response}" ]]; then
      continue
    fi

    log "Responding to discussion ${task_id} round ${current_round}"
    respond_to_discussion "${task_id}" "${current_round}"
  done
}

check_consensus_needed() {
  local discussions_dir="${SHARED_DIR}/discussions"
  for discussion_dir in "${discussions_dir}"/*/; do
    [[ -d "${discussion_dir}" ]] || continue

    local task_id
    task_id=$(basename "${discussion_dir}")
    local status_file="${discussion_dir}/status.json"

    [[ -f "${status_file}" ]] || continue

    local status current_round
    status=$(jq -r '.status' "${status_file}")
    current_round=$(jq -r '.current_round' "${status_file}")

    [[ "${status}" == "discussing" ]] || continue

    local round_dir="${discussion_dir}/round_${current_round}"

    # Check if all nodes have responded
    local response_count=0
    for node in "${ALL_NODES[@]}"; do
      if [[ -f "${round_dir}/${node}.json" ]]; then
        ((response_count++))
      fi
    done

    if [[ ${response_count} -eq ${#ALL_NODES[@]} ]]; then
      # Only triceratops runs consensus (as chairperson who renders final decisions)
      # This prevents duplicate consensus checks
      if [[ "${NODE_NAME}" == "triceratops" ]]; then
        log "All nodes responded in round ${current_round} for ${task_id}, checking consensus"
        evaluate_consensus "${task_id}" "${current_round}"
      fi
    fi
  done
}

check_pending_announcements() {
  # Only triceratops handles announcements
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  local decisions_dir="${SHARED_DIR}/decisions"
  for decision_file in "${decisions_dir}"/*.json; do
    [[ -f "${decision_file}" ]] || continue
    # Skip non-decision files
    [[ "${decision_file}" != *_result.json ]] || continue
    [[ "${decision_file}" != *_history.json ]] || continue
    [[ "${decision_file}" != *_progress.jsonl ]] || continue
    [[ "${decision_file}" != *_announce_progress.jsonl ]] || continue

    local decision_status
    decision_status=$(jq -r '.status' "${decision_file}")

    # Pick up pending announcements
    if [[ "${decision_status}" == "pending_announcement" ]]; then
      local task_id
      task_id=$(jq -r '.task_id' "${decision_file}")
      log "Announcing decision for task: ${task_id}"
      announce_decision "${decision_file}"
    # Handle stale announcing status (container restart recovery)
    elif [[ "${decision_status}" == "announcing" ]]; then
      local task_id announced_at
      task_id=$(jq -r '.task_id' "${decision_file}")
      announced_at=$(jq -r '.announcement.announced_at // ""' "${decision_file}")

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
    fi
  done
}

check_pending_decisions() {
  local decisions_dir="${SHARED_DIR}/decisions"
  for decision_file in "${decisions_dir}"/*.json; do
    [[ -f "${decision_file}" ]] || continue
    # Skip non-decision files
    [[ "${decision_file}" != *_result.json ]] || continue
    [[ "${decision_file}" != *_history.json ]] || continue
    [[ "${decision_file}" != *_progress.jsonl ]] || continue
    [[ "${decision_file}" != *_announce_progress.jsonl ]] || continue

    local decision_status executor
    decision_status=$(jq -r '.status' "${decision_file}")
    executor=$(jq -r '.executor // ""' "${decision_file}")

    # Execute announced decisions
    if [[ "${decision_status}" == "announced" ]]; then
      if [[ -z "${executor}" || "${executor}" == "${NODE_NAME}" ]]; then
        local task_id
        task_id=$(jq -r '.task_id' "${decision_file}")
        log "Executing decision for task: ${task_id}"
        execute_decision "${decision_file}"
      fi
    # Handle stale executing decisions (container restart recovery)
    elif [[ "${decision_status}" == "executing" ]]; then
      if [[ -z "${executor}" || "${executor}" == "${NODE_NAME}" ]]; then
        local task_id execution_started_at
        task_id=$(jq -r '.task_id' "${decision_file}")
        execution_started_at=$(jq -r '.execution_started_at // ""' "${decision_file}")

        # Check if result file already exists (task completed but status not updated)
        local result_file="${decisions_dir}/${task_id}_result.json"
        if [[ -f "${result_file}" ]]; then
          log "Task ${task_id} has result file but status is executing, marking as completed"
          local tmp
          tmp=$(mktemp)
          jq '.status = "completed" | .completed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
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
    fi
  done
}

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

    # Read approval response
    local suggestion_filename decision discord_user_id
    suggestion_filename=$(jq -r '.suggestion_file // ""' "${approval_file}" 2>/dev/null)
    decision=$(jq -r '.decision // ""' "${approval_file}" 2>/dev/null)
    discord_user_id=$(jq -r '.discord_user_id // ""' "${approval_file}" 2>/dev/null)

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

    # Read and validate suggestion content
    local title description
    title=$(jq -r '.title // ""' "${suggestion_file}" 2>/dev/null)
    description=$(jq -r '.description // ""' "${suggestion_file}" 2>/dev/null)

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

    # Check inbox tasks
    for existing_task in "${SHARED_DIR}/inbox"/*.json; do
      [[ -f "${existing_task}" ]] || continue
      local existing_title
      existing_title=$(jq -r '.title // ""' "${existing_task}" 2>/dev/null)
      if [[ "${existing_title}" == "${openclaw_title}" ]]; then
        duplicate_found=true
        break
      fi
    done

    # Check decisions (in-progress, executing, completed, etc.)
    if [[ "${duplicate_found}" == "false" ]]; then
      for existing_decision in "${SHARED_DIR}/decisions"/*.json; do
        [[ -f "${existing_decision}" ]] || continue
        # Skip auxiliary files
        local dec_basename
        dec_basename=$(basename "${existing_decision}")
        [[ "${dec_basename}" != *_result.json ]] || continue
        [[ "${dec_basename}" != *_history.json ]] || continue
        [[ "${dec_basename}" != *_progress.jsonl ]] || continue
        [[ "${dec_basename}" != *_announce_progress.jsonl ]] || continue

        local existing_title
        existing_title=$(jq -r '.title // ""' "${existing_decision}" 2>/dev/null)
        if [[ "${existing_title}" == "${openclaw_title}" ]]; then
          duplicate_found=true
          break
        fi
      done
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

    # Skip already-submitted requests
    local status
    status=$(jq -r '.status // ""' "${request_file}" 2>/dev/null)
    [[ "${status}" == "pending" ]] || continue

    # Read and validate request content
    local req_type title description
    req_type=$(jq -r '.type // ""' "${request_file}" 2>/dev/null)
    title=$(jq -r '.title // ""' "${request_file}" 2>/dev/null)
    description=$(jq -r '.description // ""' "${request_file}" 2>/dev/null)

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

    # Duplicate check
    local openclaw_title="[OpenClaw Research] ${title}"
    local duplicate_found=false

    for existing_task in "${SHARED_DIR}/inbox"/*.json; do
      [[ -f "${existing_task}" ]] || continue
      local existing_title
      existing_title=$(jq -r '.title // ""' "${existing_task}" 2>/dev/null)
      if [[ "${existing_title}" == "${openclaw_title}" ]]; then
        duplicate_found=true
        break
      fi
    done

    if [[ "${duplicate_found}" == "false" ]]; then
      for existing_decision in "${SHARED_DIR}/decisions"/*.json; do
        [[ -f "${existing_decision}" ]] || continue
        local dec_basename
        dec_basename=$(basename "${existing_decision}")
        [[ "${dec_basename}" != *_result.json ]] || continue
        [[ "${dec_basename}" != *_history.json ]] || continue
        [[ "${dec_basename}" != *_progress.jsonl ]] || continue
        [[ "${dec_basename}" != *_announce_progress.jsonl ]] || continue

        local existing_title
        existing_title=$(jq -r '.title // ""' "${existing_decision}" 2>/dev/null)
        if [[ "${existing_title}" == "${openclaw_title}" ]]; then
          duplicate_found=true
          break
        fi
      done
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
      }')

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

    local status task_id
    status=$(jq -r '.status // ""' "${request_file}" 2>/dev/null)
    task_id=$(jq -r '.task_id // ""' "${request_file}" 2>/dev/null)
    [[ "${status}" == "submitted" && -n "${task_id}" ]] || continue

    # Check if result exists
    local result_file="${SHARED_DIR}/decisions/${task_id}_result.json"
    [[ -f "${result_file}" ]] || continue

    # Check if we already wrote the result back
    local result_out="${suggestions_dir}/research_result_${task_id}.json"
    [[ -f "${result_out}" ]] && continue

    # Read decision and result
    local decision_file="${SHARED_DIR}/decisions/${task_id}.json"
    local decision approach result_summary
    decision=$(jq -r '.decision // "unknown"' "${decision_file}" 2>/dev/null || echo "unknown")
    approach=$(jq -r '.agreed_approach // ""' "${decision_file}" 2>/dev/null || echo "")
    result_summary=$(jq -r '.summary // .result // ""' "${result_file}" 2>/dev/null || echo "")
    local completed_at
    completed_at=$(jq -r '.completed_at // ""' "${result_file}" 2>/dev/null || echo "")

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
    log "ERROR: LINE Push API request failed for research notification"
    rm -f "${response_body}"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Research result notification sent via LINE (HTTP ${http_code}) for task ${task_id}"
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
    local request_file="${eval_dir}/request.json"

    [[ -f "${request_file}" ]] || continue

    local eval_status
    eval_status=$(jq -r '.status' "${request_file}")
    [[ "${eval_status}" == "pending" || "${eval_status}" == "in_progress" ]] || continue

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
    fi
  done
}
