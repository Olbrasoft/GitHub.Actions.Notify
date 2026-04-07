#!/bin/bash
# wake-claude.sh — single-transaction event delivery to a running Claude Code
# session.
#
# Called by:
#   - GitHub Actions workflows (deploy.yml, ci.yml) on the self-hosted runner
#   - webhook-receiver.py (for pull_request_review and check_suite events)
#
# Usage:
#   wake-claude.sh <REPO> [<BRANCH>]
#
#     REPO:   "Olbrasoft/cr" or "Olbrasoft-cr" (auto-converted)
#     BRANCH: optional hint for narrowing session selection
#
# Algorithm — ONE TRANSACTION, no daemons, no registry, no inbox:
#
#   1. Read all events from $EVENTS_DIR matching this repo prefix
#   2. For each event:
#      a. Try to extract a target Claude PID from the PR body marker
#         <!-- claude-pid: NNN --> using gh api (if PR number is derivable).
#         If marker points to a live Claude process → use it.
#      b. Otherwise (marker missing or stale), enumerate ALL live Claude
#         processes via pgrep -x claude and find ones whose /proc/PID/cwd
#         matches the repo basename. STRICT MATCHING:
#           - exactly 1 match → use it
#           - 0 matches OR 2+ matches → DROP (ambiguous, refuse to guess)
#      c. If no live target found → DROP event, exit 0
#      d. Find the target session's FIFO at /tmp/claude-wake/.session-<PID>.fifo
#      e. Kill any orphan readers on that FIFO (PPID = systemd-user)
#      f. Write the event JSON to the FIFO with bounded retry (up to 60s,
#         polling every 1s, re-checking liveness between attempts)
#      g. On success → delete event file. On timeout → drop event.
#
# This script holds NO state between invocations. Each call is a complete
# transaction that ends in either DELIVERED or DROPPED.

set -u

REPO_RAW="${1:-}"
BRANCH_HINT="${2:-}"

[ -z "$REPO_RAW" ] && { echo "[wake-claude] usage: $0 <REPO> [<BRANCH>]" >&2; exit 1; }

# Normalize repo: "Olbrasoft/cr" → "Olbrasoft-cr" (file form),
#                 keep slash form for gh api calls.
REPO_FILE=$(echo "$REPO_RAW" | tr '/' '-')
if [[ "$REPO_RAW" == */* ]]; then
    REPO_FULL="$REPO_RAW"
else
    # Convert dashed back to slash form for gh api: assume first dash = owner/repo split
    REPO_FULL=$(echo "$REPO_RAW" | sed 's/-/\//')
fi

EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"
WAKE_DIR="/tmp/claude-wake"
WRITE_RETRY_SECS="${WAKE_CLAUDE_RETRY_SECS:-60}"
WRITE_TIMEOUT="${WAKE_CLAUDE_WRITE_TIMEOUT:-3}"

[ -d "$EVENTS_DIR" ] || exit 0

###############################################################################
# Helpers
###############################################################################

log() { echo "[wake-claude] $*" >&2; }

# Get the local repo path for cwd matching. We use the basename of the repo.
# E.g. "Olbrasoft/VirtualAssistant" → "VirtualAssistant"
repo_basename() {
    echo "${REPO_FULL##*/}"
}

# Enumerate live Claude PIDs whose cwd basename equals the given repo basename.
# Echoes each matching PID on its own line, one per line.
find_claude_pids_for_repo() {
    local basename
    basename=$(repo_basename)
    [ -z "$basename" ] && return 0

    for pid in $(pgrep -x claude 2>/dev/null); do
        local cwd
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
        if [ "${cwd##*/}" = "$basename" ]; then
            echo "$pid"
        fi
    done
}

