#!/bin/bash
# wake-claude.sh — single-transaction event delivery to a running Claude Code
# session.
#
# Called by:
#   - GitHub Actions workflows (deploy.yml, ci.yml) on the self-hosted runner
#   - webhook-receiver.py (for pull_request_review and check_suite events)
#
# Usage:
#   wake-claude.sh <REPO>
#
#     REPO: "Olbrasoft/cr" (preferred) or "Olbrasoft-cr" (legacy single-dash
#           form; ambiguous with 2+ dashes — use slash form instead)
#
# Algorithm — ONE TRANSACTION, no daemons, no registry, no inbox:
#
#   1. Read all events from $EVENTS_DIR matching this repo prefix
#   2. For each event:
#      a. PRIMARY routing — extract claude-session UUID marker from PR body
#         (<!-- claude-session: UUID -->) via gh pr view. The UUID is the
#         basename of the JSONL file in ~/.claude/projects/<encoded-cwd>/.
#         Find the live Claude PID whose CURRENT session (most recently
#         modified JSONL in its cwd's project dir) matches this UUID.
#         If found → that's the target.
#      b. FALLBACK routing — if no marker, or marker session not running,
#         enumerate ALL live Claude processes via pgrep -x claude and find
#         ones whose /proc/PID/cwd basename matches the repo. STRICT:
#           - exactly 1 match → use it
#           - 0 matches OR 2+ matches → DROP (ambiguous, refuse to guess)
#      c. If no live target found → DROP event, exit 0
#      d. Find the target session's FIFO at /tmp/claude-wake/.session-<PID>.fifo
#      e. Kill any orphan readers on that FIFO (PPID = systemd-user)
#      f. Write the event JSON to the FIFO with bounded retry (up to 300s,
#         polling every 1s, re-checking liveness between attempts)
#      g. On success → delete event file. On timeout → drop event.
#
# This script holds NO state between invocations. Each call is a complete
# transaction that ends in either DELIVERED or DROPPED.

set -u

REPO_RAW="${1:-}"

[ -z "$REPO_RAW" ] && { echo "[wake-claude] usage: $0 <REPO>" >&2; exit 1; }

