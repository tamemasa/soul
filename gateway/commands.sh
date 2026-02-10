#!/usr/bin/env bash
# commands.sh - Soul chat interface command implementations

ALL_NODES=("panda" "gorilla" "triceratops")

# Docker command wrapper: try direct, then sg docker, then sudo
_docker() {
  if docker "$@" 2>/dev/null; then
    return 0
  elif sg docker -c "docker $*" 2>/dev/null; then
    return 0
  else
    sudo docker "$@" 2>/dev/null
  fi
}

# ─── Task Submission ───────────────────────────────────────────

cmd_submit_task() {
  local description="$1"
  local task_id="task_$(date +%s)_$(shuf -i 1000-9999 -n 1)"
  local task_file="${SHARED_DIR}/inbox/${task_id}.json"

  local escaped_desc
  escaped_desc=$(echo "${description}" | jq -Rs .)

  mkdir -p "${SHARED_DIR}/inbox"
  cat > "${task_file}" <<EOF
{
  "id": "${task_id}",
  "type": "task",
  "title": ${escaped_desc},
  "description": ${escaped_desc},
  "priority": "medium",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "pending"
}
EOF

  echo -e "${GREEN}Task submitted: ${BOLD}${task_id}${NC}"
  echo -e "${DIM}The Brains will pick it up and start discussing.${NC}"
  echo -e "${DIM}Track with: /discussion ${task_id}${NC}"
}

cmd_ask_question() {
  local question="$1"
  local task_id="ask_$(date +%s)_$(shuf -i 1000-9999 -n 1)"
  local task_file="${SHARED_DIR}/inbox/${task_id}.json"

  local escaped_q
  escaped_q=$(echo "${question}" | jq -Rs .)

  mkdir -p "${SHARED_DIR}/inbox"
  cat > "${task_file}" <<EOF
{
  "id": "${task_id}",
  "type": "question",
  "title": ${escaped_q},
  "description": ${escaped_q},
  "priority": "medium",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "pending"
}
EOF

  echo -e "${GREEN}Question submitted: ${BOLD}${task_id}${NC}"
  echo -e "${DIM}The Brains will discuss and provide their perspectives.${NC}"
}

# ─── System Status ─────────────────────────────────────────────

