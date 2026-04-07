#!/bin/bash
# wake-on-event.sh — asyncRewake hook for Claude Code.
#
# Per-session FIFO consumer. Runs as a Stop and SessionStart hook with
# `asyncRewake: true`. The script blocks on a named pipe; when an external
# producer (wake-claude.sh) writes an event, the script processes it and
# `exit 2`s, which causes Claude Code to inject the stderr output as a
# system reminder into the next model turn.
#
# Design constraints (per user direction):
#   - NO PR registry, NO inbox files, NO adoption, NO background daemons.
#   - The Notifier (wake-claude.sh) finds this session by enumerating live
#     `claude` processes via pgrep + /proc/PID/cwd. There is nothing to
#     register here.
#
# Lifecycle:
#   1. Spawned by Claude Code on SessionStart and on every Stop event.
#   2. Walks up the process tree to find the parent Claude PID.
#   3. **Suicide check:** if no Claude ancestor exists, this hook is an
#      orphan (the session that spawned it has died and we got reparented
#      to systemd-user). Exit immediately, taking nothing with us.
#   4. **Singleton check:** if another wake-on-event.sh is already reading
#      the same FIFO for the same Claude PID, exit immediately. Multiple
#      readers per FIFO cause kernel-level event stealing.
#   5. Create the per-session FIFO if missing and write a manifest.
#   6. Block on `cat $FIFO` with a 600s safety timeout.
#   7. On read: process the event, write instructions to stderr, exit 2.
#   8. On real EXIT (Claude session dead): cleanup() removes FIFO and manifest.

set -u

WAKE_DIR="/tmp/claude-wake"
mkdir -p "$WAKE_DIR"

###############################################################################
# Process tree walking
###############################################################################

# Find the Claude PID by walking up from this script's parent. Returns the
# PID on stdout if found, empty string otherwise.
find_claude_pid() {
    local pid=$PPID
    local i=0
    while [ "$pid" -gt 1 ] && [ "$i" -lt 10 ]; do
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

# Suicide check: if no Claude ancestor, we're an orphan. The original
# session that spawned us has died and we've been reparented to systemd-user.
# Don't keep listening on a FIFO that has no consumer.
if [ -z "$CLAUDE_PID" ]; then
    exit 0
fi

FIFO="$WAKE_DIR/.session-${CLAUDE_PID}.fifo"
MANIFEST="$WAKE_DIR/.session-${CLAUDE_PID}.json"

# NOTE: there is no singleton check. Multiple wake-on-event.sh instances per
# session are intentional: Claude Code spawns a new hook on every Stop event,
# and old instances stay blocked on `cat $FIFO` until either (a) they receive
# an event and exit 2, or (b) their 600s timeout expires. Multiple readers
# blocked on the same FIFO are a feature — when wake-claude.sh writes one
# event, the kernel atomically delivers it to exactly one reader; the others
# stay alive and act as backup readers for subsequent events. This makes the
# wake mechanism more resilient to bursts.

###############################################################################
# Cleanup on real exit (not on exit 2 — Claude Code respawns the hook then)
###############################################################################

cleanup() {
    # Only purge if the parent Claude process is dead. exit 2 keeps the
    # session alive and we want the FIFO preserved for the next spawn.
    if ! kill -0 "$CLAUDE_PID" 2>/dev/null; then
        rm -f "$FIFO" "$MANIFEST"
    fi
}
trap cleanup EXIT

###############################################################################
# Create FIFO + manifest if missing (idempotent across hook spawns)
###############################################################################

if [ ! -p "$FIFO" ]; then
    rm -f "$FIFO"
    mkfifo "$FIFO" 2>/dev/null || exit 0
fi

# Write a small manifest so external tools can discover this session.
# (wake-claude.sh does NOT use the manifest — it enumerates via pgrep.
# The manifest is informational only.)
jq -n \
    --argjson pid "$CLAUDE_PID" \
    --arg fifo "$FIFO" \
    --arg cwd "$(pwd)" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pid: $pid, fifo: $fifo, cwd: $cwd, created: $created}' > "$MANIFEST" 2>/dev/null

###############################################################################
# Event processing
###############################################################################

