#!/bin/bash
# asyncRewake hook for Claude Code: per-session FIFO consumer.
#
# Lifecycle:
#   1. Spawned by Claude Code as an asyncRewake hook
#   2. Detect repo from `git remote get-url origin` in cwd
#   3. Create FIFO at /tmp/claude-wake/{REPO}/{PID}.fifo and registration JSON
#   4. Drain any pending event files for this repo (catches the race where
#      an event arrived while no hook was registered)
#   5. If a pending event was found, process it and exit 2 → Claude re-spawns us
#   6. Otherwise block on the FIFO with a 600s timeout
#   7. On FIFO read: process event, output instructions to stderr, exit 2
#   8. On timeout: refresh branch in registration JSON, loop back to step 6
#
# Why two paths (drain pending + FIFO):
#   FIFO is the fast path for live delivery from wake-claude.sh.
#   Pending file drain catches events that arrived while no hook was registered.
#   Both paths terminate with exit 2 so Claude Code knows to re-prompt the
#   assistant with the stderr output as a system reminder.

REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' | tr '/' '-')
[ -z "$REPO" ] && exit 0

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
PID=$$
WAKE_DIR="/tmp/claude-wake/$REPO"
FIFO="$WAKE_DIR/$PID.fifo"
REG="$WAKE_DIR/$PID.json"
EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"

mkdir -p "$WAKE_DIR"

# Cleanup on exit
cleanup() {
    rm -f "$FIFO" "$REG"
}
trap cleanup EXIT

# Remove stale FIFO/reg if they happen to exist (e.g. from a crashed instance)
rm -f "$FIFO" "$REG"

# Create FIFO
mkfifo "$FIFO" 2>/dev/null || exit 0

# Register session: repo, branch, PID, CWD. The branch field is a cached
# hint only — wake-claude.sh queries the live branch from cwd at wake time
# instead of trusting this cache.
write_registration() {
    cat > "$REG" << EOF
{"pid": $PID, "branch": "$BRANCH", "repo": "$REPO", "cwd": "$(pwd)"}
EOF
}
write_registration

# Process a single event JSON. Outputs human-readable instructions to stderr
# (Claude Code captures and re-injects them as a system reminder when the
# script exits with code 2).
process_event() {
    local event_data="$1"
    [ -z "$event_data" ] && return 1

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

# Drain ONE pending event file for this repo (the oldest one). If found,
# process it and exit 2 — Claude Code will respawn us, and on the next
# instance we will either drain the next file or block on the FIFO.
#
# This catches the race where an event was written + wake-claude.sh called
# while no hook was registered (e.g. between an exit-2 and the next
# asyncRewake spawn). Without this drain such events would only be picked
# up on the next UserPromptSubmit by check-deploy-status.sh, defeating the
# point of push wake.
if [ -d "$EVENTS_DIR" ]; then
    OLDEST=""
    OLDEST_MTIME=""
    for pending in "$EVENTS_DIR"/${REPO}*.json; do
        [ -f "$pending" ] || continue
        MTIME=$(stat -c '%Y' "$pending" 2>/dev/null || echo 0)
        if [ -z "$OLDEST" ] || [ "$MTIME" -lt "$OLDEST_MTIME" ]; then
            OLDEST="$pending"
            OLDEST_MTIME="$MTIME"
        fi
    done
    if [ -n "$OLDEST" ]; then
        PENDING_DATA=$(cat "$OLDEST" 2>/dev/null)
        if [ -n "$PENDING_DATA" ]; then
            rm -f "$OLDEST"
            process_event "$PENDING_DATA"
            exit 2
        fi
    fi
fi

# No pending events — block on the FIFO with a 600s timeout. The timeout
# loop refreshes the cached branch in the registration JSON in case the
# user runs `git checkout`. wake-claude.sh queries live branch from cwd
# at wake time so the cache is only a hint, but we still keep it fresh.
while true; do
    if EVENT_DATA=$(timeout 600 cat "$FIFO" 2>/dev/null); then
        # Something wrote to the FIFO — we got woken up with event data
        [ -z "$EVENT_DATA" ] && exit 2
        process_event "$EVENT_DATA"
        exit 2
    fi
    # Timeout — refresh registration (branch might have changed)
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    write_registration
done
