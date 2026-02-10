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
      # Only one node should run consensus (use alphabetical first: gorilla)
      # This prevents duplicate consensus checks
      if [[ "${NODE_NAME}" == "gorilla" ]]; then
        log "All nodes responded in round ${current_round} for ${task_id}, checking consensus"
        evaluate_consensus "${task_id}" "${current_round}"
      fi
    fi
  done
}

check_pending_decisions() {
  local decisions_dir="${SHARED_DIR}/decisions"
  for decision_file in "${decisions_dir}"/*.json; do
    [[ -f "${decision_file}" ]] || continue

    local decision_status executor
    decision_status=$(jq -r '.status' "${decision_file}")
    executor=$(jq -r '.executor // ""' "${decision_file}")

    # Only execute decisions assigned to this node or unassigned
    if [[ "${decision_status}" == "approved" ]]; then
      if [[ -z "${executor}" || "${executor}" == "${NODE_NAME}" ]]; then
        local task_id
        task_id=$(jq -r '.task_id' "${decision_file}")
        log "Executing decision for task: ${task_id}"
        execute_decision "${decision_file}"
      fi
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
