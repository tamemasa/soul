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
