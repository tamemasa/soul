#!/usr/bin/env bash
# write-approval.sh - Record owner's approval/rejection for a pending suggestion
# Usage: write-approval <pending_filename> approve|reject
#
# Automatically uses OWNER_DISCORD_ID from the environment (set at container startup).
# The AI must only call this when in buddy mode (owner identity verified by the framework).
# Triceratops independently verifies the discord_user_id before processing.

set -euo pipefail

SUGGESTIONS_DIR="/suggestions"

filename="${1:-}"
action="${2:-}"

if [[ -z "${filename}" || -z "${action}" ]]; then
  echo "Usage: write-approval <pending_filename> approve|reject"
  echo ""
  echo "The Discord user ID is automatically read from OWNER_DISCORD_ID environment variable."
  echo "Only call this command when the owner (buddy mode) has approved/rejected."
  exit 1
fi

# Validate action
if [[ "${action}" != "approve" && "${action}" != "reject" ]]; then
  echo "Error: action must be 'approve' or 'reject' (got: ${action})"
  exit 1
fi

# Get owner Discord user ID from environment (set at container startup, not user input)
discord_user_id="${OWNER_DISCORD_ID:-}"
if [[ -z "${discord_user_id}" ]]; then
  echo "Error: OWNER_DISCORD_ID environment variable is not set."
  exit 1
fi

# Validate discord_user_id (must be numeric, Discord snowflake)
if [[ ! "${discord_user_id}" =~ ^[0-9]+$ ]]; then
  echo "Error: OWNER_DISCORD_ID is not a valid numeric ID (got: ${discord_user_id})"
  exit 1
fi

# Validate filename format
if [[ ! "${filename}" =~ ^pending_suggestion_[0-9]+_[0-9]+\.json$ ]]; then
  echo "Error: invalid filename format. Expected: pending_suggestion_<ts>_<rand>.json"
  exit 1
fi

# Check pending file exists
filepath="${SUGGESTIONS_DIR}/${filename}"
if [[ ! -f "${filepath}" ]]; then
  echo "Error: pending suggestion not found: ${filepath}"
  exit 1
fi

# Write approval response file (Triceratops will verify the user ID)
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
approval_filename="approval_${filename}"
tmp_file="${SUGGESTIONS_DIR}/.tmp_${approval_filename}"

cat > "${tmp_file}" <<EOF
{
  "suggestion_file": $(printf '%s' "${filename}" | jq -Rs .),
  "decision": $(printf '%s' "${action}" | jq -Rs .),
  "discord_user_id": $(printf '%s' "${discord_user_id}" | jq -Rs .),
  "responded_at": "${now_iso}"
}
EOF

mv "${tmp_file}" "${SUGGESTIONS_DIR}/${approval_filename}"

echo "Approval response recorded: ${approval_filename}"
echo "Decision: ${action} (verified owner: ${discord_user_id})"
echo "Triceratops will verify the user ID and process accordingly."