cmd_status() {
  echo -e "${BOLD}═══ Soul System Status ═══${NC}"
  echo ""

  # Node status
  echo -e "${BOLD}Brain Nodes:${NC}"
  for node in "${ALL_NODES[@]}"; do
    local container="soul-brain-${node}"
    local status
    status=$(_docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null | tr -d '\n' || true)
    status="${status:-not found}"
    local color="${RED}"
    [[ "${status}" == "running" ]] && color="${GREEN}"
    echo -e "  ${color}●${NC} ${BOLD}${node}${NC} (${status})"
  done
  echo ""

  # Scheduler
  local sched_status
  sched_status=$(_docker inspect -f '{{.State.Status}}' "soul-scheduler" 2>/dev/null | tr -d '\n' || true)
  sched_status="${sched_status:-not found}"
  local sched_color="${RED}"
  [[ "${sched_status}" == "running" ]] && sched_color="${GREEN}"
  echo -e "${BOLD}Scheduler:${NC} ${sched_color}●${NC} ${sched_status}"
  echo ""

  # Inbox count
  local inbox_count=0
  if [[ -d "${SHARED_DIR}/inbox" ]]; then
    inbox_count=$(find "${SHARED_DIR}/inbox" -name "*.json" 2>/dev/null | wc -l)
  fi
  echo -e "${BOLD}Pending tasks:${NC} ${inbox_count}"

  # Active discussions
  local disc_count=0
  if [[ -d "${SHARED_DIR}/discussions" ]]; then
    for d in "${SHARED_DIR}/discussions"/*/status.json; do
      [[ -f "${d}" ]] || continue
      local s
      s=$(jq -r '.status' "${d}" 2>/dev/null)
      [[ "${s}" == "discussing" ]] && ((disc_count++))
    done
  fi
  echo -e "${BOLD}Active discussions:${NC} ${disc_count}"

  # Decisions
  local decided_count=0
  if [[ -d "${SHARED_DIR}/decisions" ]]; then
    decided_count=$(find "${SHARED_DIR}/decisions" -name "*.json" ! -name "*_result.json" 2>/dev/null | wc -l)
  fi
  echo -e "${BOLD}Total decisions:${NC} ${decided_count}"

  # Workers
  local worker_count=0
  if [[ -d "${SHARED_DIR}/workers" ]]; then
    worker_count=$(find "${SHARED_DIR}/workers" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
  fi
  echo -e "${BOLD}Workers:${NC} ${worker_count}"
}

# ─── Discussions ───────────────────────────────────────────────

cmd_list_discussions() {
  echo -e "${BOLD}═══ Discussions ═══${NC}"
  echo ""

  if [[ ! -d "${SHARED_DIR}/discussions" ]]; then
    echo -e "${DIM}No discussions yet.${NC}"
    return
  fi

  local found=false
  for discussion_dir in "${SHARED_DIR}/discussions"/*/; do
    [[ -d "${discussion_dir}" ]] || continue
    found=true

    local task_id
    task_id=$(basename "${discussion_dir}")
    local status_file="${discussion_dir}/status.json"

    if [[ -f "${status_file}" ]]; then
      local status current_round started_at
      status=$(jq -r '.status // "unknown"' "${status_file}")
      current_round=$(jq -r '.current_round // "?"' "${status_file}")
      started_at=$(jq -r '.started_at // ""' "${status_file}")

      local status_color="${YELLOW}"
      case "${status}" in
        decided) status_color="${GREEN}" ;;
        discussing) status_color="${CYAN}" ;;
        executing) status_color="${BLUE}" ;;
      esac

      local title="(no title)"
      if [[ -f "${discussion_dir}/task.json" ]]; then
        title=$(jq -r '.title // "(no title)"' "${discussion_dir}/task.json")
      fi

      echo -e "  ${status_color}[${status}]${NC} ${BOLD}${task_id}${NC} (round ${current_round})"
      echo -e "    ${title}"
      echo -e "    ${DIM}${started_at}${NC}"
    fi
  done

  if [[ "${found}" == "false" ]]; then
    echo -e "${DIM}No discussions yet.${NC}"
  fi
}

cmd_show_discussion() {
  local task_id="$1"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"

  if [[ ! -d "${discussion_dir}" ]]; then
    echo -e "${RED}Discussion not found: ${task_id}${NC}"
    return
  fi

  echo -e "${BOLD}═══ Discussion: ${task_id} ═══${NC}"
  echo ""

  # Show task
  if [[ -f "${discussion_dir}/task.json" ]]; then
    local title description
    title=$(jq -r '.title // ""' "${discussion_dir}/task.json")
    description=$(jq -r '.description // ""' "${discussion_dir}/task.json")
    echo -e "${BOLD}Task:${NC} ${title}"
    echo -e "${DIM}${description}${NC}"
    echo ""
  fi

  # Show status
  if [[ -f "${discussion_dir}/status.json" ]]; then
    local status current_round
    status=$(jq -r '.status' "${discussion_dir}/status.json")
    current_round=$(jq -r '.current_round' "${discussion_dir}/status.json")
    echo -e "${BOLD}Status:${NC} ${status} (round ${current_round})"
    echo ""
  fi

  # Show each round
  for round_dir in "${discussion_dir}"/round_*/; do
    [[ -d "${round_dir}" ]] || continue
    local round_num
    round_num=$(basename "${round_dir}" | sed 's/round_//')
    echo -e "${BOLD}── Round ${round_num} ──${NC}"

    for node in "${ALL_NODES[@]}"; do
      local resp="${round_dir}/${node}.json"
      if [[ -f "${resp}" ]]; then
        local vote opinion
        vote=$(jq -r '.vote // "?"' "${resp}")
        opinion=$(jq -r '.opinion // ""' "${resp}")

        local vote_color="${YELLOW}"
        case "${vote}" in
          approve) vote_color="${GREEN}" ;;
          reject) vote_color="${RED}" ;;
        esac

        local node_color="${NC}"
        case "${node}" in
          panda) node_color="${BLUE}" ;;
          gorilla) node_color="${RED}" ;;
          triceratops) node_color="${MAGENTA}" ;;
        esac

        echo -e "  ${node_color}${BOLD}${node}${NC} ${vote_color}[${vote}]${NC}"
        echo -e "    ${opinion}" | head -5
        echo ""
      fi
    done
  done

  # Show decision if exists
  local decision_file="${SHARED_DIR}/decisions/${task_id}.json"
  if [[ -f "${decision_file}" ]]; then
    local decision executor
    decision=$(jq -r '.decision // ""' "${decision_file}")
    executor=$(jq -r '.executor // ""' "${decision_file}")
    echo -e "${BOLD}── Decision ──${NC}"
    echo -e "  Result: ${GREEN}${decision}${NC}"
    echo -e "  Executor: ${executor}"

    local result_file="${SHARED_DIR}/decisions/${task_id}_result.json"
    if [[ -f "${result_file}" ]]; then
      local result
      result=$(jq -r '.result // ""' "${result_file}")
      echo -e "${BOLD}── Execution Result ──${NC}"
      echo -e "  ${result}" | head -20
    fi
  fi
}

