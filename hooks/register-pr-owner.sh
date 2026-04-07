#!/bin/bash
# Register the current Claude Code session as the owner of a GitHub PR.
#
# Called by:
#   - hooks/auto-register-pr-from-tool-output.sh (PostToolUse hook, automatic)
#   - manually as a fallback if PostToolUse is not configured
#
# Usage:
#   register-pr-owner.sh <PR_URL> [CLAUDE_PID]
#
#   PR_URL: full URL of the PR, e.g. https://github.com/owner/repo/pull/123
#   CLAUDE_PID: (optional) the Claude Code process PID. If omitted, the
#               script walks the process tree from $PPID looking for a
#               process named "claude". If that fails, it falls back to
#               $PPID itself.
#
# Effect: writes ~/.config/claude-channels/pr-owners/{owner-repo}-{pr}.json
# with {pid, fifo, repo, pr, registered_at}. The fifo path is the
# session FIFO at /tmp/claude-wake/.session-{PID}.fifo (created by
# wake-on-event.sh on SessionStart). If the FIFO does not exist yet, the
# script writes the registration anyway — wake-on-event.sh will create the
# FIFO on its next run and the Notifier will pick it up then.
#
# Idempotent: re-running with the same PR_URL overwrites the existing
# registration with the current PID. This handles the case where the same
# session re-registers (no harm) or a NEW session takes over (intentional).

set -u

PR_URL="${1:?Usage: $0 <PR_URL> [CLAUDE_PID]}"
CLAUDE_PID="${2:-}"

# Extract owner/repo/pr_number from the URL.
# Accepted forms:
#   https://github.com/owner/repo/pull/123
#   https://github.com/owner/repo/pull/123/files
#   https://github.com/owner/repo/pull/123#discussion-...
#   github.com/owner/repo/pull/123
if [[ ! "$PR_URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    echo "[register-pr-owner] not a recognizable PR URL: $PR_URL" >&2
    exit 1
fi
OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
PR_NUMBER="${BASH_REMATCH[3]}"
REPO_FILE="${OWNER}-${REPO}"

# If the caller did not pass a Claude PID, find one by walking up the
# process tree from $PPID. The first ancestor with comm == "claude" wins.
find_claude_pid() {
    local pid=$PPID
    local i=0
    while [ "$pid" != "1" ] && [ "$i" -lt 10 ]; do
        local comm
        comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
        if [ "$comm" = "claude" ]; then
            echo "$pid"
            return 0
        fi
        pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo 1)
        i=$((i + 1))
    done
    echo "$PPID"
}

if [ -z "$CLAUDE_PID" ]; then
    CLAUDE_PID=$(find_claude_pid)
fi

# Sanity check: the Claude PID should be alive at registration time.
if ! kill -0 "$CLAUDE_PID" 2>/dev/null; then
    echo "[register-pr-owner] resolved Claude PID $CLAUDE_PID is not alive" >&2
    exit 1
fi

PR_OWNERS_DIR="$HOME/.config/claude-channels/pr-owners"
WAKE_DIR="/tmp/claude-wake"
FIFO="$WAKE_DIR/.session-${CLAUDE_PID}.fifo"
mkdir -p "$PR_OWNERS_DIR"

OWNER_FILE="$PR_OWNERS_DIR/${REPO_FILE}-${PR_NUMBER}.json"
jq -n \
    --argjson pid "$CLAUDE_PID" \
    --arg fifo "$FIFO" \
    --arg repo "$REPO_FILE" \
    --argjson pr "$PR_NUMBER" \
    --arg url "$PR_URL" \
    --arg registered "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pid: $pid, fifo: $fifo, repo: $repo, pr: $pr, url: $url, registered_at: $registered}' \
    > "$OWNER_FILE"

echo "[register-pr-owner] OK ${REPO_FILE}#${PR_NUMBER} → PID $CLAUDE_PID" >&2
