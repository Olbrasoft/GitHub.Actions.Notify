#!/bin/bash
# asyncRewake hook for Claude Code: per-session FIFO consumer.
#
# Session-bound design (see docs/architecture.md):
#   - Each Claude session has ONE FIFO at /tmp/claude-wake/.session-{PID}.fifo
#     (regardless of how many repos the session works in).
#   - The FIFO is referenced by the session manifest at
#     /tmp/claude-wake/.session-{PID}.json which records pid + fifo path.
#   - PR ownership lives in ~/.config/claude-channels/pr-owners/ — created by
#     the PostToolUse auto-register hook when `gh pr create` succeeds. This
#     hook does NOT manage ownership — it only owns the FIFO.
#   - Cleanup on EXIT removes the FIFO, the session manifest, and any
#     ~/.config/claude-channels/pr-owners/*.json that points at this PID.
#     A dead session leaves no orphans.
#
# Lifecycle:
#   1. Spawned by Claude Code on SessionStart and on every Stop event
#      (asyncRewake true).
#   2. Walk up the process tree to find the Claude PID (the parent of this
#      hook subprocess).
#   3. Create FIFO + manifest if they don't already exist.
#   4. Block on `cat $FIFO` with a 600s timeout.
#   5. On read: process the event payload, write instructions to stderr,
#      exit 2 — Claude Code re-prompts the assistant with the stderr as a
#      system reminder, achieving the "wake".
#   6. On timeout: just loop back. The wake mechanism is event-driven; the
#      timeout exists only so the cat doesn't block forever in case
#      something goes wrong.
#   7. On real EXIT (Claude session ends, hook is killed): the trap fires
#      and removes everything.

set -u

WAKE_DIR="/tmp/claude-wake"
PR_OWNERS_DIR="$HOME/.config/claude-channels/pr-owners"

mkdir -p "$WAKE_DIR" "$PR_OWNERS_DIR"

# Find the Claude process PID by walking up the process tree from this hook.
# Try each ancestor and stop at the first one whose comm is "claude".
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
    # Fallback: use direct parent PID. Better than nothing.
    echo "$PPID"
}

CLAUDE_PID=$(find_claude_pid)
FIFO="$WAKE_DIR/.session-${CLAUDE_PID}.fifo"
MANIFEST="$WAKE_DIR/.session-${CLAUDE_PID}.json"

