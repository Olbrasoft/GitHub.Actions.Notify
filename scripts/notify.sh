#!/bin/bash
# Standalone script to send a notification to VirtualAssistant.
# Usage: ./notify.sh "Notification text" [source] [issue-ids]
#
# Examples:
#   ./notify.sh "Build prošel úspěšně"
#   ./notify.sh "Deploy selhal" "ci-pipeline" "123,456"

set -euo pipefail

TEXT="${1:?Usage: $0 \"text\" [source] [issue-ids]}"
SOURCE="${2:-ci-pipeline}"
ISSUE_IDS="${3:-}"
VA_URL="${VIRTUAL_ASSISTANT_URL:-http://localhost:5055}"

ISSUE_IDS_JSON="[]"
if [ -n "$ISSUE_IDS" ]; then
  ISSUE_IDS_JSON="[${ISSUE_IDS}]"
fi

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "${VA_URL}/api/notifications" \
  -H "Content-Type: application/json" \
  -d "{
    \"text\": $(echo "$TEXT" | jq -Rs .),
    \"source\": \"${SOURCE}\",
    \"issueIds\": ${ISSUE_IDS_JSON}
  }" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ]; then
  echo "OK: Notification sent"
else
  echo "ERROR: HTTP ${HTTP_CODE} — ${BODY}" >&2
  exit 1
fi