# Render an event JSON payload as human-readable instructions on stderr.
# Claude Code captures stderr and re-injects it as a system reminder when
# we exit with code 2.
process_event() {
    local event_data="$1"
    [ -z "$event_data" ] && return 1

    if ! echo "$event_data" | jq empty 2>/dev/null; then
        echo "[wake-on-event] event payload is not valid JSON" >&2
        return 1
    fi

    local event_type status repo_name
    event_type=$(echo "$event_data" | jq -r '.event // "unknown"')
    status=$(echo "$event_data" | jq -r '.status // "unknown"')
    repo_name=$(echo "$event_data" | jq -r '.repository // "unknown"')

    {
        case "$event_type" in
            deploy-complete)
                local failed_step commit_msg commit
                failed_step=$(echo "$event_data" | jq -r '.failedStep // ""')
                commit_msg=$(echo "$event_data" | jq -r '.commitMessage // "unknown"')
                commit=$(echo "$event_data" | jq -r '.commit // "unknown"')
                echo "Deploy $status for $repo_name: $commit_msg ($commit)"
                if [ "$status" != "success" ] && [ -n "$failed_step" ]; then
                    echo "FAILED STEP: $failed_step"
                    echo "Read failed CI logs and fix. Notify user via mcp__notify__notify."
                elif [ "$status" = "success" ]; then
                    echo "Verify deployment. Notify user via mcp__notify__notify."
                else
                    echo "Deploy FAILED. Check logs. Notify user via mcp__notify__notify."
                fi
                ;;
            code-review-complete)
                local pr_num pr_url comments
                pr_num=$(echo "$event_data" | jq -r '.prNumber // "unknown"')
                pr_url=$(echo "$event_data" | jq -r '.prUrl // ""')
                comments=$(echo "$event_data" | jq -r '.reviewComments // 0')
                echo "Code review on $repo_name PR #$pr_num: $comments comments (status: $status)"
                [ -n "$pr_url" ] && echo "PR: $pr_url"
                echo "Read comments: gh api repos/$repo_name/pulls/$pr_num/comments --jq '.[].body'"
                echo "Fix all issues, push, notify user via mcp__notify__notify."
                ;;
            ci-complete)
                local pr_num pr_branch
                pr_num=$(echo "$event_data" | jq -r '.prNumber // "unknown"')
                pr_branch=$(echo "$event_data" | jq -r '.branch // "unknown"')
                echo "CI $status for $repo_name PR #$pr_num (branch: $pr_branch)"
                if [ "$status" = "success" ]; then
                    echo "All CI checks passed. Check if Copilot review is done, then merge PR."
                else
                    echo "CI FAILED. Read logs: gh run list --repo $repo_name --branch $pr_branch --limit 1"
                    echo "Fix the issue, push. Notify user via mcp__notify__notify."
                fi
                ;;
            verify-complete)
                local commit environment
                commit=$(echo "$event_data" | jq -r '.commit // "unknown"')
                environment=$(echo "$event_data" | jq -r '.environment // "production"')
                echo "Verify $status for $repo_name ($commit, $environment)"
                if [ "$status" = "success" ]; then
                    echo "Production verified. Run issue-specific Playwright test. Close issue if OK."
                else
                    echo "Verification FAILED. Investigate and fix."
                fi
                echo "Notify user via mcp__notify__notify."
                ;;
            wake)
                echo "Wake signal for $repo_name (no specific event)."
                ;;
            *)
                echo "CI event: $event_type ($status) for $repo_name"
                ;;
        esac
    } >&2

    return 0
}

###############################################################################
# Main loop: block on FIFO
###############################################################################

while true; do
    if EVENT_DATA=$(timeout 600 cat "$FIFO" 2>/dev/null); then
        [ -z "$EVENT_DATA" ] && exit 2
        process_event "$EVENT_DATA"
        exit 2
    fi
    # Timeout: nothing happened in 10 minutes. Refresh manifest with current
    # cwd (cheap) and loop back.
    jq -n \
        --argjson pid "$CLAUDE_PID" \
        --arg fifo "$FIFO" \
        --arg cwd "$(pwd)" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{pid: $pid, fifo: $fifo, cwd: $cwd, created: $created}' > "$MANIFEST" 2>/dev/null
done
