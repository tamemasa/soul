#!/usr/bin/env bash
# Docker Command Guard - prevents brain nodes from running destructive
# docker commands against their own container.
# Installed as /usr/local/bin/docker (PATH priority over /usr/bin/docker).

REAL_DOCKER="/usr/bin/docker"

# Pass through if not in a brain node context
if [[ -z "${NODE_NAME:-}" ]]; then
  exec "${REAL_DOCKER}" "$@"
fi

SELF_CONTAINER="soul-brain-${NODE_NAME}"
SELF_SERVICE="brain-${NODE_NAME}"
args_str="$*"
blocked=false
reason=""

# Block bare 'docker compose down' (stops everything)
if [[ "${args_str}" =~ compose[[:space:]].*down([[:space:]]|$) ]]; then
  if ! [[ "${args_str}" =~ down[[:space:]]+[a-zA-Z] ]]; then
    blocked=true
    reason="'docker compose down' stops all containers including self"
  fi
fi

# Block destructive single-container commands targeting self
for cmd in stop rm kill restart; do
  if [[ "${args_str}" =~ ${cmd}.*${SELF_CONTAINER} ]] || [[ "${args_str}" =~ ${cmd}.*${SELF_SERVICE} ]]; then
    blocked=true
    reason="'docker ${cmd}' targeting own container"
  fi
done

# Block docker compose operations targeting own service
if [[ "${args_str}" =~ compose.*(up|restart|stop|rm).*${SELF_SERVICE} ]]; then
  blocked=true
  reason="'docker compose' operation targeting own service"
fi

# Block docker cp into own container
if [[ "${args_str}" =~ cp.*${SELF_CONTAINER}: ]]; then
  blocked=true
  reason="'docker cp' into own container"
fi

if [[ "${blocked}" == "true" ]]; then
  echo "ERROR: [docker-guard] BLOCKED: docker $*" >&2
  echo "ERROR: [docker-guard] Reason: ${reason}" >&2
  echo "ERROR: [docker-guard] Use request_rebuild() for self-rebuild instead." >&2
  # Log to shared directory
  local_log_dir="/shared/logs/$(date -u +%Y-%m-%d)"
  mkdir -p "${local_log_dir}" 2>/dev/null
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [docker-guard] [${NODE_NAME}] BLOCKED: docker $* (${reason})" \
    >> "${local_log_dir}/${NODE_NAME}.log" 2>/dev/null
  exit 1
fi

exec "${REAL_DOCKER}" "$@"
