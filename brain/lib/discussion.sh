#!/usr/bin/env bash
# discussion.sh - Discussion protocol implementation

MAX_ROUNDS=3

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

  mkdir -p "${round_dir}"

  local task_content
  task_content=$(cat "${discussion_dir}/task.json")

  # Build context from previous rounds
  local context=""
  if [[ ${round} -gt 1 ]]; then
    local prev_round=$((round - 1))
    local prev_dir="${discussion_dir}/round_${prev_round}"
    context="## Previous Round (${prev_round}) Responses:
"
    for node in "${ALL_NODES[@]}"; do
      if [[ -f "${prev_dir}/${node}.json" ]]; then
        local opinion
        opinion=$(jq -r '.opinion' "${prev_dir}/${node}.json")
        local vote
        vote=$(jq -r '.vote' "${prev_dir}/${node}.json")
        context="${context}
### ${node} (vote: ${vote}):
${opinion}
"
      fi
    done
  fi

  # Load protocol template
  local protocol
  protocol=$(cat "${BRAIN_DIR}/protocols/discussion.md")

  # Build prompt
  local prompt="${protocol}

## Your Identity
You are the ${NODE_NAME} brain node in the Soul system.
Your parameters: risk_tolerance=${RISK_TOLERANCE}, innovation_weight=${INNOVATION_WEIGHT}, safety_weight=${SAFETY_WEIGHT}, thoroughness=${THOROUGHNESS}, consensus_flexibility=${CONSENSUS_FLEXIBILITY}

## Task
${task_content}

## Round ${round} of ${MAX_ROUNDS}
${context}

## Instructions
Analyze this task according to your personality and parameters.
You MUST respond with ONLY a valid JSON object (no markdown, no code fences):
{
  \"node\": \"${NODE_NAME}\",
  \"round\": ${round},
  \"vote\": \"approve|approve_with_modification|reject\",
  \"opinion\": \"Your detailed opinion\",
  \"proposed_approach\": \"Your proposed approach to the task\",
  \"concerns\": [\"list of concerns\"],
  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
}"

  local response
  response=$(invoke_claude "${prompt}")

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

  log "Responded to discussion ${task_id} round ${round}"
}

execute_decision() {
  local decision_file="$1"
  local task_id
  task_id=$(jq -r '.task_id' "${decision_file}")
  local approach
  approach=$(jq -r '.final_approach' "${decision_file}")
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"

  # Mark as executing
  local tmp
  tmp=$(mktemp)
  jq '.status = "executing" | .executor = "'"${NODE_NAME}"'" | .execution_started_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "${decision_file}" > "${tmp}" && mv "${tmp}" "${decision_file}"

  log "Executing task ${task_id} with approach: ${approach}"

  # Load task execution protocol
  local protocol
  protocol=$(cat "${BRAIN_DIR}/protocols/task-execution.md")

  local task_content
  task_content=$(cat "${discussion_dir}/task.json")

  local prompt="${protocol}

## Task
${task_content}

## Agreed Approach
${approach}

## Instructions
Execute this task following the agreed approach. Work within the /shared/workspace/ directory.
Report your results."

  local result
  result=$(invoke_claude "${prompt}")

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

  log "Task ${task_id} execution completed"
}
