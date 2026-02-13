#!/usr/bin/env bash
# rebuild-manager.sh - Cross-node container rebuild protocol
#
# Problem: Triceratops cannot rebuild itself (the process would die).
# Solution: Triceratops writes a rebuild request; Gorilla approves; Panda executes.
#
# Flow:
#   1. Triceratops creates /shared/rebuild_requests/{id}.json with status "pending_approval"
#   2. Gorilla's daemon detects it, verifies the consensus decision, and approves
#   3. Panda's daemon detects approved requests and executes the rebuild
#   4. Result is recorded in the same file
#
# Dual-approval ensures both Gorilla (coordinator) and Panda (executor) agree
# on the rebuild before it happens. The original task must also be approved
# through the normal consensus process.

REBUILD_DIR="${SHARED_DIR}/rebuild_requests"

# Request a container rebuild (called by triceratops during task execution)
# Usage: request_rebuild <service_name> <task_id> <reason>
request_rebuild() {
  local service="$1"
  local task_id="$2"
  local reason="$3"

  mkdir -p "${REBUILD_DIR}"

  local req_id="rebuild_$(date +%s)_$((RANDOM % 10000))"
  local req_file="${REBUILD_DIR}/${req_id}.json"
  local tmp
  tmp=$(mktemp)

  cat > "${tmp}" <<EOF
{
  "id": "${req_id}",
  "service": "${service}",
  "task_id": "${task_id}",
  "requested_by": "${NODE_NAME}",
  "reason": "${reason}",
  "status": "pending_approval",
  "requested_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  mv "${tmp}" "${req_file}"

  log "Rebuild requested: ${service} (request: ${req_id}, task: ${task_id})"
  echo "${req_id}"
}

# Wait for a rebuild request to complete (called by requester)
# Usage: wait_for_rebuild <req_id> [timeout_seconds]
# Returns 0 on success, 1 on failure/timeout
wait_for_rebuild() {
  local req_id="$1"
  local timeout="${2:-300}"  # Default 5 min timeout
  local req_file="${REBUILD_DIR}/${req_id}.json"
  local elapsed=0
  local interval=5

  while [[ ${elapsed} -lt ${timeout} ]]; do
    if [[ -f "${req_file}" ]]; then
      local status
      status=$(jq -r '.status' "${req_file}" 2>/dev/null)
      case "${status}" in
        completed)
          log "Rebuild ${req_id} completed successfully"
          return 0
          ;;
        failed|rejected)
          local error
          error=$(jq -r '.error // "unknown error"' "${req_file}")
          log "Rebuild ${req_id} ${status}: ${error}"
          return 1
          ;;
      esac
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  log "Rebuild ${req_id} timed out after ${timeout}s"
  return 1
}

