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

    local event_type status repo_name event_ts event_age_seconds event_age_human
    event_type=$(echo "$event_data" | jq -r '.event // "unknown"')
    status=$(echo "$event_data" | jq -r '.status // "unknown"')
    repo_name=$(echo "$event_data" | jq -r '.repository // "unknown"')
    event_ts=$(echo "$event_data" | jq -r '.timestamp // ""')

    # Compute age of the event (now - timestamp). This lets the feedback
    # log entry record observed delay so cross-session pattern analysis
    # can spot late deliveries. Issue #40.
    #
    # Guard against negative ages from clock skew or a bad payload — a
    # negative number would render as `-5s` and confuse Claude. Treat
    # any negative age as a clamped 0 with an explicit label.
    event_age_seconds=""
    event_age_human=""
    if [ -n "$event_ts" ]; then
        local ts_epoch now_epoch
        ts_epoch=$(date -u -d "$event_ts" +%s 2>/dev/null || echo "")
        now_epoch=$(date -u +%s)
        if [ -n "$ts_epoch" ]; then
            event_age_seconds=$((now_epoch - ts_epoch))
            if [ "$event_age_seconds" -lt 0 ]; then
                # Future timestamp — clock skew. Clamp to 0 and label.
                event_age_seconds=0
                event_age_human="0s (clock skew: event_ts in future)"
            elif [ "$event_age_seconds" -lt 60 ]; then
                event_age_human="${event_age_seconds}s"
            elif [ "$event_age_seconds" -lt 3600 ]; then
                event_age_human="$((event_age_seconds / 60))m"
            else
                event_age_human="$((event_age_seconds / 3600))h$((event_age_seconds / 60 % 60))m"
            fi
        fi
    fi

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
                local pr_num pr_url comments reviewer is_copilot
                pr_num=$(echo "$event_data" | jq -r '.prNumber // "unknown"')
                pr_url=$(echo "$event_data" | jq -r '.prUrl // ""')
                comments=$(echo "$event_data" | jq -r '.reviewComments // 0')
                reviewer=$(echo "$event_data" | jq -r '.reviewer // ""')
                # Copilot's reviewer login (the .user.login field — GitHub's
                # account login/username, NOT the profile display name)
                # differs across API surfaces:
                #   - REST API (gh api .../reviews):  copilot-pull-request-reviewer[bot]
                #   - REST API (gh pr view --json):   copilot-pull-request-reviewer
                #   - Webhook payload (.user.login):  Copilot
                # The webhook-receiver.py extracts user.login from the
                # webhook payload, which for this bot is the literal login
                # "Copilot". Match all three forms exactly so the
                # is_copilot path fires for the bot regardless of which
                # producer set the .reviewer field, but does NOT match
                # any human reviewer whose login happens to start with
                # "Copilot" (e.g. "CopilotFan").
                case "$reviewer" in
                    copilot-pull-request-reviewer|copilot-pull-request-reviewer\[bot\]|Copilot|Copilot\[bot\])
                        is_copilot=1 ;;
                    *)
                        is_copilot=0 ;;
                esac
                echo "Code review COMPLETE on $repo_name PR #$pr_num by $reviewer: $comments comment(s)"
                [ -n "$pr_url" ] && echo "PR: $pr_url"
                echo ""
                # Advisory text only — never imperative. The wake event can
                # arrive minutes after the underlying review completed (or
                # even after the PR is already merged), so Claude must
                # always verify current PR state before acting. Bug 34.
                echo "FIRST verify PR state: gh pr view $pr_num --repo $repo_name --json state,mergeable"
                if [ "$comments" = "0" ]; then
                    echo "If state=OPEN: merge with"
                    echo "  gh pr merge $pr_num --repo $repo_name --merge --delete-branch"
                    echo "If state=MERGED: skip — work was already completed and merged."
                    echo "If state=CLOSED (not merged): skip — the work was abandoned."
                else
                    echo "If state=OPEN, review the comments and consider whether each is still relevant:"
                    echo "  gh api repos/$repo_name/pulls/$pr_num/comments --jq '.[].body'"
                    echo "Address relevant ones in the working tree, commit (\"fix: address review on PR #$pr_num\"), push, then merge:"
                    echo "  gh pr merge $pr_num --repo $repo_name --merge --delete-branch"
                    echo ""
                    if [ "$is_copilot" = "1" ]; then
                        echo "IMPORTANT (Copilot review): Copilot reviews each PR EXACTLY ONCE. After pushing the fix commits, MERGE THE PR DIRECTLY — do NOT wait for a second review wake event from Copilot. It will never arrive. Source: ~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/continuous-pr-processing-workflow.md and ci-workflow-monitor SKILL.md Critical Rule #7."
                    else
                        echo "NOTE (human reviewer '$reviewer'): unlike Copilot, human reviewers may re-review after a fix push. Before merging, verify the reviewer is satisfied — e.g. check for a follow-up APPROVED review or an explicit acknowledgement. If the reviewer requested changes, wait for them to come back."
                    fi
                    echo ""
                    echo "If state=MERGED: comments may already be addressed by later commits in main — verify against current code before doing anything."
                    echo "If state=CLOSED (not merged): skip — the work was abandoned."
                fi
                echo "Notify user via mcp__notify__notify with the outcome."
                ;;
            ci-complete)
                local pr_num pr_branch
                pr_num=$(echo "$event_data" | jq -r '.prNumber // "unknown"')
                pr_branch=$(echo "$event_data" | jq -r '.branch // "unknown"')
                echo "CI $status for $repo_name PR #$pr_num (branch: $pr_branch)"
                if [ "$status" = "success" ]; then
                    echo "All CI checks passed. Check the latest Copilot review state before deciding:"
                    echo "  gh pr view $pr_num --repo $repo_name --json reviews \\"
                    echo "    --jq '[.reviews[] | select(.author.login | startswith(\"copilot-pull-request-reviewer\"))] | last'"
                    echo "  - null → Copilot has not reviewed yet. Wait for the code-review-complete wake event (the asyncRewake hook re-arms on every Stop, so just continue working)."
                    echo "  - .state == \"COMMENTED\" with comments you ALREADY addressed → MERGE NOW. Copilot reviews each PR EXACTLY ONCE and will not fire again on push."
                    echo "  - .state == \"COMMENTED\" with unresolved comments → fix them first (per the earlier code-review-complete advisory), then merge."
                    echo "  - .state == \"CHANGES_REQUESTED\" → address the requested changes, then merge."
                    echo "  - .state == \"APPROVED\" → MERGE."
                    echo "Note: filter by .author.login startswith because gh pr view returns ALL reviews (humans + bots). The 'merge directly after one Copilot review' rule only applies to Copilot. For human reviews, verify the human is satisfied before merging."
                    echo "Do NOT wait passively for a second Copilot wake event after pushing fixes — it will never arrive."
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

        # Cross-session feedback log instructions. After acting (or
        # deciding not to), Claude should append a one-line evaluation to
        # the shared feedback log so future sessions can spot patterns
        # without relying on the original session being alive. Issue #40.
        echo ""
        if [ -n "$event_age_human" ]; then
            echo "EVENT AGE: $event_age_human (event timestamp: $event_ts)"
        fi
        echo "AFTER acting (or skipping), append a feedback entry:"
        echo "  ~/.claude/hooks/log-wake-feedback.sh \\"
        echo "    event=$event_type \\"
        echo "    repo=$repo_name \\"
        echo "    classification=ok|late|stale|garbled|wrong-target|other \\"
        if [ -n "$event_age_human" ]; then
            echo "    delay=$event_age_human \\"
        fi
        echo "    note=\"<one-line summary of what you did or why you skipped>\""
        echo "Pick the classification that best describes how this event interacted with current state:"
        echo "  ok           — event arrived in time, action taken cleanly"
        echo "  late         — event arrived after a noticeable delay but action still applicable"
        echo "  stale        — event arrived after the underlying state already changed (e.g. PR already merged)"
        echo "  garbled      — event payload was malformed or partially read"
        echo "  wrong-target — event was for a different session/branch than the one it landed on"
        echo "  other        — anything else worth recording"
    } >&2

    return 0
}

