#!/usr/bin/env bash
# check-research-result.sh - Check the status/result of a research request
# Usage: check-research-result.sh [request_filename]
#
# Without arguments: lists all research requests and their status
# With argument: shows details of a specific request

set -euo pipefail

SUGGESTIONS_DIR="/suggestions"

request_file="${1:-}"

# List all research requests if no argument
if [[ -z "${request_file}" ]]; then
  echo "=== Research Requests ==="
  echo ""
  found=false
  for f in "${SUGGESTIONS_DIR}"/research_request_*.json; do
    [[ -f "${f}" ]] || continue
    found=true
    local_filename=$(basename "${f}")
    status=$(jq -r '.status // "unknown"' "${f}" 2>/dev/null)
    title=$(jq -r '.title // "no title"' "${f}" 2>/dev/null)
    type=$(jq -r '.type // "unknown"' "${f}" 2>/dev/null)
    task_id=$(jq -r '.task_id // "-"' "${f}" 2>/dev/null)

    echo "[${status}] ${local_filename}"
    echo "  Type: ${type} | Title: ${title}"
    if [[ "${task_id}" != "-" ]]; then
      echo "  Task ID: ${task_id}"
    fi

    # Check for result file
    if [[ "${task_id}" != "-" ]]; then
      result_file="${SUGGESTIONS_DIR}/research_result_${task_id}.json"
      if [[ -f "${result_file}" ]]; then
        result_status=$(jq -r '.decision // "unknown"' "${result_file}" 2>/dev/null)
        echo "  Result: ${result_status} (see research_result_${task_id}.json)"
      fi
    fi
    echo ""
  done

  if [[ "${found}" == "false" ]]; then
    echo "No research requests found."
  fi
  exit 0
fi

# Show specific request
target="${SUGGESTIONS_DIR}/${request_file}"
if [[ ! -f "${target}" ]]; then
  echo "ERROR: File not found: ${request_file}"
  exit 1
fi

echo "=== Request Details ==="
jq . "${target}"

# Check for associated result
task_id=$(jq -r '.task_id // ""' "${target}" 2>/dev/null)
if [[ -n "${task_id}" ]]; then
  result_file="${SUGGESTIONS_DIR}/research_result_${task_id}.json"
  if [[ -f "${result_file}" ]]; then
    echo ""
    echo "=== Research Result ==="
    jq . "${result_file}"
  else
    echo ""
    echo "Result not yet available. Task ${task_id} is still being processed."
  fi
fi