# ─── Decisions ─────────────────────────────────────────────────

cmd_list_decisions() {
  echo -e "${BOLD}═══ Decisions ═══${NC}"
  echo ""

  if [[ ! -d "${SHARED_DIR}/decisions" ]]; then
    echo -e "${DIM}No decisions yet.${NC}"
    return
  fi

  local found=false
  for decision_file in "${SHARED_DIR}/decisions"/*.json; do
    [[ -f "${decision_file}" ]] || continue
    [[ "${decision_file}" != *_result.json ]] || continue
    found=true

    local task_id decision status decided_at
    task_id=$(jq -r '.task_id // "?"' "${decision_file}")
    decision=$(jq -r '.decision // "?"' "${decision_file}")
    status=$(jq -r '.status // "?"' "${decision_file}")
    decided_at=$(jq -r '.decided_at // ""' "${decision_file}")

    local dec_color="${YELLOW}"
    case "${status}" in
      approved) dec_color="${GREEN}" ;;
      completed) dec_color="${CYAN}" ;;
      rejected) dec_color="${RED}" ;;
    esac

    echo -e "  ${dec_color}[${status}]${NC} ${BOLD}${task_id}${NC} → ${decision}"
    echo -e "    ${DIM}${decided_at}${NC}"
  done

  if [[ "${found}" == "false" ]]; then
    echo -e "${DIM}No decisions yet.${NC}"
  fi
}

# ─── Evaluation ────────────────────────────────────────────────

cmd_trigger_eval() {
  local cycle_id="eval_manual_$(date +%s)"
  local eval_dir="${SHARED_DIR}/evaluations/${cycle_id}"

  mkdir -p "${eval_dir}"
  cat > "${eval_dir}/request.json" <<EOF
{
  "cycle_id": "${cycle_id}",
  "type": "manual_evaluation",
  "status": "pending",
  "triggered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "triggered_by": "user"
}
EOF

  echo -e "${GREEN}Evaluation cycle triggered: ${BOLD}${cycle_id}${NC}"
  echo -e "${DIM}The Brains will evaluate each other and report results.${NC}"
}

# ─── Parameters ────────────────────────────────────────────────

cmd_show_params() {
  local target_node="$1"

  echo -e "${BOLD}═══ Brain Parameters ═══${NC}"
  echo ""

  for node in "${ALL_NODES[@]}"; do
    [[ -z "${target_node}" || "${target_node}" == "${node}" ]] || continue

    local params_file="${SHARED_DIR}/nodes/${node}/params.json"
    if [[ -f "${params_file}" ]]; then
      local node_color="${NC}"
      case "${node}" in
        panda) node_color="${BLUE}" ;;
        gorilla) node_color="${RED}" ;;
        triceratops) node_color="${MAGENTA}" ;;
      esac

      echo -e "  ${node_color}${BOLD}${node}${NC}:"
      jq -r 'to_entries[] | "    \(.key): \(.value)"' "${params_file}"
      echo ""
    fi
  done
}

cmd_set_param() {
  local node="$1"
  local key="$2"
  local value="$3"

  if [[ -z "${node}" || -z "${key}" || -z "${value}" ]]; then
    echo -e "${RED}Usage: /set <node> <key> <value>${NC}"
    echo -e "${DIM}Example: /set panda risk_tolerance 0.3${NC}"
    return
  fi

  local params_file="${SHARED_DIR}/nodes/${node}/params.json"
  if [[ ! -f "${params_file}" ]]; then
    echo -e "${RED}Node not found: ${node}${NC}"
    return
  fi

  local tmp
  tmp=$(mktemp)
  jq ".${key} = ${value}" "${params_file}" > "${tmp}" && mv "${tmp}" "${params_file}"

  echo -e "${GREEN}Updated ${BOLD}${node}.${key}${NC}${GREEN} = ${value}${NC}"
  echo -e "${DIM}Changes take effect on next task processing cycle.${NC}"
  echo -e "${DIM}For immediate effect, restart the node: /restart ${node}${NC}"
}

# ─── Workers ───────────────────────────────────────────────────

cmd_list_workers() {
  echo -e "${BOLD}═══ Worker Nodes ═══${NC}"
  echo ""

  if [[ ! -d "${SHARED_DIR}/workers" ]]; then
    echo -e "${DIM}No workers configured yet.${NC}"
    return
  fi

  local found=false
  for worker_dir in "${SHARED_DIR}/workers"/*/; do
    [[ -d "${worker_dir}" ]] || continue
    found=true

    local worker_name
    worker_name=$(basename "${worker_dir}")
    local status_file="${worker_dir}/status.json"

    local status="unknown"
    if [[ -f "${status_file}" ]]; then
      status=$(jq -r '.status // "unknown"' "${status_file}")
    fi

    local status_color="${YELLOW}"
    case "${status}" in
      running) status_color="${GREEN}" ;;
      requested|pending_deploy) status_color="${CYAN}" ;;
      error) status_color="${RED}" ;;
    esac

    echo -e "  ${status_color}●${NC} ${BOLD}${worker_name}${NC} (${status})"
  done

  if [[ "${found}" == "false" ]]; then
    echo -e "${DIM}No workers configured yet.${NC}"
  fi
}

