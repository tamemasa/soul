#!/usr/bin/env bash
# suggest.sh - Submit a suggestion to the Soul system (pending approval)
# Usage: suggest.sh "Title" ["Description"]
#
# Writes a pending suggestion JSON file to /suggestions/ volume.
# The file must be approved via approve-suggest before Triceratops picks it up.
# Pending files (pending_suggestion_*.json) are ignored by the Soul system.

set -euo pipefail

SUGGESTIONS_DIR="/suggestions"

title="${1:-}"
description="${2:-}"

if [[ -z "${title}" ]]; then
  echo "Usage: suggest.sh \"Title\" [\"Description\"]"
  echo "Submit a suggestion to the Soul system."
  echo "The suggestion will be created as pending. Use approve-suggest to approve or reject it."
  exit 1
fi

# Generate a unique filename with pending_ prefix
ts=$(date +%s)
rand=$((RANDOM % 9000 + 1000))
filename="pending_suggestion_${ts}_${rand}.json"

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

echo "Suggestion created as pending: ${filename}"
echo "Title: ${title}"
echo "To approve: approve-suggest ${filename} approve"
echo "To reject:  approve-suggest ${filename} reject"
