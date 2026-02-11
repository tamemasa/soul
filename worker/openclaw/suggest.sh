#!/usr/bin/env bash
# suggest.sh - Submit a suggestion to the Soul system
# Usage: suggest.sh "Title" ["Description"]
#
# Writes a suggestion JSON file to /suggestions/ volume.
# The Soul system (triceratops) picks it up, validates, rate-limits (1/hour),
# and registers it as a low-priority task for Brain node review.
#
# Rate limiting is enforced on the Soul system side.
# If multiple suggestions are written within 1 hour, only the first is accepted.

set -euo pipefail

SUGGESTIONS_DIR="/suggestions"
RATELIMIT_FILE="${SUGGESTIONS_DIR}/.last_submitted"

title="${1:-}"
description="${2:-}"

if [[ -z "${title}" ]]; then
  echo "Usage: suggest.sh \"Title\" [\"Description\"]"
  echo "Submit a suggestion to the Soul system."
  echo "Limited to 1 suggestion per hour."
  exit 1
fi

# Client-side rate limit check (courtesy; real enforcement is on Soul side)
if [[ -f "${RATELIMIT_FILE}" ]]; then
  last_epoch=$(cat "${RATELIMIT_FILE}" 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  elapsed=$((now_epoch - last_epoch))
  if [[ ${elapsed} -lt 3600 ]]; then
    remaining=$(( (3600 - elapsed) / 60 ))
    echo "Rate limited. Next suggestion allowed in ${remaining} minute(s)."
    exit 1
  fi
fi

# Generate a unique filename
ts=$(date +%s)
rand=$((RANDOM % 9000 + 1000))
filename="suggestion_${ts}_${rand}.json"

# Create suggestion JSON
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Write atomically (tmp + mv)
tmp_file="${SUGGESTIONS_DIR}/.tmp_${filename}"
cat > "${tmp_file}" <<EOF
{
  "title": $(printf '%s' "${title}" | jq -Rs .),
  "description": $(printf '%s' "${description}" | jq -Rs .),
  "submitted_at": "${now_iso}"
}
EOF

mv "${tmp_file}" "${SUGGESTIONS_DIR}/${filename}"

# Update client-side rate limit
date +%s > "${RATELIMIT_FILE}"

echo "Suggestion submitted: ${title}"
echo "It will be reviewed by the Soul system's Brain nodes as a low-priority task."