###############################################################################
# Main loop: block on FIFO
###############################################################################
#
# Producers (wake-claude.sh) terminate each event with a newline (NDJSON
# framing — bug 33). The consumer reads ONE LINE at a time via `read -r`,
# which means two events written back-to-back to the same FIFO are read
# as two separate lines instead of being concatenated by `cat` into a
# garbled `{...}{...}` blob that fails JSON parse.
#
# We open the FIFO once via `exec 3<` and read from FD 3 across all
# iterations, plus a paired `exec 3>` so the FIFO never reaches EOF
# from our side when producers close their write end. This avoids the
# open-close-reopen race where a producer arriving between iterations
# would block waiting for a reader to re-open.

exec 3<>"$FIFO"

# Re-check that the parent Claude process is still alive. The startup
# suicide check at the top only fires once, but the loop below blocks
# for up to 600s in `read`. If the parent dies during that block, the
# hook gets reparented to systemd-user and would otherwise stay alive
# forever, accumulating one orphan per dead session. See bug 32.
parent_alive() {
    kill -0 "$CLAUDE_PID" 2>/dev/null
}

while true; do
    if ! parent_alive; then
        # Parent Claude died while we were idle. Bail out before re-arming
        # the read so we do not become an orphan.
        exec 3<&-
        exit 0
    fi
    # Read one NDJSON line with a 600s safety timeout. read returns 0 on
    # success, non-zero on timeout (no input within 600s) or EOF (no
    # writers — but FD 3 is also write-open, so we never see real EOF).
    EVENT_DATA=""
    if IFS= read -r -t 600 EVENT_DATA <&3; then
        if ! parent_alive; then
            exec 3<&-
            exit 0
        fi
        [ -z "$EVENT_DATA" ] && { exec 3<&-; exit 2; }
        process_event "$EVENT_DATA"
        exec 3<&-
        exit 2
    fi
    # read timed out: nothing arrived in 600s. Refresh manifest with
    # current cwd (cheap) and loop back.
    jq -n \
        --argjson pid "$CLAUDE_PID" \
        --arg fifo "$FIFO" \
        --arg cwd "$(pwd)" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{pid: $pid, fifo: $fifo, cwd: $cwd, created: $created}' > "$MANIFEST" 2>/dev/null
done