# Try to extract a Claude target PID from a PR body marker.
# Marker format: <!-- claude-pid: NNN -->
# Returns empty string if no marker found or gh api fails.
pid_from_pr_body() {
    local pr_num="$1"
    [ -z "$pr_num" ] && return 0

    local body
    body=$(timeout 10 gh pr view "$pr_num" --repo "$REPO_FULL" --json body --jq '.body' 2>/dev/null)
    [ -z "$body" ] && return 0

    if [[ "$body" =~ claude-pid:[[:space:]]*([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Verify a PID is a live Claude process. Returns 0 if alive Claude, 1 otherwise.
is_live_claude() {
    local pid="$1"
    [ -z "$pid" ] && return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -le 1 ] && return 1
    [ "$(cat /proc/$pid/comm 2>/dev/null)" = "claude" ] || return 1
    return 0
}

# Kill any orphan FIFO readers for a given target FIFO.
# Orphans are wake-on-event.sh processes whose grandparent is NOT a claude process
# (i.e. they were reparented to systemd-user after their original session died).
kill_orphan_readers_for_fifo() {
    local fifo="$1"
    local killed=0
    for pid in $(pgrep -f wake-on-event.sh 2>/dev/null); do
        # Walk up: pid → parent → grandparent. If we never see "claude",
        # this hook is orphaned.
        local cur="$pid"
        local found_claude=0
        local depth=0
        while [ "$cur" -gt 1 ] && [ "$depth" -lt 8 ]; do
            local cur_comm
            cur_comm=$(cat "/proc/$cur/comm" 2>/dev/null) || break
            if [ "$cur_comm" = "claude" ]; then
                found_claude=1
                break
            fi
            cur=$(awk '{print $4}' "/proc/$cur/stat" 2>/dev/null) || break
            depth=$((depth + 1))
        done

        if [ "$found_claude" = "0" ]; then
            # Verify this orphan is reading our target FIFO before killing.
            # Children of the orphan include `timeout 600 cat $fifo`.
            local cmdlines
            cmdlines=$(pgrep -af "cat $fifo" 2>/dev/null)
            if echo "$cmdlines" | grep -q "$fifo"; then
                log "Killing orphan reader PID $pid (FIFO $fifo)"
                pkill -9 -P "$pid" 2>/dev/null
                kill -9 "$pid" 2>/dev/null
                killed=$((killed + 1))
            fi
        fi
    done
    [ "$killed" -gt 0 ] && log "Killed $killed orphan reader(s) for $fifo"
}

# Write event data to a FIFO with bounded retry. Returns 0 on success,
# 1 on liveness loss or timeout.
write_with_retry() {
    local fifo="$1"
    local data="$2"
    local target_pid="$3"
    local deadline=$(($(date +%s) + WRITE_RETRY_SECS))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        # Re-check target liveness each iteration.
        if ! is_live_claude "$target_pid"; then
            log "Target PID $target_pid died during retry"
            return 1
        fi
        # FIFO must still exist.
        if [ ! -p "$fifo" ]; then
            log "FIFO $fifo disappeared during retry"
            return 1
        fi
        # Try short bounded write. If a reader is on the FIFO, this succeeds
        # immediately; if not, it times out after WRITE_TIMEOUT seconds.
        if WAKE_DATA="$data" WAKE_FIFO="$fifo" \
            timeout "$WRITE_TIMEOUT" \
            bash -c 'printf "%s" "$WAKE_DATA" > "$WAKE_FIFO"' 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

###############################################################################
# Process a single event file
###############################################################################

process_event_file() {
    local event_file="$1"
    [ -f "$event_file" ] || return

    local event_data
    event_data=$(cat "$event_file" 2>/dev/null)
    if [ -z "$event_data" ]; then
        log "DROP empty: ${event_file##*/}"
        rm -f "$event_file"
        return
    fi

    if ! echo "$event_data" | jq empty 2>/dev/null; then
        log "DROP invalid JSON: ${event_file##*/}"
        rm -f "$event_file"
        return
    fi

    # Extract optional PR number from event
    local pr_num
    pr_num=$(echo "$event_data" | jq -r '.prNumber // empty')

    if [ -z "$pr_num" ]; then
        # Try to derive from commit SHA via gh. Strip whitespace and reject
        # any non-numeric output (gh api errors leak multi-line JSON otherwise).
        local commit_sha
        commit_sha=$(echo "$event_data" | jq -r '.commit // empty')
        if [ -n "$commit_sha" ]; then
            pr_num=$(timeout 10 gh api "repos/${REPO_FULL}/commits/${commit_sha}/pulls" --jq '.[0].number // empty' 2>/dev/null | tr -d '[:space:]')
            case "$pr_num" in ''|*[!0-9]*) pr_num="" ;; esac
        fi
    fi

    # Find target PID — primary: PR body marker, fallback: cwd matching
    local target_pid=""
    if [ -n "$pr_num" ]; then
        target_pid=$(pid_from_pr_body "$pr_num")
        if [ -n "$target_pid" ] && ! is_live_claude "$target_pid"; then
            log "PR body marker PID $target_pid is not a live Claude — falling back to cwd matching"
            target_pid=""
        fi
    fi

    if [ -z "$target_pid" ]; then
        # Strict cwd matching: deliver only if EXACTLY ONE running Claude
        # session is on the matching repo. If 0 or 2+ matches, refuse to
        # guess and drop.
        local matches
        matches=$(find_claude_pids_for_repo)
        local count
        count=$(echo "$matches" | grep -c .)
        if [ "$count" = "0" ]; then
            log "DROP no Claude session on $REPO_FULL (PR=${pr_num:-?}): ${event_file##*/}"
            rm -f "$event_file"
            return
        fi
        if [ "$count" -gt 1 ]; then
            log "DROP ambiguous: $count Claude sessions on $REPO_FULL (PR=${pr_num:-?}, PIDs=$(echo $matches | tr '\n' ' ')): ${event_file##*/}"
            rm -f "$event_file"
            return
        fi
        target_pid="$matches"
    fi

    if ! is_live_claude "$target_pid"; then
        log "DROP target PID $target_pid not a live Claude: ${event_file##*/}"
        rm -f "$event_file"
        return
    fi

    local fifo="$WAKE_DIR/.session-${target_pid}.fifo"
    if [ ! -p "$fifo" ]; then
        log "DROP no FIFO for PID $target_pid ($fifo): ${event_file##*/}"
        rm -f "$event_file"
        return
    fi

    # Kill orphan readers BEFORE writing — guarantees the legit reader gets
    # the event, not a zombie.
    kill_orphan_readers_for_fifo "$fifo"

    if write_with_retry "$fifo" "$event_data" "$target_pid"; then
        rm -f "$event_file"
        log "DELIVERED ${event_file##*/} → PID $target_pid (PR=${pr_num:-?})"
    else
        log "DROP after ${WRITE_RETRY_SECS}s retry: ${event_file##*/} (PID $target_pid, PR=${pr_num:-?})"
        rm -f "$event_file"
    fi
}

###############################################################################
# Main: process all event files for this repo
###############################################################################

for ef in "$EVENTS_DIR"/${REPO_FILE}*.json; do
    [ -f "$ef" ] || continue
    process_event_file "$ef"
done
