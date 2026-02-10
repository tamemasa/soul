#!/usr/bin/env bash
# worker-manager.sh - Worker node lifecycle management

WORKERS_DIR="${SHARED_DIR}/workers"

check_worker_status() {
  mkdir -p "${WORKERS_DIR}"
  for worker_dir in "${WORKERS_DIR}"/*/; do
    [[ -d "${worker_dir}" ]] || continue

    local status_file="${worker_dir}/status.json"
    [[ -f "${status_file}" ]] || continue

    local worker_status
    worker_status=$(jq -r '.status' "${status_file}")

    case "${worker_status}" in
      requested)
        # A decision has been made to create this worker
        if [[ "${NODE_NAME}" == "gorilla" ]]; then
          create_worker "$(basename "${worker_dir}")"
        fi
        ;;
      running)
        # Periodic health check could go here
        ;;
    esac
  done
}

create_worker() {
  local worker_name="$1"
  local worker_dir="${WORKERS_DIR}/${worker_name}"
  local config_file="${worker_dir}/config.json"

  [[ -f "${config_file}" ]] || return 0

  log "Creating worker: ${worker_name}"

  # Update status
  local tmp
  tmp=$(mktemp)
  jq '.status = "creating" | .creating_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "${worker_dir}/status.json" > "${tmp}" && mv "${tmp}" "${worker_dir}/status.json"

  # Worker creation writes a compose override file
  # that the host can pick up via docker compose -f
  local template
  template=$(jq -r '.template // "default"' "${config_file}")
  local compose_override="${worker_dir}/docker-compose.worker.yml"

  cat > "${compose_override}" <<EOF
services:
  worker-${worker_name}:
    build:
      context: ./worker
    container_name: soul-worker-${worker_name}
    environment:
      - WORKER_NAME=${worker_name}
      - ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY}
    volumes:
      - shared:/shared
      - ./worker/templates/${template}:/worker/config:ro
    restart: unless-stopped
EOF

  # Update status to pending_deploy
  tmp=$(mktemp)
  jq '.status = "pending_deploy" | .compose_file = "'"${compose_override}"'"' \
    "${worker_dir}/status.json" > "${tmp}" && mv "${tmp}" "${worker_dir}/status.json"

  log "Worker ${worker_name} compose file created, pending deployment"
}

request_worker() {
  local worker_name="$1"
  local template="$2"
  local description="$3"
  local worker_dir="${WORKERS_DIR}/${worker_name}"

  mkdir -p "${worker_dir}"

  cat > "${worker_dir}/config.json" <<EOF
{
  "name": "${worker_name}",
  "template": "${template}",
  "description": "${description}",
  "requested_by": "${NODE_NAME}",
  "requested_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  cat > "${worker_dir}/status.json" <<EOF
{
  "worker": "${worker_name}",
  "status": "requested",
  "requested_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  log "Worker ${worker_name} requested"
}
