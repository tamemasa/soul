#!/usr/bin/env bash
# discussion.sh - Discussion protocol implementation

MAX_ROUNDS=3
EMBED_SIZE_LIMIT=51200  # 50KB

is_embeddable_text() {
  local mime="$1"
  local filepath="$2"
  case "${mime}" in
    text/*|application/json|application/xml|application/javascript|application/x-sh|application/x-shellscript|application/typescript)
      return 0 ;;
    application/octet-stream)
      if [[ -n "${filepath}" ]] && command -v file >/dev/null 2>&1; then
        local detected
        detected=$(file --mime-type -b "${filepath}" 2>/dev/null)
        case "${detected}" in
          text/*) return 0 ;;
        esac
      fi
      return 1 ;;
    *) return 1 ;;
  esac
}

build_attachment_context() {
  local task_id="$1"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"
  local attachments_dir="${SHARED_DIR}/attachments/${task_id}"
  local context=""

  # Task-level attachments
  local task_file="${discussion_dir}/task.json"
  if [[ -f "${task_file}" ]]; then
    local att_count
    att_count=$(jq '.attachments // [] | length' "${task_file}" 2>/dev/null || echo 0)
    if [[ ${att_count} -gt 0 ]]; then
      local i
      for ((i=0; i<att_count; i++)); do
        local fname orig_name fsize mime
        fname=$(jq -r ".attachments[$i].filename" "${task_file}")
        orig_name=$(jq -r ".attachments[$i].original_name" "${task_file}")
        fsize=$(jq -r ".attachments[$i].size" "${task_file}")
        mime=$(jq -r ".attachments[$i].mime_type" "${task_file}")
        local fpath="${attachments_dir}/${fname}"

        if is_embeddable_text "${mime}" "${fpath}" && [[ -f "${fpath}" ]] && [[ ${fsize} -le ${EMBED_SIZE_LIMIT} ]]; then
          local content
          content=$(cat "${fpath}" 2>/dev/null || echo "(read error)")
          context="${context}

--- Attached File: ${orig_name} ---
${content}
--- End of ${orig_name} ---"
        else
          context="${context}
[Attached file: ${orig_name} (${fsize} bytes, ${mime}) at ${fpath}]"
        fi
      done
    fi
  fi

  # Comment-level attachments
  local comments_file="${discussion_dir}/comments.json"
  if [[ -f "${comments_file}" ]]; then
    local comment_count
    comment_count=$(jq 'length' "${comments_file}" 2>/dev/null || echo 0)
    local c
    for ((c=0; c<comment_count; c++)); do
      local catt_count comment_id
      catt_count=$(jq ".[$c].attachments // [] | length" "${comments_file}" 2>/dev/null || echo 0)
      if [[ ${catt_count} -gt 0 ]]; then
        comment_id=$(jq -r ".[$c].id" "${comments_file}")
        local j
        for ((j=0; j<catt_count; j++)); do
          local fname orig_name fsize mime
          fname=$(jq -r ".[$c].attachments[$j].filename" "${comments_file}")
          orig_name=$(jq -r ".[$c].attachments[$j].original_name" "${comments_file}")
          fsize=$(jq -r ".[$c].attachments[$j].size" "${comments_file}")
          mime=$(jq -r ".[$c].attachments[$j].mime_type" "${comments_file}")
          local fpath="${attachments_dir}/comments/${comment_id}/${fname}"

          if is_embeddable_text "${mime}" "${fpath}" && [[ -f "${fpath}" ]] && [[ ${fsize} -le ${EMBED_SIZE_LIMIT} ]]; then
            local content
            content=$(cat "${fpath}" 2>/dev/null || echo "(read error)")
            context="${context}

--- Attached File (comment): ${orig_name} ---
${content}
--- End of ${orig_name} ---"
          else
            context="${context}
[Attached file (comment): ${orig_name} (${fsize} bytes, ${mime}) at ${fpath}]"
          fi
        done
      fi
    done
  fi

  echo "${context}"
}

start_discussion() {
  local task_file="$1"
  local task_id="$2"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"

  # Only one node creates the discussion directory (alphabetical first: gorilla)
  # Others will find it already created and just respond
  if [[ "${NODE_NAME}" == "gorilla" ]]; then
    mkdir -p "${discussion_dir}/round_1"
    cp "${task_file}" "${discussion_dir}/task.json"

    # Create status file
    cat > "${discussion_dir}/status.json" <<EOF
{
  "task_id": "${task_id}",
  "status": "discussing",
  "current_round": 1,
  "max_rounds": ${MAX_ROUNDS},
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "started_by": "${NODE_NAME}"
}
EOF
    log "Discussion created for task: ${task_id}"
  fi

  # Wait briefly for the directory to be created by gorilla
  sleep 2

  if [[ -d "${discussion_dir}" ]]; then
    respond_to_discussion "${task_id}" 1
  fi
}

respond_to_discussion() {
  local task_id="$1"
  local round="$2"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"
  local round_dir="${discussion_dir}/round_${round}"
  local my_response="${round_dir}/${NODE_NAME}.json"

  # Skip if already responded
  [[ ! -f "${my_response}" ]] || return 0

  set_activity "discussing" "\"task_id\":\"${task_id}\",\"round\":${round},"

  mkdir -p "${round_dir}"

  local task_content
  task_content=$(cat "${discussion_dir}/task.json")

  # Build context from ALL previous rounds (not just the last one)
  local context=""
  if [[ ${round} -gt 1 ]]; then
    context="## Previous Discussion:
"
    for ((prev_r=1; prev_r<round; prev_r++)); do
      local prev_dir="${discussion_dir}/round_${prev_r}"
      context="${context}
### Round ${prev_r}:"
      for node in "${ALL_NODES[@]}"; do
        if [[ -f "${prev_dir}/${node}.json" ]]; then
          local opinion vote approach
          opinion=$(jq -r '.opinion' "${prev_dir}/${node}.json")
          vote=$(jq -r '.vote' "${prev_dir}/${node}.json")
          approach=$(jq -r '.proposed_approach // ""' "${prev_dir}/${node}.json")
          context="${context}
#### ${node} (vote: ${vote}):
${opinion}"
          if [[ -n "${approach}" ]]; then
            context="${context}
Proposed approach: ${approach}"
          fi
          context="${context}
"
        fi
      done
    done
  fi

  # Load user comments if any
  local user_comments=""
  local comments_file="${discussion_dir}/comments.json"
  if [[ -f "${comments_file}" ]]; then
    local comment_count
    comment_count=$(jq 'length' "${comments_file}" 2>/dev/null || echo 0)
    if [[ ${comment_count} -gt 0 ]]; then
      user_comments="## User Comments/Requests:
"
      local i
      for ((i=0; i<comment_count; i++)); do
        local msg timestamp
        msg=$(jq -r ".[$i].message" "${comments_file}")
        timestamp=$(jq -r ".[$i].created_at" "${comments_file}")
        user_comments="${user_comments}
- [${timestamp}] ${msg}"
      done
      user_comments="${user_comments}

IMPORTANT: The user (system operator) has provided the above comments. Please carefully consider their feedback and requests in your response.
"
    fi
  fi

  # Load protocol template
  local protocol
  protocol=$(cat "${BRAIN_DIR}/protocols/discussion.md")

  # Build attachment context
  local attachment_context
  attachment_context=$(build_attachment_context "${task_id}")

  # Build prompt
  local prompt="${protocol}

## Your Identity
You are the ${NODE_NAME} brain node in the Soul system.
Your parameters: risk_tolerance=${RISK_TOLERANCE}, innovation_weight=${INNOVATION_WEIGHT}, safety_weight=${SAFETY_WEIGHT}, thoroughness=${THOROUGHNESS}, consensus_flexibility=${CONSENSUS_FLEXIBILITY}

## Task
${task_content}
${attachment_context}

## Round ${round} of ${MAX_ROUNDS}
${context}
${user_comments}

## Instructions
Analyze this task according to your personality and parameters.
opinion、proposed_approach、concernsの内容は必ず日本語で記述すること。JSONキー名とvote値は英語のまま維持する。
You MUST respond with ONLY a valid JSON object (no markdown, no code fences):
{
  \"node\": \"${NODE_NAME}\",
  \"round\": ${round},
  \"vote\": \"approve|approve_with_modification|reject\",
  \"opinion\": \"あなたの詳細な意見（日本語）\",
  \"proposed_approach\": \"タスクへの提案アプローチ（日本語）\",
  \"concerns\": [\"懸念事項のリスト（日本語）\"],
  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
}"

  local response
  response=$(invoke_claude "${prompt}")

  # Strip markdown code fences if Claude wrapped the response
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

  # Validate and save JSON response
  if echo "${response}" | jq . > /dev/null 2>&1; then
    echo "${response}" > "${my_response}"
  else
    # Wrap raw response in JSON structure
    local escaped
    escaped=$(echo "${response}" | jq -Rs .)
    cat > "${my_response}" <<EOF
{
  "node": "${NODE_NAME}",
  "round": ${round},
  "vote": "approve_with_modification",
  "opinion": ${escaped},
  "proposed_approach": "",
  "concerns": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  fi

  set_activity "idle"
  log "Responded to discussion ${task_id} round ${round}"
}

announce_decision() {
  local decision_file="$1"
  local task_id
  task_id=$(jq -r '.task_id' "${decision_file}")
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"

  # Mark as announcing (prevents double execution by watcher)
  local tmp
  tmp=$(mktemp)
  jq '.status = "announcing"' "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"

  set_activity "announcing" "\"task_id\":\"${task_id}\","
  log "Announcing decision for task: ${task_id}"

  # Collect all round responses
  local status_file="${discussion_dir}/status.json"
  local max_round
  max_round=$(jq -r '.current_round' "${status_file}")

  local all_responses=""
  for r in $(seq 1 "${max_round}"); do
    all_responses="${all_responses}
## Round ${r}:"
    for node in "${ALL_NODES[@]}"; do
      local resp_file="${discussion_dir}/round_${r}/${node}.json"
      if [[ -f "${resp_file}" ]]; then
        local opinion vote
        opinion=$(jq -r '.opinion' "${resp_file}")
        vote=$(jq -r '.vote' "${resp_file}")
        all_responses="${all_responses}
### ${node} (${vote}): ${opinion}"
      fi
    done
  done

  local task_content
  task_content=$(cat "${discussion_dir}/task.json")

  local approach
  approach=$(jq -r '.final_approach' "${decision_file}")

  # Load announcement protocol template
  local protocol
  protocol=$(cat "${BRAIN_DIR}/protocols/announcement.md")

  # Build attachment context
  local attachment_context
  attachment_context=$(build_attachment_context "${task_id}")

  local prompt="${protocol}

## Task
${task_content}
${attachment_context}

## Discussion History
${all_responses}

## Final Decision
Decision: $(jq -r '.decision' "${decision_file}")
Approach: ${approach}

## Instructions
議論の要約と最終決定を発表してください。summary、key_pointsは必ず日本語で記述すること。
You MUST respond with ONLY a valid JSON object (no markdown, no code fences):
{
  \"summary\": \"議論と最終決定の明確な要約（日本語）\",
  \"key_points\": [\"要点1（日本語）\", \"要点2（日本語）\", ...]
}"

  # Record original decided_at for cancellation detection
  local original_decided_at
  original_decided_at=$(jq -r '.decided_at // ""' "${decision_file}")

  # Stream announcement to progress file for real-time UI display
  local progress_file="${SHARED_DIR}/decisions/${task_id}_announce_progress.jsonl"
  : > "${progress_file}"

  # Run claude in background so we can monitor for cancellation
  claude -p "${prompt}" ${CLAUDE_MODEL:+--model "${CLAUDE_MODEL}"} --permission-mode bypassPermissions --verbose --output-format stream-json \
    > "${progress_file}" \
    2>>"${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)/${NODE_NAME}_claude.log" &
  local claude_pid=$!

  if ! monitor_claude_process "${claude_pid}" "${decision_file}" "${original_decided_at}" "${task_id}"; then
    log "Announcement of ${task_id} was cancelled due to re-decision"
    set_activity "idle"
    return
  fi

  if [[ ! -s "${progress_file}" ]]; then
    log "ERROR: Claude invocation failed for announcement of task ${task_id}"
    # Mark as failed to announce (revert to pending_announcement for retry)
    tmp=$(mktemp)
    jq '.status = "pending_announcement"' "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
    set_activity "idle"
    return
  fi

  # Extract final result from stream
  local response
  response=$(jq -r 'select(.type == "result") | .result // ""' "${progress_file}" 2>/dev/null | tail -1)

  # If no response, try alternative extraction or revert status
  if [[ -z "${response}" ]]; then
    log "WARN: No result extracted from announcement progress, attempting alternative extraction"
    response=$(tail -1 "${progress_file}" | jq -r '.message.content // ""' 2>/dev/null || echo "")
    if [[ -z "${response}" ]]; then
      log "ERROR: Failed to extract announcement result for task ${task_id}"
      tmp=$(mktemp)
      jq '.status = "pending_announcement"' "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
      set_activity "idle"
      return
    fi
  fi

  # Strip markdown code fences if Claude wrapped the response
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

  local summary=""
  local key_points="[]"
  if echo "${response}" | jq . > /dev/null 2>&1; then
    summary=$(echo "${response}" | jq -r '.summary // ""')
    key_points=$(echo "${response}" | jq '.key_points // []')
  else
    # Try extracting JSON object if Claude added preamble text before JSON
    local json_part
    json_part=$(echo "${response}" | sed -n '/^[[:space:]]*{/,/^[[:space:]]*}/p')
    if [[ -n "${json_part}" ]] && echo "${json_part}" | jq . > /dev/null 2>&1; then
      summary=$(echo "${json_part}" | jq -r '.summary // ""')
      key_points=$(echo "${json_part}" | jq '.key_points // []')
    else
      summary="${response}"
    fi
  fi

  # Update decision file with announcement
  # Use $ENV to avoid shell quoting issues with --argjson
  local tmp
  tmp=$(mktemp)
  local announced_at
  announced_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  JQ_SUMMARY="${summary}" JQ_KP="${key_points}" \
    jq --arg at "${announced_at}" \
    '.status = "announced" | .announcement = {
      "summary": env.JQ_SUMMARY,
      "key_points": (env.JQ_KP | try fromjson catch []),
      "announced_by": "triceratops",
      "announced_at": $at
    }' "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"

  set_activity "idle"
  log "Decision announced for task: ${task_id}"
}

# Monitor a background claude process; kill it if the decision's decided_at changes (re-decision).
# Usage: monitor_claude_process <pid> <decision_file> <original_decided_at> <task_id>
# Returns 0 if claude finished normally, 1 if cancelled.
monitor_claude_process() {
  local pid="$1"
  local decision_file="$2"
  local original_decided_at="$3"
  local task_id="$4"

  while kill -0 "${pid}" 2>/dev/null; do
    sleep 3
    # Check if the decision was replaced (decided_at changed)
    local current_decided_at
    current_decided_at=$(jq -r '.decided_at // ""' "${decision_file}" 2>/dev/null || echo "")
    if [[ -n "${current_decided_at}" && "${current_decided_at}" != "${original_decided_at}" ]]; then
      log "Decision for ${task_id} was replaced (decided_at changed), cancelling claude process ${pid}"
      kill "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      return 1
    fi
  done
  wait "${pid}" 2>/dev/null
  return 0
}

execute_decision() {
  local decision_file="$1"
  local task_id
  task_id=$(jq -r '.task_id' "${decision_file}")
  local approach
  approach=$(jq -r '.final_approach' "${decision_file}")
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"
  local status_file="${discussion_dir}/status.json"

  # Guard: if status was changed back to "discussing" (new round requested), skip execution
  local current_status
  current_status=$(jq -r '.status' "${status_file}" 2>/dev/null || echo "")
  if [[ "${current_status}" == "discussing" ]]; then
    log "Skipping execution of ${task_id}: discussion was reopened (status=discussing)"
    return
  fi

  # Record original decided_at for cancellation detection
  local original_decided_at
  original_decided_at=$(jq -r '.decided_at // ""' "${decision_file}")

  # Mark as executing
  local tmp
  tmp=$(mktemp)
  jq '.status = "executing" | .executor = "'"${NODE_NAME}"'" | .execution_started_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"

  set_activity "executing" "\"task_id\":\"${task_id}\","
  log "Executing task ${task_id} with approach: ${approach}"

  # Load task execution protocol
  local protocol
  protocol=$(cat "${BRAIN_DIR}/protocols/task-execution.md")

  local task_content
  task_content=$(cat "${discussion_dir}/task.json")

  # Build attachment context
  local attachment_context
  attachment_context=$(build_attachment_context "${task_id}")

  local prompt="${protocol}

## Task
${task_content}
${attachment_context}

## Agreed Approach
${approach}

## Instructions
Execute this task following the agreed approach. Work within the /shared/workspace/ directory.
Report your results."

  # Stream execution to progress file for real-time UI display
  local progress_file="${SHARED_DIR}/decisions/${task_id}_progress.jsonl"
  : > "${progress_file}"

  # Run claude in background so we can monitor for cancellation
  claude -p "${prompt}" ${CLAUDE_MODEL:+--model "${CLAUDE_MODEL}"} --permission-mode bypassPermissions --verbose --output-format stream-json \
    > "${progress_file}" \
    2>>"${SHARED_DIR}/logs/$(date -u +%Y-%m-%d)/${NODE_NAME}_claude.log" &
  local claude_pid=$!

  if ! monitor_claude_process "${claude_pid}" "${decision_file}" "${original_decided_at}" "${task_id}"; then
    log "Execution of ${task_id} was cancelled due to re-decision"
    set_activity "idle"
    return
  fi

  # Check exit status
  if [[ ! -s "${progress_file}" ]]; then
    log "ERROR: Claude invocation failed for task ${task_id}"
    # Mark as failed
    tmp=$(mktemp)
    jq '.status = "failed" | .failed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .failure_reason = "claude invocation failed"' \
      "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
    set_activity "idle"
    return
  fi

  # Extract final result from stream
  local result
  result=$(jq -r 'select(.type == "result") | .result // ""' "${progress_file}" 2>/dev/null | tail -1)

  # If result is empty, check if execution actually succeeded
  if [[ -z "${result}" ]]; then
    local subtype
    subtype=$(jq -r 'select(.type == "result") | .subtype // ""' "${progress_file}" 2>/dev/null | tail -1)

    if [[ "${subtype}" == "success" ]]; then
      log "WARN: Empty result but subtype=success for task ${task_id}, extracting from last assistant message"
      # Extract last assistant text block as fallback
      result=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // ""' \
        "${progress_file}" 2>/dev/null | tail -n 50 | head -c 10000)
    fi

    if [[ -z "${result}" ]]; then
      log "ERROR: No result extracted from progress file for task ${task_id}"
      tmp=$(mktemp)
      jq '.status = "failed" | .failed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .failure_reason = "no result extracted from execution"' \
        "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"
      set_activity "idle"
      return
    fi
  fi

  # Save execution result
  local result_file="${SHARED_DIR}/decisions/${task_id}_result.json"
  local escaped_result
  escaped_result=$(echo "${result}" | jq -Rs .)
  cat > "${result_file}" <<EOF
{
  "task_id": "${task_id}",
  "executor": "${NODE_NAME}",
  "result": ${escaped_result},
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  # Mark decision as completed
  tmp=$(mktemp)
  jq '.status = "completed" | .completed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"

  # Move task from inbox to archive
  local inbox_task="${SHARED_DIR}/inbox/${task_id}.json"
  if [[ -f "${inbox_task}" ]]; then
    mkdir -p "${SHARED_DIR}/archive"
    mv "${inbox_task}" "${SHARED_DIR}/archive/${task_id}.json"
  fi

  set_activity "idle"
  log "Task ${task_id} execution completed"
}