# Normalize repo: "Olbrasoft/cr" → "Olbrasoft-cr" (file form),
#                 keep slash form for gh api calls.
REPO_FILE=$(echo "$REPO_RAW" | tr '/' '-')
if [[ "$REPO_RAW" == */* ]]; then
    REPO_FULL="$REPO_RAW"
elif [[ "$REPO_RAW" == *-* && "$REPO_RAW" != *-*-* ]]; then
    # Legacy dashed form is only safe when there is exactly one dash
    # (single-dash owner/repo). Replace the only dash with a slash.
    REPO_FULL="${REPO_RAW/-//}"
else
    # Multiple dashes are ambiguous (could be "my-org/repo", "org/my-repo",
    # or "my-org/my-repo") — refuse to guess.
    echo "[wake-claude] ambiguous repo '$REPO_RAW': use owner/repo form for repositories with multiple dashes" >&2
    exit 1
fi

EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"
WAKE_DIR="/tmp/claude-wake"
PROJECTS_DIR="$HOME/.claude/projects"
WRITE_RETRY_SECS="${WAKE_CLAUDE_RETRY_SECS:-300}"
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

# Extract the claude-session UUID from a PR body marker.
# Marker format: <!-- claude-session: UUID -->
# Returns empty string if no marker found or gh api fails.
session_uuid_from_pr_body() {
    local pr_num="$1"
    [ -z "$pr_num" ] && return 0

    local body
    body=$(timeout 10 gh pr view "$pr_num" --repo "$REPO_FULL" --json body --jq '.body' 2>/dev/null)
    [ -z "$body" ] && return 0

    if [[ "$body" =~ claude-session:[[:space:]]*([a-f0-9-]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Find the live Claude PID whose CURRENT session is the given UUID. The
# current session is the most-recently-modified .jsonl file in the project
# directory keyed by the Claude process's cwd.
#
# Returns empty string if no live Claude has the given session as current.
pid_for_session_uuid() {
    local uuid="$1"
    [ -z "$uuid" ] && return 0

    for pid in $(pgrep -x claude 2>/dev/null); do
        local cwd
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
        local enc proj_dir
        enc=$(echo "$cwd" | sed 's|/|-|g')
        proj_dir="$PROJECTS_DIR/$enc"
        [ -d "$proj_dir" ] || continue

        # Most-recently-modified JSONL is the active session for this PID.
        local latest
        latest=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1)
        [ -z "$latest" ] && continue
        local basename="${latest##*/}"
        if [ "${basename%.jsonl}" = "$uuid" ]; then
            echo "$pid"
            return 0
        fi
    done
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

# Recursively collect all descendants of a given PID into the variable
# named by $1. Sets the variable to a newline-separated list (excludes the
# starting PID).
collect_descendants() {
    local result_var="$1"
    local root_pid="$2"
    local stack="$root_pid"
    local result=""
    while [ -n "$stack" ]; do
        local current="${stack%%$'\n'*}"
        if [ "$stack" = "$current" ]; then
            stack=""
        else
            stack="${stack#*$'\n'}"
        fi
        local child
        for child in $(pgrep -P "$current" 2>/dev/null); do
            result="$result$child"$'\n'
            stack="$stack$child"$'\n'
        done
    done
    eval "$result_var=\$result"
}

# Check whether the given PID is a `cat` process whose argv contains the
# given FIFO path as a literal (fixed-string match — no regex).
proc_is_cat_of_fifo() {
    local pid="$1"
    local fifo="$2"
    local comm
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || return 1
    [ "$comm" = "cat" ] || return 1
    # /proc/<pid>/cmdline is NUL-separated argv. Read it and check whether
    # any argument equals the FIFO path exactly.
    local cmdline
    cmdline=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    while IFS= read -r arg; do
        [ "$arg" = "$fifo" ] && return 0
    done <<< "$cmdline"
    return 1
}

# Kill orphan FIFO readers for a given target FIFO.
#
# An orphan reader is a wake-on-event.sh process whose process tree does NOT
# walk up to a live `claude` ancestor (its original session died and it was
# reparented). This function:
#   1. Enumerates wake-on-event.sh processes
#   2. For each, checks the parent chain for a `claude` ancestor
#   3. If no `claude` ancestor → walks the orphan's descendant tree to find
#      its `cat $fifo` reader (which is typically a grandchild of the script:
#      script → bash subshell → timeout → cat). Uses fixed-string matching
#      against /proc/<pid>/cmdline argv to avoid regex pitfalls with `.`
#      in the FIFO path.
#   4. If the orphan has a cat reading our specific FIFO → kill the entire
#      descendant tree of the orphan, then the orphan itself
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

        [ "$found_claude" = "1" ] && continue

        # Walk the orphan's full descendant tree and look for a `cat`
        # process whose argv contains our target FIFO as a literal.
        local orphan_descendants=""
        collect_descendants orphan_descendants "$pid"
        local orphan_owns_fifo=0
        local desc
        while IFS= read -r desc; do
            [ -z "$desc" ] && continue
            if proc_is_cat_of_fifo "$desc" "$fifo"; then
                orphan_owns_fifo=1
                break
            fi
        done <<< "$orphan_descendants"

        [ "$orphan_owns_fifo" = "0" ] && continue

        # Kill the entire descendant tree of the orphan, then the orphan
        # itself. We re-collect descendants because the tree may have
        # changed since the previous walk.
        log "Killing orphan reader PID $pid (FIFO $fifo)"
        local kill_targets=""
        collect_descendants kill_targets "$pid"
        local target
        while IFS= read -r target; do
            [ -z "$target" ] && continue
            kill -9 "$target" 2>/dev/null
        done <<< "$kill_targets"
        kill -9 "$pid" 2>/dev/null
        killed=$((killed + 1))
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
        #
        # Each event is terminated by a newline (NDJSON framing) so the
        # consumer can read one event per `read -r` call. Without this,
        # two writers landing back-to-back end up concatenated as
        # `{...}{...}` and the consumer's `cat` returns garbled JSON.
        # Bug 33.
        if WAKE_DATA="$data" WAKE_FIFO="$fifo" \
            timeout "$WRITE_TIMEOUT" \
            bash -c 'printf "%s\n" "$WAKE_DATA" > "$WAKE_FIFO"' 2>/dev/null; then
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

    # Find target PID — PRIMARY: session UUID from PR body marker
    #                  FALLBACK: strict cwd matching (exactly one Claude on repo)
    local target_pid=""
    local session_uuid=""
    if [ -n "$pr_num" ]; then
        session_uuid=$(session_uuid_from_pr_body "$pr_num")
        if [ -n "$session_uuid" ]; then
            target_pid=$(pid_for_session_uuid "$session_uuid")
            if [ -z "$target_pid" ]; then
                log "Session UUID $session_uuid (from PR #$pr_num body) has no live Claude — falling back to cwd matching"
            fi
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
# Sweep stale per-session FIFOs and manifests for dead Claude PIDs
###############################################################################
#
# wake-on-event.sh installs a cleanup() trap that removes its FIFO + manifest
# when the script exits AND the Claude PID is dead. But the trap only fires
# inside a *running* hook process. If the Claude session dies while no hook
# is currently in cat (the asyncRewake hook only spawns at SessionStart/Stop
# boundaries), the trap never runs and the FIFO leaks. See bug 36.
#
# We sweep at the start of every wake-claude.sh invocation: cheap, idempotent,
# and runs whenever there is wake activity for any repo.
sweep_stale_session_files() {
    local f pid
    for f in "$WAKE_DIR"/.session-*.fifo "$WAKE_DIR"/.session-*.json; do
        [ -e "$f" ] || continue
        pid="${f##*/.session-}"
        pid="${pid%.fifo}"
        pid="${pid%.json}"
        # Numeric PID check — skip anything that does not match the pattern.
        case "$pid" in
            ''|*[!0-9]*) continue ;;
        esac
        if ! kill -0 "$pid" 2>/dev/null; then
            log "Sweeping stale ${f##*/} (PID $pid dead)"
            rm -f "$f"
        fi
    done
}
sweep_stale_session_files

