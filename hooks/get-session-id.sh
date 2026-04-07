#!/bin/bash
# get-session-id.sh — emit the current Claude Code session UUID on stdout.
#
# Usage:
#   ~/.claude/hooks/get-session-id.sh
#
# Algorithm:
#   1. Walk up the parent process tree to find the Claude PID
#      (the `claude` process that owns this terminal).
#   2. Read /proc/<claude_pid>/cwd to get the working directory.
#   3. Encode the cwd to find the project directory at
#      ~/.claude/projects/<encoded-cwd>/
#   4. Pick the most-recently-modified .jsonl file in that directory.
#      Its basename (minus .jsonl) is the current session UUID.
#
# Returns empty string if no Claude ancestor or no session file found.
#
# Designed to be called from a `gh pr create --body "..."` invocation:
#   SESSION_ID=$(~/.claude/hooks/get-session-id.sh)
#   gh pr create --body "<!-- claude-session: $SESSION_ID -->
#   ...
#   "

set -u

find_claude_pid() {
    local pid=$PPID
    local i=0
    while [ "$pid" -gt 1 ] && [ "$i" -lt 12 ]; do
        local comm
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || break
        if [ "$comm" = "claude" ]; then
            echo "$pid"
            return 0
        fi
        pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || break
        i=$((i + 1))
    done
    echo ""
}

CLAUDE_PID=$(find_claude_pid)
[ -z "$CLAUDE_PID" ] && exit 0

CWD=$(readlink "/proc/$CLAUDE_PID/cwd" 2>/dev/null)
[ -z "$CWD" ] && exit 0

ENC=$(echo "$CWD" | sed 's|/|-|g')
PROJ_DIR="$HOME/.claude/projects/$ENC"

[ -d "$PROJ_DIR" ] || exit 0

# Pick the most-recently-modified .jsonl. ls -t sorts by mtime descending.
LATEST=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
[ -z "$LATEST" ] && exit 0

# Strip path and .jsonl extension
basename="${LATEST##*/}"
echo "${basename%.jsonl}"