# Cleanup on real exit only (not on exit 2 → Claude re-spawns us). The
# distinction matters because exit 2 is the "wake" signal: we want the
# session to keep its FIFO so the NEXT spawned hook instance picks up
# delivery. Cleanup must only happen when the Claude process itself is
# really gone.
cleanup() {
    # Only purge if the parent Claude process is dead. Otherwise this is
    # an exit-2 cycle and the FIFO is still needed.
    if ! kill -0 "$CLAUDE_PID" 2>/dev/null; then
        rm -f "$FIFO" "$MANIFEST"
        # Drop any PR ownerships for this PID — dead owner = drop all events
        for owner in "$PR_OWNERS_DIR"/*.json; do
            [ -f "$owner" ] || continue
            local_pid=$(jq -r '.pid // 0' "$owner" 2>/dev/null)
            if [ "$local_pid" = "$CLAUDE_PID" ]; then
                rm -f "$owner"
            fi
        done
    fi
}
trap cleanup EXIT

# Create FIFO + manifest if missing. The hook is spawned multiple times
# during a session (SessionStart + every Stop), so this must be idempotent.
if [ ! -p "$FIFO" ]; then
    rm -f "$FIFO"
    mkfifo "$FIFO" 2>/dev/null || exit 0
fi

# Write/refresh the session manifest. cwd may have changed since the last
# run if the user navigated, but PID and FIFO are stable.
jq -n \
    --argjson pid "$CLAUDE_PID" \
    --arg fifo "$FIFO" \
    --arg cwd "$(pwd)" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pid: $pid, fifo: $fifo, cwd: $cwd, created: $created}' > "$MANIFEST"

# Adopt orphaned PR ownerships from previous (now-dead) sessions for this
# repo. The use case: user creates PRs in a Claude session, closes it, opens
# a new one in the same project — they expect the new session to receive
# pending events for those PRs and continue the workflow autonomously.
#
# Adoption rules:
#   1. Only owner records for the cwd's git repo are considered (so a
#      session in repo A does not adopt PRs from repo B).
#   2. Only records whose pid is dead (kill -0 fails) are adopted —
#      a live owner is left alone.
#   3. The PR must still be OPEN on GitHub. Closed/merged PRs are not
#      relevant; their owner records are deleted.
#   4. Adoption is silent (no events are delivered as a side effect).
#      The next event from GitHub will be routed to the new owner via
#      wake-claude.sh as usual.
#
# This is a best-effort scan: if `gh` is missing or the API is slow, we
# skip the PR-state check rather than blocking session startup. The
# scan runs at most once per asyncRewake spawn, which is bounded.
# Decide whether a recorded owner should be considered alive. A live owner
# is one whose PID is a real, running process AND whose registered FIFO
# still exists. The FIFO check guards against PID reuse — a recycled PID
# could otherwise be mistaken for the original owner.
owner_is_live() {
    local pid="$1"
    local fifo="$2"

    # Reject empty, non-numeric, and pid <= 1 (init/group). `kill -0 0` would
    # otherwise succeed because it targets the current process group, which
    # would be wrong here.
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$pid" -le 1 ]; then
        return 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    # FIFO must exist (and be a FIFO). If the FIFO is gone, the original
    # session has cleaned up and the PID has likely been reused.
    if [ -z "$fifo" ] || [ ! -p "$fifo" ]; then
        return 1
    fi

    return 0
}

adopt_orphans() {
    [ -d "$PR_OWNERS_DIR" ] || return 0

    local my_repo
    my_repo=$(git -C "$(pwd)" remote get-url origin 2>/dev/null \
        | sed 's|.*github.com[:/]||;s|\.git$||' \
        | tr '/' '-')
    [ -z "$my_repo" ] && return 0

    local adopted=0
    for owner in "$PR_OWNERS_DIR"/${my_repo}-*.json; do
        [ -f "$owner" ] || continue

        local owner_pid owner_fifo owner_repo owner_pr owner_url
        owner_pid=$(jq -r '.pid // 0' "$owner" 2>/dev/null)
        owner_fifo=$(jq -r '.fifo // ""' "$owner" 2>/dev/null)
        owner_repo=$(jq -r '.repo // ""' "$owner" 2>/dev/null)
        owner_pr=$(jq -r '.pr // 0' "$owner" 2>/dev/null)
        owner_url=$(jq -r '.url // ""' "$owner" 2>/dev/null)

        # Only process records for our repo (the glob is broad — *-*-*.json)
        [ "$owner_repo" = "$my_repo" ] || continue
        [ "$owner_pr" -gt 0 ] || continue

        # Skip live owners
        if owner_is_live "$owner_pid" "$owner_fifo"; then
            continue
        fi

        # Derive owner/repo from the stored URL rather than reconstructing it
        # from the dashed file prefix. The dashed form is not invertible when
        # the GitHub owner or repo name itself contains a dash (for example
        # "my-org/my-repo" → "my-org-my-repo"), so we cannot rely on
        # "${my_repo/-//}". The URL is the canonical source of truth.
        local pr_full_repo=""
        if [[ "$owner_url" =~ github\.com/([^/]+)/([^/]+)/pull/[0-9]+ ]]; then
            pr_full_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        fi
        if [ -z "$pr_full_repo" ]; then
            echo "[wake-on-event] Cannot derive owner/repo from $owner.url, skipping" >&2
            continue
        fi

        # Verify the PR is still open on GitHub. If gh fails, leave the
        # record alone — better to keep an orphan than to lose state.
        # Each call is bounded by 5s; total scan time is per_record × records.
        local pr_state
        pr_state=$(timeout 5 gh pr view "$owner_pr" \
            --repo "$pr_full_repo" \
            --json state \
            --jq '.state' 2>/dev/null)

        case "$pr_state" in
            OPEN)
                # Adopt with strict first-wins: take an exclusive lock on the
                # owner file, re-read the record under the lock, only rewrite
                # if it still points at the same dead PID we observed
                # (compare-and-swap). A racing session that already adopted
                # the record would have changed the PID, so we would back off.
                local lock_file="$owner.lock"
                (
                    if flock -x -w 5 9; then
                        local cur_pid cur_repo cur_pr cur_fifo
                        cur_pid=$(jq -r '.pid // 0' "$owner" 2>/dev/null)
                        cur_fifo=$(jq -r '.fifo // ""' "$owner" 2>/dev/null)
                        cur_repo=$(jq -r '.repo // ""' "$owner" 2>/dev/null)
                        cur_pr=$(jq -r '.pr // 0' "$owner" 2>/dev/null)

                        # Check the record still matches the same orphan AND is
                        # still dead. If another session already adopted it,
                        # cur_pid would now be alive and we back off.
                        if [ -f "$owner" ] \
                            && [ "$cur_pid" = "$owner_pid" ] \
                            && [ "$cur_repo" = "$owner_repo" ] \
                            && [ "$cur_pr" = "$owner_pr" ] \
                            && ! owner_is_live "$cur_pid" "$cur_fifo"; then
                            local tmp="$owner.adopt.$$"
                            if jq \
                                --argjson pid "$CLAUDE_PID" \
                                --arg fifo "$FIFO" \
                                --arg adopted "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                '.pid = $pid | .fifo = $fifo | .adopted_at = $adopted' \
                                "$owner" > "$tmp" 2>/dev/null; then
                                mv "$tmp" "$owner"
                                echo "[wake-on-event] Adopted PR #$owner_pr from dead PID $owner_pid" >&2
                                exit 0
                            else
                                rm -f "$tmp"
                            fi
                        fi
                        exit 1
                    else
                        echo "[wake-on-event] Could not acquire lock for $owner, skipping" >&2
                        exit 2
                    fi
                ) 9>"$lock_file"
                if [ "$?" -eq 0 ]; then
                    adopted=$((adopted + 1))
                fi
                # Best-effort cleanup of the lock file (the lock itself was
                # already released when the subshell exited).
                rm -f "$lock_file"
                ;;
            MERGED|CLOSED)
                # PR is no longer interesting — clean up the orphan record
                rm -f "$owner"
                echo "[wake-on-event] Cleaned up PR #$owner_pr (state: $pr_state)" >&2
                ;;
            *)
                # gh failed, unknown state, or empty — leave alone
                ;;
        esac
    done

    if [ "$adopted" -gt 0 ]; then
        echo "[wake-on-event] Adopted $adopted orphaned PR ownership(s) for $my_repo" >&2
    fi
}
adopt_orphans

# Process a single event JSON payload received via FIFO. Outputs human-
# readable instructions to stderr (Claude Code captures and re-injects them
# as a system reminder when the script exits with code 2).
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

# Block on the FIFO. The 600s timeout exists only as a safety belt; in
# practice the Notifier writes events as soon as GitHub triggers them, and
# this loop returns within seconds.
while true; do
    if EVENT_DATA=$(timeout 600 cat "$FIFO" 2>/dev/null); then
        [ -z "$EVENT_DATA" ] && exit 2
        process_event "$EVENT_DATA"
        exit 2
    fi
    # Timeout: nothing happened in 10 minutes. Loop and re-block.
    # Refresh manifest with current cwd (cheap).
    jq -n \
        --argjson pid "$CLAUDE_PID" \
        --arg fifo "$FIFO" \
        --arg cwd "$(pwd)" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{pid: $pid, fifo: $fifo, cwd: $cwd, created: $created}' > "$MANIFEST"
done