###############################################################################
# Main: process all event files for this repo
###############################################################################
#
# Dedup duplicate events within this invocation. The legacy filename scheme
# for deploy/verify events includes {run_id}-{run_attempt}, so workflow
# re-runs produce multiple files for the same logical event:
#
#   Olbrasoft-cr-verify-abc1234-241234-1.json
#   Olbrasoft-cr-verify-abc1234-241235-1.json   # re-run
#
# Both files contain the same (event_type, commit, environment) tuple. We
# pick the file with the LATEST timestamp inside the JSON for each tuple,
# deliver only that one, and drop the rest. The dedup key includes the
# environment so events for staging vs production on the same commit are
# NOT treated as duplicates.

declare -A event_winner   # key: "event_type|commit|env" → file path
declare -A event_winner_ts  # key: "event_type|commit|env" → timestamp

for ef in "$EVENTS_DIR"/${REPO_FILE}*.json; do
    [ -f "$ef" ] || continue
    # Read minimum metadata to dedup. Skip files we cannot parse — let the
    # main loop drop them with the standard "invalid JSON" diagnostic.
    if ! jq empty "$ef" 2>/dev/null; then
        continue
    fi
    et=$(jq -r '.event // ""' "$ef" 2>/dev/null)
    sha=$(jq -r '.commit // ""' "$ef" 2>/dev/null)
    env=$(jq -r '.environment // ""' "$ef" 2>/dev/null)
    ts=$(jq -r '.timestamp // ""' "$ef" 2>/dev/null)
    # If we cannot identify the logical key, treat the file as unique.
    if [ -z "$et" ] || [ -z "$sha" ]; then
        continue
    fi
    key="$et|$sha|$env"
    if [ -z "${event_winner[$key]:-}" ] || [[ "$ts" > "${event_winner_ts[$key]:-}" ]]; then
        # Drop the previous winner for this key (it is a logical duplicate
        # superseded by a newer file).
        if [ -n "${event_winner[$key]:-}" ]; then
            log "DEDUP drop ${event_winner[$key]##*/} (superseded by ${ef##*/} for $key)"
            rm -f "${event_winner[$key]}"
        fi
        event_winner[$key]="$ef"
        event_winner_ts[$key]="$ts"
    else
        log "DEDUP drop ${ef##*/} (older than ${event_winner[$key]##*/} for $key)"
        rm -f "$ef"
    fi
done

# Now process each surviving file (one per logical key, plus any unparseable
# leftovers).
for ef in "$EVENTS_DIR"/${REPO_FILE}*.json; do
    [ -f "$ef" ] || continue
    process_event_file "$ef"
done
