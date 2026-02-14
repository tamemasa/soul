#!/usr/bin/env bash
# research-request.sh - Submit a research/design request to the Soul system
# Usage: research-request.sh <type> "Title" "Description" [reply_to]
#
# type: "research" or "design" only
# Title: Short title for the request
# Description: Detailed description (minimum 10 characters)
# reply_to: (optional) LINE group ID (C...) or user ID (U...) for result notification
#
# Writes a research request JSON file to /suggestions/ volume.
# Brain nodes will detect it and register it as an inbox task automatically.
# No Discord approval required (limited to research/design only).

set -euo pipefail

SUGGESTIONS_DIR="/suggestions"

type="${1:-}"
title="${2:-}"
description="${3:-}"
reply_to="${4:-}"

# Usage check
if [[ -z "${type}" || -z "${title}" ]]; then
  echo "Usage: research-request.sh <type> \"Title\" \"Description\""
  echo ""
  echo "  type:        research | design"
  echo "  Title:       Short title for the request"
  echo "  Description: Detailed description (min 10 characters)"
  echo ""
  echo "Submit a research or design request to the Soul system."
  echo "Brain nodes will pick it up and discuss it automatically."
  exit 1
fi

# Validate type (research/design only)
case "${type}" in
  research|design)
    ;;
  *)
    echo "ERROR: Invalid type '${type}'. Allowed types: research, design"
    exit 1
    ;;
esac

# Validate description
if [[ -z "${description}" ]]; then
  echo "ERROR: Description is required."
  exit 1
fi

if [[ "${#description}" -lt 10 ]]; then
  echo "ERROR: Description must be at least 10 characters (got ${#description})."
  exit 1
fi

# Generate a unique filename
ts=$(date +%s)
rand=$((RANDOM % 9000 + 1000))
filename="research_request_${ts}_${rand}.json"

# Create request JSON
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Write atomically (tmp + mv)
tmp_file="${SUGGESTIONS_DIR}/.tmp_${filename}"
jq -n \
  --arg type "${type}" \
  --arg title "${title}" \
  --arg desc "${description}" \
  --arg submitted_at "${now_iso}" \
  --arg reply_to "${reply_to}" \
  '{
    type: $type,
    title: $title,
    description: $desc,
    status: "pending",
    submitted_at: $submitted_at
  } | if $reply_to != "" then . + {reply_to: $reply_to} else . end' > "${tmp_file}"

mv "${tmp_file}" "${SUGGESTIONS_DIR}/${filename}"

echo "Research request submitted: ${filename}"
echo "Type: ${type}"
echo "Title: ${title}"
echo "Brain nodes will pick this up automatically."
