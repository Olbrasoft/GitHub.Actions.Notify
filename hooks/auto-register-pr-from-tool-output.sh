#!/bin/bash
# PostToolUse hook for Claude Code: auto-register PR ownership.
#
# Fires after every tool call (Bash, Edit, Read, etc.). When a Bash
# command's output contains a GitHub PR URL, this hook automatically
# registers the current Claude session as the owner of that PR via
# register-pr-owner.sh. The Notifier (wake-claude.sh) then knows where
# to deliver future events for that PR.
#
# Without this hook, the assistant would have to remember to call
# register-pr-owner.sh manually after every `gh pr create`. With it,
# ownership is recorded automatically and reliably.
#
# Input: JSON on stdin from Claude Code, with this shape:
#   {
#     "session_id": "...",
#     "transcript_path": "...",
#     "cwd": "...",
#     "hook_event_name": "PostToolUse",
#     "tool_name": "Bash",
#     "tool_input": {"command": "..."},
#     "tool_response": {"stdout": "...", "stderr": "...", "interrupted": false}
#   }
#
# Behavior:
#   - Reads JSON from stdin (one-shot, no loop).
#   - Only acts on Bash tool calls (other tools have no shell output).
#   - Greps the combined stdout+stderr for PR URLs of the form
#     https://github.com/{owner}/{repo}/pull/{N}
#   - For each unique URL found, calls register-pr-owner.sh.
#   - Always exits 0 — never blocks the assistant. Failures are logged
#     to a side log so they can be debugged without disrupting the user.

set -u

LOG="$HOME/.claude/logs/auto-register-pr.log"
mkdir -p "$(dirname "$LOG")"

# Read the entire JSON payload from stdin. If stdin is empty (e.g. running
# manually for testing), exit cleanly.
if ! INPUT=$(cat); then
    exit 0
fi
[ -z "$INPUT" ] && exit 0

# Try to parse the JSON. If it isn't JSON, log and exit.
if ! echo "$INPUT" | jq empty 2>/dev/null; then
    echo "$(date -u +%FT%TZ) not-json input received, length=${#INPUT}" >> "$LOG"
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Extract the combined output (stdout + stderr). The shape of tool_response
# may vary slightly across Claude Code versions; try a few common keys.
OUTPUT=$(echo "$INPUT" | jq -r '
    (.tool_response.stdout // .tool_response.output // "") + "\n" +
    (.tool_response.stderr // "")
')

# Extract all PR URLs. We allow optional trailing path/anchor.
PR_URLS=$(echo "$OUTPUT" | grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' | sort -u)

if [ -z "$PR_URLS" ]; then
    exit 0
fi

REGISTER_SCRIPT="$HOME/.claude/hooks/register-pr-owner.sh"
if [ ! -x "$REGISTER_SCRIPT" ]; then
    echo "$(date -u +%FT%TZ) register-pr-owner.sh not found at $REGISTER_SCRIPT" >> "$LOG"
    exit 0
fi

# Register each unique PR URL. The register script is idempotent — if the
# same URL appears in multiple commands, the second call just overwrites
# the registration with identical data.
while IFS= read -r url; do
    [ -n "$url" ] || continue
    if "$REGISTER_SCRIPT" "$url" >> "$LOG" 2>&1; then
        echo "$(date -u +%FT%TZ) registered $url" >> "$LOG"
    else
        echo "$(date -u +%FT%TZ) FAILED to register $url" >> "$LOG"
    fi
done <<< "$PR_URLS"

exit 0
