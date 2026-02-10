#!/usr/bin/env bash
# consensus.sh - Consensus evaluation and decision logic

evaluate_consensus() {
  local task_id="$1"
  local round="$2"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"
  local round_dir="${discussion_dir}/round_${round}"
  local status_file="${discussion_dir}/status.json"

  # Collect all votes
  local approve_count=0
  local reject_count=0
  local modify_count=0
  local votes=()
  local approaches=()

  for node in "${ALL_NODES[@]}"; do
    local response_file="${round_dir}/${node}.json"
    if [[ -f "${response_file}" ]]; then
      local vote
      vote=$(jq -r '.vote' "${response_file}")
      votes+=("${node}:${vote}")

      case "${vote}" in
        approve) ((approve_count++)) ;;
        reject) ((reject_count++)) ;;
        approve_with_modification) ((modify_count++)) ;;
      esac

      local approach
      approach=$(jq -r '.proposed_approach // ""' "${response_file}")
      if [[ -n "${approach}" ]]; then
        approaches+=("${node}: ${approach}")
      fi
    fi
  done

  local total=$((approve_count + modify_count + reject_count))
  local agree_count=$((approve_count + modify_count))

  log "Consensus check for ${task_id} round ${round}: approve=${approve_count} modify=${modify_count} reject=${reject_count}"

  # 2/3 majority for approval (approve + approve_with_modification)
  if [[ ${agree_count} -ge 2 ]]; then
    log "Consensus reached for ${task_id}: approved (${agree_count}/${total})"
    finalize_decision "${task_id}" "approved" "${round}" "${approaches[*]}"
    return
  fi

  # 2/3 majority for rejection
  if [[ ${reject_count} -ge 2 ]]; then
    log "Consensus reached for ${task_id}: rejected (${reject_count}/${total})"
    finalize_decision "${task_id}" "rejected" "${round}" ""
    return
  fi

  # No consensus - check if we have more rounds
  if [[ ${round} -lt ${MAX_ROUNDS} ]]; then
    local next_round=$((round + 1))
    mkdir -p "${discussion_dir}/round_${next_round}"

    local tmp
    tmp=$(mktemp)
    jq '.current_round = '"${next_round}"' | .status = "discussing"' \
      "${status_file}" > "${tmp}" && mv "${tmp}" "${status_file}"

    log "No consensus for ${task_id}, advancing to round ${next_round}"
    return
  fi

  # Final round with no consensus - Triceratops mediates
  log "No consensus after ${MAX_ROUNDS} rounds for ${task_id}, Triceratops mediates"
  mediate_decision "${task_id}" "${round}"
}

mediate_decision() {
  local task_id="$1"
  local final_round="$2"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"

  # Only triceratops runs mediation
  if [[ "${NODE_NAME}" != "gorilla" ]]; then
    # gorilla triggers mediation but signals triceratops
    local mediation_request="${discussion_dir}/mediation_request.json"
    cat > "${mediation_request}" <<EOF
{
  "task_id": "${task_id}",
  "requested_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "final_round": ${final_round}
}
EOF
    return
  fi

  # Collect all round responses
  local all_responses=""
  for r in $(seq 1 "${final_round}"); do
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

  local prompt="You are the Triceratops mediator in the Soul system.
The Brain nodes could not reach consensus after ${final_round} rounds of discussion.
As the mediator, you must make a final decision.

## Task:
${task_content}

## Discussion History:
${all_responses}

## Instructions:
Make a final decision. Consider all perspectives but prioritize practical outcomes.
Respond with ONLY a valid JSON object:
{
  \"decision\": \"approved|rejected\",
  \"final_approach\": \"The chosen approach\",
  \"reasoning\": \"Why this decision was made\",
  \"mediated_by\": \"triceratops\"
}"

  local response
  response=$(invoke_claude "${prompt}")

  local decision="approved"
  local approach=""
  if echo "${response}" | jq . > /dev/null 2>&1; then
    decision=$(echo "${response}" | jq -r '.decision // "approved"')
    approach=$(echo "${response}" | jq -r '.final_approach // ""')
  fi

  finalize_decision "${task_id}" "${decision}" "${final_round}" "${approach}"
}

finalize_decision() {
  local task_id="$1"
  local decision="$2"
  local final_round="$3"
  local approach="$4"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"
  local status_file="${discussion_dir}/status.json"

  # Update discussion status
  local tmp
  tmp=$(mktemp)
  jq '.status = "decided" | .decided_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "${status_file}" > "${tmp}" && mv "${tmp}" "${status_file}"

  # Determine executor: pick the node whose approach was closest to consensus
  # Default to panda for safety-critical, gorilla for innovation tasks
  local executor="panda"
  local task_type
  task_type=$(jq -r '.type // "task"' "${discussion_dir}/task.json")
  case "${task_type}" in
    evaluation) executor="gorilla" ;;
    worker_create) executor="gorilla" ;;
    *) executor="panda" ;;
  esac

  # Write decision file
  local escaped_approach
  escaped_approach=$(echo "${approach}" | jq -Rs .)
  cat > "${SHARED_DIR}/decisions/${task_id}.json" <<EOF
{
  "task_id": "${task_id}",
  "decision": "${decision}",
  "status": "${decision}",
  "final_round": ${final_round},
  "final_approach": ${escaped_approach},
  "executor": "${executor}",
  "decided_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  log "Decision finalized for ${task_id}: ${decision} (executor: ${executor})"
}
