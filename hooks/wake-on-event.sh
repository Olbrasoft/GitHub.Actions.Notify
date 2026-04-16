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
LOCKFILE="$WAKE_DIR/.session-${CLAUDE_PID}.reader.lock"

###############################################################################
# Singleton reader enforcement
###############################################################################
#
# Only ONE wake-on-event.sh instance may block on the FIFO at a time per
# Claude session. A previous iteration of this script claimed that multiple
# concurrent readers were "a feature" — that was WRONG.
#
# The failure mode: bash's `read -r` builtin reads from its input FD one
# BYTE at a time (it has to scan for the delimiter byte-by-byte). When two
# processes block simultaneously in `read -r` on the same FIFO, the kernel
# delivers one byte of an atomic write to one reader, the next byte to the
# other, and so on. The result is that each reader ends up with every OTHER
# byte of the payload — "garbled" NDJSON that fails `jq empty` parse. When
# the first reader hits a newline and exits, the second inherits the rest
# of the stream, so its buffer ends up as (every-other-byte of payload A) +
# (clean payload B). This exact pattern was observed repeatedly in
# ~/.config/claude-channels/invalid-payloads/*.txt.
#
# Fix: a PID-based lockfile ensures at most one reader per CLAUDE_PID.
# New spawns that find a live reader step aside (exit 0) and leave the
# existing reader in charge. If the old reader exited ungracefully and
# left a stale lock, the new spawn detects that via `kill -0` + cmdline
# re-verification (PID reuse protection) and takes over.
#
# Claim is atomic via hard-link: we write our PID to a per-process temp
# file FIRST, then `ln` it into place as $LOCKFILE. `ln` fails with EEXIST
# if $LOCKFILE already exists, so at most one spawn can succeed, and any
# reader that observes $LOCKFILE sees a fully populated PID — never an
# empty file in the open-but-not-yet-written window that a bare
# `(set -C; echo > LOCKFILE)` would expose. Addresses the race Copilot
# flagged on PR #47: the previous noclobber-based claim_lock let a
# concurrent spawn `cat` the file between open and write, see empty
# contents, treat it as stale, rm it, and claim its own — two owners
# and byte-race re-emerged.

claim_lock() {
    local tmp_lock="${LOCKFILE}.$$.tmp"
    # Write PID to temp first so the final link target is always populated.
    printf '%s\n' "$$" > "$tmp_lock" 2>/dev/null || return 1
    if ln "$tmp_lock" "$LOCKFILE" 2>/dev/null; then
        rm -f "$tmp_lock"
        return 0
    fi
    rm -f "$tmp_lock"
    return 1
}

release_lock() {
    # Only release if we still own the lock. Avoids a rm of a lock that
    # was stolen from us by PID reuse or a rogue overwrite.
    local owner
    owner=$(cat "$LOCKFILE" 2>/dev/null)
    if [ "$owner" = "$$" ]; then
        rm -f "$LOCKFILE"
    fi
}

# Defense against a lockfile path that somehow exists but is NOT a regular
# file (directory, FIFO, symlink to missing target, etc). `rm -f` silently
# skips directories, which would otherwise make claim_lock fail forever
# and leave the session with no reader. Log loudly, attempt targeted
# cleanup (rmdir for an empty dir, rm -f for everything else), and give
# up only if the path still exists afterwards. Copilot review on PR #47.
if [ -e "$LOCKFILE" ] && [ ! -f "$LOCKFILE" ]; then
    echo "[wake-on-event] $LOCKFILE exists but is not a regular file — attempting cleanup" >&2
    if [ -d "$LOCKFILE" ]; then
        rmdir "$LOCKFILE" 2>/dev/null
    else
        rm -f "$LOCKFILE" 2>/dev/null
    fi
    if [ -e "$LOCKFILE" ]; then
        echo "[wake-on-event] failed to clean up $LOCKFILE — exiting (session will have no reader until the path is fixed manually)" >&2
        exit 0
    fi
fi

