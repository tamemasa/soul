#!/usr/bin/env bash
# evaluation.sh - Mutual evaluation protocol

run_evaluation() {
  local cycle_id="$1"
  local eval_dir="${SHARED_DIR}/evaluations/${cycle_id}"

  local other_nodes
  read -ra other_nodes <<< "$(get_other_nodes)"

  for target in "${other_nodes[@]}"; do
    local eval_file="${eval_dir}/${NODE_NAME}_evaluates_${target}.json"
    [[ -f "${eval_file}" ]] && continue

    set_activity "evaluating" "\"target\":\"${target}\",\"cycle_id\":\"${cycle_id}\","
    log "Evaluating node: ${target}"

    # Gather target's recent activity
    local recent_activity=""
    recent_activity=$(gather_node_activity "${target}")

    # Gather target's current params
    local target_params=""
    local target_params_file="${SHARED_DIR}/nodes/${target}/params.json"
    if [[ -f "${target_params_file}" ]]; then
      target_params=$(cat "${target_params_file}" 2>/dev/null || echo "{}")
    fi

    local protocol
    protocol=$(cat "${BRAIN_DIR}/protocols/evaluation.md")

    local prompt="${protocol}

## Your Identity
You are the ${NODE_NAME} brain node evaluating the ${target} node.
Your parameters: risk_tolerance=${RISK_TOLERANCE}, safety_weight=${SAFETY_WEIGHT}

## Target Node: ${target}
Current parameters: ${target_params}

## Recent Activity of ${target}:
${recent_activity}

## Instructions
Evaluate the ${target} node's performance, decision quality, and parameter balance.
Respond with ONLY a valid JSON object:
{
  \"evaluator\": \"${NODE_NAME}\",
  \"target\": \"${target}\",
  \"cycle_id\": \"${cycle_id}\",
  \"scores\": {
    \"decision_quality\": 0.0,
    \"collaboration\": 0.0,
    \"effectiveness\": 0.0,
    \"parameter_balance\": 0.0
  },
  \"overall_score\": 0.0,
  \"needs_retuning\": false,
  \"suggested_params\": {},
  \"reasoning\": \"Detailed reasoning\",
  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
}"

    local response
    response=$(invoke_claude "${prompt}")

    # Strip markdown code fences if Claude wrapped the response
    response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

    if echo "${response}" | jq . > /dev/null 2>&1; then
      echo "${response}" > "${eval_file}"
    else
      local escaped
      escaped=$(echo "${response}" | jq -Rs .)
      cat > "${eval_file}" <<EOF
{
  "evaluator": "${NODE_NAME}",
  "target": "${target}",
  "cycle_id": "${cycle_id}",
  "scores": {"decision_quality": 0.5, "collaboration": 0.5, "effectiveness": 0.5, "parameter_balance": 0.5},
  "overall_score": 0.5,
  "needs_retuning": false,
  "suggested_params": {},
  "reasoning": ${escaped},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    fi

    set_activity "idle"
    log "Evaluation of ${target} submitted"
  done

  # Check if all evaluations for this cycle are complete
  check_evaluation_results "${cycle_id}"
}

gather_node_activity() {
  local target="$1"
  local activity=""

  # Look at recent discussion responses from this node
  local count=0
  for discussion_dir in "${SHARED_DIR}/discussions"/*/; do
    [[ -d "${discussion_dir}" ]] || continue
    [[ ${count} -ge 5 ]] && break

    for round_dir in "${discussion_dir}"/round_*/; do
      local resp="${round_dir}/${target}.json"
      if [[ -f "${resp}" ]]; then
        local vote opinion
        vote=$(jq -r '.vote // "unknown"' "${resp}")
        opinion=$(jq -r '.opinion // ""' "${resp}" | head -c 200)
        activity="${activity}
- Task $(basename "${discussion_dir}"): vote=${vote}, opinion=${opinion}..."
        ((count++))
      fi
    done
  done

  # Look at recent logs
  local today
  today=$(date -u +%Y-%m-%d)
  local log_file="${SHARED_DIR}/logs/${today}/${target}.log"
  if [[ -f "${log_file}" ]]; then
    activity="${activity}

Recent logs:
$(tail -20 "${log_file}")"
  fi

  echo "${activity:-No recent activity found.}"
}