# Check for pending_approval rebuild requests and approve them (called by gorilla's daemon)
# Gorilla validates the consensus decision and approves the rebuild for panda to execute.
check_rebuild_approvals() {
  # Only gorilla handles approvals
  [[ "${NODE_NAME}" == "gorilla" ]] || return 0

  mkdir -p "${REBUILD_DIR}"

  for req_file in "${REBUILD_DIR}"/*.json; do
    [[ -f "${req_file}" ]] || continue

    local status
    status=$(jq -r '.status' "${req_file}" 2>/dev/null)
    [[ "${status}" == "pending_approval" || "${status}" == "pending" ]] || continue

    local req_id service task_id requested_by
    req_id=$(jq -r '.id' "${req_file}")
    service=$(jq -r '.service' "${req_file}")
    task_id=$(jq -r '.task_id' "${req_file}")
    requested_by=$(jq -r '.requested_by' "${req_file}")

    log "Rebuild approval request detected: ${req_id} (service: ${service}, from: ${requested_by})"

    # Validate: only allow rebuild of brain-triceratops
    local allowed_services=("brain-triceratops")
    local is_allowed=false
    for allowed in "${allowed_services[@]}"; do
      if [[ "${service}" == "${allowed}" ]]; then
        is_allowed=true
        break
      fi
    done

    if [[ "${is_allowed}" != "true" ]]; then
      log "REJECTED rebuild ${req_id}: service '${service}' is not in allowed list"
      local tmp
      tmp=$(mktemp)
      jq '.status = "rejected" | .error = "service not in allowed rebuild list" | .rejected_by = "gorilla" | .rejected_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
      continue
    fi

    # Validate: must have an associated task_id
    if [[ -z "${task_id}" || "${task_id}" == "null" ]]; then
      log "REJECTED rebuild ${req_id}: no associated task_id"
      local tmp
      tmp=$(mktemp)
      jq '.status = "rejected" | .error = "no associated consensus task_id" | .rejected_by = "gorilla" | .rejected_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
      continue
    fi

    # Verify the task was approved through consensus
    local decision_file="${SHARED_DIR}/decisions/${task_id}.json"
    if [[ ! -f "${decision_file}" ]]; then
      log "REJECTED rebuild ${req_id}: no decision file for task ${task_id}"
      local tmp
      tmp=$(mktemp)
      jq '.status = "rejected" | .error = "no consensus decision found for task" | .rejected_by = "gorilla" | .rejected_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
      continue
    fi

    local decision
    decision=$(jq -r '.decision' "${decision_file}" 2>/dev/null)
    if [[ "${decision}" != "approved" ]]; then
      log "REJECTED rebuild ${req_id}: task ${task_id} decision is '${decision}', not 'approved'"
      local tmp
      tmp=$(mktemp)
      jq '.status = "rejected" | .error = "task was not approved through consensus" | .rejected_by = "gorilla" | .rejected_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
      continue
    fi

    # All validations passed — approve for panda to execute
    log "APPROVED rebuild ${req_id}: consensus verified, forwarding to panda for execution"
    local tmp
    tmp=$(mktemp)
    jq '.status = "approved" | .approved_by = "gorilla" | .approved_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
      "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
  done
}

# Check for approved rebuild requests and execute them (called by panda's daemon)
# Panda only executes rebuilds that have been approved by gorilla.
check_rebuild_requests() {
  # Only panda executes rebuilds
  [[ "${NODE_NAME}" == "panda" ]] || return 0

  mkdir -p "${REBUILD_DIR}"

  for req_file in "${REBUILD_DIR}"/*.json; do
    [[ -f "${req_file}" ]] || continue

    local status
    status=$(jq -r '.status' "${req_file}" 2>/dev/null)
    [[ "${status}" == "approved" ]] || continue

    local req_id service task_id requested_by
    req_id=$(jq -r '.id' "${req_file}")
    service=$(jq -r '.service' "${req_file}")
    task_id=$(jq -r '.task_id' "${req_file}")
    requested_by=$(jq -r '.requested_by' "${req_file}")

    log "Approved rebuild request detected: ${req_id} (service: ${service}, approved by gorilla)"

    # Panda's own validation: verify service is allowed
    local allowed_services=("brain-triceratops")
    local is_allowed=false
    for allowed in "${allowed_services[@]}"; do
      if [[ "${service}" == "${allowed}" ]]; then
        is_allowed=true
        break
      fi
    done

    if [[ "${is_allowed}" != "true" ]]; then
      log "REJECTED rebuild ${req_id}: service '${service}' not in panda's allowed list"
      local tmp
      tmp=$(mktemp)
      jq '.status = "failed" | .error = "service not in allowed rebuild list (panda check)" | .executed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
      continue
    fi

    # Panda's own validation: verify consensus decision still holds
    local decision_file="${SHARED_DIR}/decisions/${task_id}.json"
    if [[ -f "${decision_file}" ]]; then
      local decision
      decision=$(jq -r '.decision' "${decision_file}" 2>/dev/null)
      if [[ "${decision}" != "approved" ]]; then
        log "REJECTED rebuild ${req_id}: decision no longer approved"
        local tmp
        tmp=$(mktemp)
        jq '.status = "failed" | .error = "decision no longer approved (panda check)" | .executed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
          "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
        continue
      fi
    fi

    # Execute the rebuild
    execute_rebuild "${req_file}" "${service}" "${req_id}"
  done
}

# Execute a validated rebuild request
execute_rebuild() {
  local req_file="$1"
  local service="$2"
  local req_id="$3"

  # Mark as executing
  local tmp
  tmp=$(mktemp)
  jq '.status = "executing" | .executor = "panda" | .execution_started_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"

  set_activity "rebuilding" "\"service\":\"${service}\",\"rebuild_id\":\"${req_id}\","
  log "Executing rebuild of ${service} (request: ${req_id})"

  # Determine the host-side compose project directory from the target container's
  # label. This is the host PWD used when docker compose originally created it.
  local host_project_dir
  host_project_dir=$(docker inspect "soul-${service}" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
  if [[ -z "${host_project_dir}" ]]; then
    host_project_dir=$(docker inspect soul-brain-triceratops --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
  fi
  if [[ -z "${host_project_dir}" ]]; then
    host_project_dir="/soul"
  fi

  # Locate docker-compose.yml: try /soul first (works if mount matches),
  # then fall back to copying from a container that has it mounted correctly.
  local compose_file="/soul/docker-compose.yml"
  if [[ ! -f "${compose_file}" ]]; then
    log "Rebuild: docker-compose.yml not at /soul, copying from container"
    local tmp_compose
    tmp_compose=$(mktemp /tmp/docker-compose.XXXXXX.yml)
    docker cp "soul-${service}:/soul/docker-compose.yml" "${tmp_compose}" 2>/dev/null || \
    docker cp "soul-brain-triceratops:/soul/docker-compose.yml" "${tmp_compose}" 2>/dev/null || \
    docker cp "soul-brain-gorilla:/soul/docker-compose.yml" "${tmp_compose}" 2>/dev/null
    if [[ -s "${tmp_compose}" ]]; then
      compose_file="${tmp_compose}"
    else
      rm -f "${tmp_compose}"
      log "ERROR: Could not locate docker-compose.yml"
      tmp=$(mktemp)
      jq '.status = "failed" | .error = "docker-compose.yml not found" | .failed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
      set_activity "idle"
      return 1
    fi
  fi

  # Execute the rebuild.
  # PWD is overridden to the host path so ${PWD} in docker-compose.yml
  # resolves to the correct host directory for bind mounts.
  local rebuild_output
  local rebuild_exit_code
  rebuild_output=$(PWD="${host_project_dir}" docker compose \
    --project-directory "${host_project_dir}" \
    -f "${compose_file}" \
    up -d --build "${service}" 2>&1)
  rebuild_exit_code=$?

  # Clean up temp compose file if used
  [[ "${compose_file}" == /tmp/* ]] && rm -f "${compose_file}"

  # If compose build fails (e.g. missing build context), fall back to docker restart.
  # This works when files were already injected via docker cp.
  if [[ ${rebuild_exit_code} -ne 0 ]] && echo "${rebuild_output}" | grep -q "unable to prepare context"; then
    log "Rebuild: compose build failed, falling back to docker restart for soul-${service}"
    rebuild_output=$(docker restart "soul-${service}" 2>&1)
    rebuild_exit_code=$?
    sleep 3
  fi

  # Wait a moment for the container to start
  sleep 5

  # Verify the container is running
  local container_status
  container_status=$(docker ps --filter "name=soul-${service}" --format '{{.Status}}' 2>/dev/null)

  if [[ ${rebuild_exit_code} -eq 0 && -n "${container_status}" ]]; then
    log "Rebuild of ${service} completed successfully: ${container_status}"
    local escaped_output
    escaped_output=$(echo "${rebuild_output}" | jq -Rs .)
    tmp=$(mktemp)
    jq --arg output "${rebuild_output}" --arg cs "${container_status}" \
      '.status = "completed" | .completed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .container_status = $cs | .output = $output' \
      "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
  else
    log "ERROR: Rebuild of ${service} failed (exit: ${rebuild_exit_code})"
    tmp=$(mktemp)
    jq --arg output "${rebuild_output}" \
      '.status = "failed" | .error = "rebuild command failed" | .output = $output | .failed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
      "${req_file}" > "${tmp}" && mv "${tmp}" "${req_file}"
  fi

  set_activity "idle"
}
