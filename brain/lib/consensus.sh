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

  for node in "${ALL_NODES[@]}"; do
    local response_file="${round_dir}/${node}.json"
    if [[ -f "${response_file}" ]]; then
      local vote
      vote=$(jq -r '.vote' "${response_file}")

      case "${vote}" in
        approve) ((approve_count++)) ;;
        reject) ((reject_count++)) ;;
        approve_with_modification) ((modify_count++)) ;;
      esac
    fi
  done

  log "Consensus check for ${task_id} round ${round}: approve=${approve_count} modify=${modify_count} reject=${reject_count}"

  # Unanimous reject = immediate rejection (any round)
  if [[ ${reject_count} -eq ${#ALL_NODES[@]} ]]; then
    log "Unanimous reject for ${task_id} in round ${round}, rejecting immediately"
    finalize_decision "${task_id}" "rejected" "${round}" ""
    return
  fi

  # Still have more rounds → advance to next round
  if [[ ${round} -lt ${MAX_ROUNDS} ]]; then
    local next_round=$((round + 1))
    mkdir -p "${discussion_dir}/round_${next_round}"

    local tmp
    tmp=$(mktemp)
    jq '.current_round = '"${next_round}"' | .status = "discussing"' \
      "${status_file}" > "${tmp}" && mv "${tmp}" "${status_file}"

    log "Advancing ${task_id} to round ${next_round} (minimum 2 rounds required)"
    return
  fi

  # Final round reached → Triceratops makes the final decision
  log "All ${MAX_ROUNDS} rounds complete for ${task_id}, Triceratops renders final decision"
  triceratops_final_decision "${task_id}" "${round}"
}

triceratops_final_decision() {
  local task_id="$1"
  local final_round="$2"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"

  # Collect all round responses with full detail
  local all_responses=""
  for r in $(seq 1 "${final_round}"); do
    all_responses="${all_responses}
### Round ${r}:"
    for node in "${ALL_NODES[@]}"; do
      local resp_file="${discussion_dir}/round_${r}/${node}.json"
      if [[ -f "${resp_file}" ]]; then
        local opinion vote approach concerns
        opinion=$(jq -r '.opinion' "${resp_file}")
        vote=$(jq -r '.vote' "${resp_file}")
        approach=$(jq -r '.proposed_approach // ""' "${resp_file}")
        concerns=$(jq -r '.concerns // [] | join(", ")' "${resp_file}")
        all_responses="${all_responses}
#### ${node} (vote: ${vote}):
Opinion: ${opinion}"
        if [[ -n "${approach}" ]]; then
          all_responses="${all_responses}
Proposed approach: ${approach}"
        fi
        if [[ -n "${concerns}" ]]; then
          all_responses="${all_responses}
Concerns: ${concerns}"
        fi
        all_responses="${all_responses}
"
      fi
    done
  done

  # Load user comments if any
  local user_comments=""
  local comments_file="${discussion_dir}/comments.json"
  if [[ -f "${comments_file}" ]]; then
    local comment_count
    comment_count=$(jq 'length' "${comments_file}" 2>/dev/null || echo 0)
    if [[ ${comment_count} -gt 0 ]]; then
      user_comments="
## User Comments:"
      local i
      for ((i=0; i<comment_count; i++)); do
        local msg timestamp
        msg=$(jq -r ".[$i].message" "${comments_file}")
        timestamp=$(jq -r ".[$i].created_at" "${comments_file}")
        user_comments="${user_comments}
- [${timestamp}] ${msg}"
      done
    fi
  fi

  local task_content
  task_content=$(cat "${discussion_dir}/task.json")

  local prompt="You are the Triceratops chairperson in the Soul system.
After ${final_round} rounds of discussion among all brain nodes, you must now render the final decision.

## Task:
${task_content}

## Full Discussion History:
${all_responses}
${user_comments}

## Instructions:
Review all perspectives from the discussion. As the chairperson:
1. Synthesize the key arguments from all nodes
2. Consider safety concerns (Panda), innovation opportunities (Gorilla), and practical balance
3. Make a final decision that best serves the task goals

Respond with ONLY a valid JSON object:
{
  \"decision\": \"approved|rejected\",
  \"final_approach\": \"The synthesized approach incorporating the best ideas from discussion\",
  \"reasoning\": \"Why this decision was made, referencing specific node arguments\",
  \"decided_by\": \"triceratops\"
}"

  local response
  response=$(invoke_claude "${prompt}")

  # Strip markdown code fences if Claude wrapped the response
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

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

  # Guard: if a newer round was requested (e.g. via user comment), don't overwrite
  local current_round_now
  current_round_now=$(jq -r '.current_round' "${status_file}")
  if [[ ${current_round_now} -gt ${final_round} ]]; then
    log "New round ${current_round_now} requested during finalization of round ${final_round} for ${task_id}, skipping"
    return
  fi

  # Update discussion status
  local tmp
  tmp=$(mktemp)
  jq '.status = "decided" | .decided_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "${status_file}" > "${tmp}" && mv "${tmp}" "${status_file}"

  # Executor is always panda
  local executor="panda"

  # Write decision file — status is pending_announcement so triceratops can announce
  local final_status="pending_announcement"
  if [[ "${decision}" == "rejected" ]]; then
    final_status="rejected"
  fi

  local escaped_approach
  escaped_approach=$(echo "${approach}" | jq -Rs .)
  cat > "${SHARED_DIR}/decisions/${task_id}.json" <<EOF
{
  "task_id": "${task_id}",
  "decision": "${decision}",
  "status": "${final_status}",
  "final_round": ${final_round},
  "final_approach": ${escaped_approach},
  "executor": "${executor}",
  "decided_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  log "Decision finalized for ${task_id}: ${decision} (executor: ${executor}, status: ${final_status})"
}