check_evaluation_results() {
  local cycle_id="$1"
  local eval_dir="${SHARED_DIR}/evaluations/${cycle_id}"

  # Count total evaluations expected: 3 nodes * 2 targets each = 6
  local expected=6
  local actual=0
  for eval_file in "${eval_dir}"/*_evaluates_*.json; do
    [[ -f "${eval_file}" ]] && ((actual++))
  done

  [[ ${actual} -ge ${expected} ]] || return 0

  # Only one node processes results (gorilla as coordinator)
  [[ "${NODE_NAME}" == "gorilla" ]] || return 0

  log "All evaluations complete for cycle ${cycle_id}, processing results"
  process_evaluation_results "${cycle_id}"
}

process_evaluation_results() {
  local cycle_id="$1"
  local eval_dir="${SHARED_DIR}/evaluations/${cycle_id}"
  local result_file="${eval_dir}/result.json"

  # Already processed?
  [[ ! -f "${result_file}" ]] || return 0

  local retune_targets=()

  for target in "${ALL_NODES[@]}"; do
    local retune_votes=0
    local suggested_params=""

    for evaluator in "${ALL_NODES[@]}"; do
      [[ "${evaluator}" != "${target}" ]] || continue
      local eval_file="${eval_dir}/${evaluator}_evaluates_${target}.json"
      [[ -f "${eval_file}" ]] || continue

      local needs_retuning
      needs_retuning=$(jq -r '.needs_retuning // false' "${eval_file}")
      if [[ "${needs_retuning}" == "true" ]]; then
        ((retune_votes++))
        suggested_params=$(jq -r '.suggested_params // {}' "${eval_file}")
      fi
    done

    # 2/3 of evaluators (i.e., both other nodes) agree on retuning
    if [[ ${retune_votes} -ge 2 ]]; then
      retune_targets+=("${target}")
      log "Retuning approved for ${target} (${retune_votes}/2 votes)"
      apply_retuning "${target}" "${cycle_id}"
    fi
  done

  # Write result summary
  local retune_json
  retune_json=$(printf '%s\n' "${retune_targets[@]}" | jq -R . | jq -s .)
  cat > "${result_file}" <<EOF
{
  "cycle_id": "${cycle_id}",
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "retune_targets": ${retune_json},
  "status": "completed"
}
EOF

  # Mark request.json as completed so it won't be re-processed
  local request_file="${eval_dir}/request.json"
  if [[ -f "${request_file}" ]]; then
    local tmp
    tmp=$(mktemp)
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.status = "completed" | .completed_at = $ts' \
      "${request_file}" > "${tmp}" && mv "${tmp}" "${request_file}"
  fi
}

apply_retuning() {
  local target="$1"
  local cycle_id="$2"
  local eval_dir="${SHARED_DIR}/evaluations/${cycle_id}"

  # Collect suggested params from both evaluators
  local new_params="{}"
  for evaluator in "${ALL_NODES[@]}"; do
    [[ "${evaluator}" != "${target}" ]] || continue
    local eval_file="${eval_dir}/${evaluator}_evaluates_${target}.json"
    [[ -f "${eval_file}" ]] || continue

    local suggested
    suggested=$(jq '.suggested_params // {}' "${eval_file}")
    # Merge: average numeric values from suggestions
    new_params=$(echo "${new_params}" "${suggested}" | jq -s '
      .[0] as $base | .[1] as $new |
      ($base // {}) * ($new // {})
    ')
  done

  # Merge new params into target's current params.json
  local target_params_file="${SHARED_DIR}/nodes/${target}/params.json"
  if [[ -f "${target_params_file}" ]]; then
    local merged
    merged=$(jq -s '.[0] * .[1]' "${target_params_file}" <(echo "${new_params}"))
    echo "${merged}" > "${target_params_file}"
    log "Params updated for ${target}: ${merged}"
  fi

  # Also write retune log for audit trail
  local retune_file="${SHARED_DIR}/evaluations/${cycle_id}/retune_${target}.json"
  cat > "${retune_file}" <<EOF
{
  "target": "${target}",
  "cycle_id": "${cycle_id}",
  "new_params": ${new_params},
  "applied_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "applied"
}
EOF

  log "Retune applied for ${target}"
}