if ! claim_lock; then
    # Lock exists — inspect the current owner.
    old_pid=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
        # Owner is alive. Verify it is actually wake-on-event.sh (not a
        # PID-reuse victim that happens to have the same numeric PID).
        old_cmdline=$(tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)
        case "$old_cmdline" in
            *wake-on-event.sh*)
                # Another live reader owns the FIFO. Step aside without
                # touching the FIFO, the manifest, or the lock — the
                # existing reader is still doing its job.
                exit 0
                ;;
        esac
    fi
    # Stale lock (owner is dead, or was never wake-on-event.sh). Drop it
    # and try once more. If a concurrent spawn beat us, exit without
    # racing — there is always going to be a live reader either way.
    rm -f "$LOCKFILE"
    if ! claim_lock; then
        exit 0
    fi
fi

###############################################################################
# Cleanup on real exit (not on exit 2 — Claude Code respawns the hook then)
###############################################################################

cleanup() {
    # Always release the reader lock so the next spawn can claim it.
    # Without this, after `exit 2` the next Stop-hook spawn would see a
    # stale lock with our own (dead) PID and there would be no reader
    # until the PID-reuse protection kicks in.
    release_lock

    # Only purge FIFO/manifest if the parent Claude process is dead.
    # exit 2 keeps the session alive and we want the FIFO preserved for
    # the next spawn.
    if ! kill -0 "$CLAUDE_PID" 2>/dev/null; then
        rm -f "$FIFO" "$MANIFEST"
    fi
}
# EXIT trap for normal exits (exit 0, exit 2).
trap cleanup EXIT
# Signal traps for SIGTERM/SIGHUP/SIGINT must explicitly exit after
# cleanup. In bash, trapping a signal REPLACES the default termination
# behavior — without the explicit `exit`, the script would continue its
# FIFO read loop WITHOUT holding the lock (cleanup released it),
# potentially allowing a concurrent reader and breaking the singleton
# guarantee. Copilot review on PR #48.
# The EXIT trap also fires when we `exit 0` here, calling cleanup a
# second time — this is safe because release_lock is idempotent (it
# re-reads the lockfile and only removes it if we still own it).
trap 'cleanup; exit 0' SIGTERM SIGHUP SIGINT

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

# Forensics directory for invalid payloads. Each parse failure dumps the
# raw bytes of the offending payload here so we can finally see what is
# arriving on the FIFO when the consumer reports "not valid JSON". Resolved
# with explicit safe defaults for both XDG_CONFIG_HOME and HOME, since the
# whole script runs under `set -u` and we must not abort if either env var
# happens to be unset.
INVALID_PAYLOADS_DIR=""
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    INVALID_PAYLOADS_DIR="$XDG_CONFIG_HOME/claude-channels/invalid-payloads"
elif [ -n "${HOME:-}" ]; then
    INVALID_PAYLOADS_DIR="$HOME/.config/claude-channels/invalid-payloads"
fi

# Dump a payload to the forensics directory for later inspection.
# Returns the path of the dumped file on stdout if (and only if) the file
# was actually created. On any failure (no dir, mkdir fails, write fails)
# this prints nothing so callers don't claim a dump location that does
# not exist on disk.
dump_invalid_payload() {
    local payload="$1"
    local origin="$2"
    [ -n "$INVALID_PAYLOADS_DIR" ] || return 0
    mkdir -p "$INVALID_PAYLOADS_DIR" 2>/dev/null || return 0
    local stamp
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    local out="$INVALID_PAYLOADS_DIR/${stamp}-pid${CLAUDE_PID}-${origin}.txt"
    if {
        printf 'timestamp_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'claude_pid: %s\n' "$CLAUDE_PID"
        printf 'fifo: %s\n' "$FIFO"
        printf 'origin: %s\n' "$origin"
        printf 'payload_length_bytes: %s\n' "${#payload}"
        printf '----- raw payload (od -c) -----\n'
        printf '%s' "$payload" | od -c 2>/dev/null || true
        printf '----- end raw payload -----\n'
    } >"$out" 2>/dev/null && [ -s "$out" ]; then
        echo "$out"
    fi
}