# ─── Logs ──────────────────────────────────────────────────────

cmd_show_logs() {
  local target="${1:-}"
  local lines="${2:-20}"

  echo -e "${BOLD}═══ Recent Logs ═══${NC}"
  echo ""

  local today
  today=$(date -u +%Y-%m-%d)
  local log_dir="${SHARED_DIR}/logs/${today}"

  if [[ ! -d "${log_dir}" ]]; then
    echo -e "${DIM}No logs for today (${today}).${NC}"
    return
  fi

  for log_file in "${log_dir}"/*.log; do
    [[ -f "${log_file}" ]] || continue

    local log_name
    log_name=$(basename "${log_file}" .log)

    [[ -z "${target}" || "${target}" == "${log_name}" ]] || continue

    local node_color="${NC}"
    case "${log_name}" in
      panda) node_color="${BLUE}" ;;
      gorilla) node_color="${RED}" ;;
      triceratops) node_color="${MAGENTA}" ;;
      scheduler) node_color="${YELLOW}" ;;
    esac

    echo -e "  ${node_color}${BOLD}── ${log_name} ──${NC}"
    tail -n "${lines}" "${log_file}" | while IFS= read -r line; do
      echo -e "    ${DIM}${line}${NC}"
    done
    echo ""
  done
}

# ─── Node Management ──────────────────────────────────────────

cmd_restart_node() {
  local node="$1"

  if [[ -z "${node}" ]]; then
    echo -e "${RED}Usage: /restart <node>${NC}"
    return
  fi

  local container="soul-brain-${node}"
  echo -e "${YELLOW}Restarting ${BOLD}${container}${NC}${YELLOW}...${NC}"

  if _docker restart "${container}" 2>/dev/null; then
    echo -e "${GREEN}${container} restarted successfully.${NC}"
  else
    echo -e "${RED}Failed to restart ${container}. Is it running?${NC}"
  fi
}