# Render an event JSON payload as human-readable instructions on stderr.
# Claude Code captures stderr and re-injects it as a system reminder when
# we exit with code 2.
process_event() {
    local event_data="$1"
    [ -z "$event_data" ] && return 1

    if ! echo "$event_data" | jq empty 2>/dev/null; then
        # Dump the offending payload so we can finally diagnose what
        # producer is writing it. The dump goes to a separate forensics
        # file (NOT stderr) so the system reminder stays compact and
        # actionable.
        local dump_path
        dump_path=$(dump_invalid_payload "$event_data" "process_event")
        {
            echo "[wake-on-event] WAKE EVENT RECEIVED but payload was not valid JSON"
            if [ -n "$dump_path" ]; then
                echo "Raw bytes dumped to: $dump_path"
            fi
            echo ""
            echo "DO NOT passively wait for another wake event. Instead:"
            echo "  1. Identify which PR you are currently working on (the branch you pushed last)"
            echo "  2. Check its state: gh pr view <PR> --repo <REPO> --json state,mergeable,mergeStateStatus,statusCheckRollup"
            echo "  3. If state=OPEN and all CI checks are SUCCESS and Copilot has already reviewed (commented or approved) once, MERGE NOW:"
            echo "       gh pr merge <PR> --repo <REPO> --merge --delete-branch"
            echo "     Copilot reviews each PR EXACTLY ONCE — there will be NO second review wake event after a fix push."
            echo "  4. If CI is still pending → continue your other work; another wake event will fire when it finishes."
            echo "  5. If state=MERGED or CLOSED → there is nothing to do."
            echo "  6. Notify user via mcp__notify__notify with what you decided."
        } >&2
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
                    echo ""
                    echo "ALL CI CHECKS PASSED. Execute this decision procedure NOW:"
                    echo ""
                    echo "Step 1 — run this single command:"
                    echo "  gh pr view $pr_num --repo $repo_name --json state,mergeable,reviews \\"
                    echo "    --jq '{state, mergeable, copilot: ([.reviews[] | select(.author.login | startswith(\"copilot-pull-request-reviewer\"))] | last | {state, submittedAt})}'"
                    echo ""
                    echo "Step 2 — act on the result (FIRST match wins, do NOT deliberate):"
                    echo ""
                    echo "  IF state=MERGED → SKIP. Nothing to do. Log as stale."
                    echo "  IF state=CLOSED → SKIP. PR was abandoned."
                    echo "  IF mergeable=CONFLICTING → rebase or resolve conflicts, push, wait for next ci-complete."
                    echo "  IF mergeable=UNKNOWN → wait a few seconds and re-check (GitHub is computing)."
                    echo "  IF copilot.state is null → Copilot has not reviewed yet. WAIT for code-review-complete wake event."
                    echo "  IF copilot.state is COMMENTED or APPROVED or CHANGES_REQUESTED → Copilot HAS reviewed."
                    echo "    → MERGE IMMEDIATELY:"
                    echo "        gh pr merge $pr_num --repo $repo_name --merge --delete-branch"
                    echo ""
                    echo "  YES, MERGE EVEN IF copilot.state is COMMENTED or CHANGES_REQUESTED."
                    echo "  Copilot reviews each PR EXACTLY ONCE. If you pushed fix commits after"
                    echo "  Copilot's review, there will be NO second review. The CI success you"
                    echo "  just received IS the final green light. MERGE NOW."
                    echo ""
                    echo "  Do NOT:"
                    echo "  - wait for a second Copilot wake event (it will NEVER arrive)"
                    echo "  - re-read Copilot comments to check if they're \"addressed\" (CI passed = addressed)"
                    echo "  - say \"čekám na review\" or \"waiting for review\" in notifications"
                    echo ""
                    echo "Step 3 — after merge, check if this repo has a deploy workflow."
                    echo "  Repos WITH deploy: VirtualAssistant → wait for deploy-complete wake."
                    echo "  Repos WITHOUT deploy: cr, GitHub.Actions.Notify → your job ENDS at merge."
                    echo "  If no deploy workflow exists, notify user: \"PR mergnut, repo nemá deploy workflow, hotovo.\""
                    echo ""
                    echo "Runbook: ~/Olbrasoft/GitHub.Actions.Notify/docs/session-wake-runbook.md"
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
# Startup drain: process DEFER'd events from disk before blocking on FIFO
###############################################################################
#
# When wake-claude.sh cannot deliver via FIFO (session is busy processing
# tools, no asyncRewake reader available), it DEFERs the event to disk:
#   ~/.config/claude-channels/deploy-events/{REPO_PREFIX}*.json
#
# Previously, these DEFER'd files were only drained by check-deploy-status.sh
# on UserPromptSubmit — which never fires in autonomous mode. This caused a
# recurring deadlock:
#
#   1. CI event delivered via FIFO → session wakes, processes it
#   2. Copilot review event arrives seconds later → no reader → DEFER'd to disk
#   3. Session finishes CI processing → Stop → asyncRewake → new hook spawns
#   4. New hook blocks on FIFO — but the review event is on DISK, not in FIFO
#   5. Session waits forever for a FIFO event that will never come
#
# Fix: on every hook startup, check disk FIRST. If a pending event exists
# for this repo, process it immediately and exit 2 (wake the session).
# The FIFO is NOT opened during the drain to prevent a race where
# wake-claude.sh writes to the FIFO (seeing a reader), but the data is
# never consumed (we exit 2 for the disk event instead).

EVENTS_DIR="${HOME}/.config/claude-channels/deploy-events"
REPO_PREFIX=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' | tr '/' '-')

if [ -n "$REPO_PREFIX" ] && [ -d "$EVENTS_DIR" ]; then
    for event_file in "$EVENTS_DIR"/${REPO_PREFIX}*.json; do
        [ -f "$event_file" ] || continue
        event_data=$(cat "$event_file" 2>/dev/null)
        rm -f "$event_file"
        if [ -n "$event_data" ]; then
            echo "[wake-on-event] Startup drain: processing DEFER'd event: $(basename "$event_file")" >&2
            process_event "$event_data"
            exit 2
        fi
    done
fi

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
# for up to FIFO_TIMEOUT_SECS in `read`. If the parent dies during
# that block, the hook gets reparented to systemd-user and would
# otherwise stay alive forever, accumulating one orphan per dead
# session. See bug 32.
parent_alive() {
    kill -0 "$CLAUDE_PID" 2>/dev/null
}

# FIFO read timeout (seconds). After each timeout the loop drains any
# DEFER'd events from disk.  120s is a good balance between latency
# (how long a DEFER'd event waits) and efficiency (how often we wake
# from sleep to do a no-op glob).
FIFO_TIMEOUT_SECS=120

while true; do
    if ! parent_alive; then
        # Parent Claude died while we were idle. Bail out before re-arming
        # the read so we do not become an orphan.
        exec 3<&-
        exit 0
    fi
    # Read one NDJSON line with a timeout. read returns 0 on success,
    # non-zero on timeout or EOF (but FD 3 is also write-open, so we
    # never see real EOF).
    EVENT_DATA=""
    if IFS= read -r -t "$FIFO_TIMEOUT_SECS" EVENT_DATA <&3; then
        if ! parent_alive; then
            exec 3<&-
            exit 0
        fi
        [ -z "$EVENT_DATA" ] && { exec 3<&-; exit 2; }
        process_event "$EVENT_DATA"
        exec 3<&-
        exit 2
    fi

    ###########################################################################
    # Loop drain: check disk for DEFER'd events on every FIFO timeout
    ###########################################################################
    #
    # Same logic as startup drain but runs periodically while the hook is
    # alive. Catches events that were DEFER'd by wake-claude.sh when this
    # hook's FIFO had no reader (e.g. during a previous tool-execution gap
    # that caused the prior hook instance to exit 2 for a different event).
    if [ -n "$REPO_PREFIX" ] && [ -d "$EVENTS_DIR" ]; then
        for event_file in "$EVENTS_DIR"/${REPO_PREFIX}*.json; do
            [ -f "$event_file" ] || continue
            event_data=$(cat "$event_file" 2>/dev/null)
            rm -f "$event_file"
            if [ -n "$event_data" ]; then
                echo "[wake-on-event] Loop drain: processing DEFER'd event: $(basename "$event_file")" >&2
                process_event "$event_data"
                exec 3<&-
                exit 2
            fi
        done
    fi

    # Refresh manifest with current cwd (cheap) and loop back.
    jq -n \
        --argjson pid "$CLAUDE_PID" \
        --arg fifo "$FIFO" \
        --arg cwd "$(pwd)" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{pid: $pid, fifo: $fifo, cwd: $cwd, created: $created}' > "$MANIFEST" 2>/dev/null
done
