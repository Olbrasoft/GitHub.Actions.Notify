#!/bin/bash
# Wake Claude Code sessions via FIFO.
#
# Usage:
#   wake-claude.sh <REPO> [BRANCH]
#
# REPO: e.g. "Olbrasoft-cr" or "Olbrasoft/cr" (auto-converted)
# BRANCH: optional — if given, only wake sessions on this branch
#         if omitted, wake ALL sessions for the repo (deploy events)
#
# Design contract:
#
# 1. Event files in $EVENTS_DIR are a DURABLE QUEUE. They persist on disk
#    until a consumer (this script via FIFO, or check-deploy-status.sh on
#    UserPromptSubmit) has positively confirmed receipt.
#
# 2. FIFO writes are the FAST PATH. Each FIFO write is synchronous (blocks
#    until the consumer reads), so a successful write IS the ack — the
#    kernel guarantees the consumer has the data.
#
# 3. The producer (this script) deletes an event file ONLY after at least
#    one live consumer has acked it via FIFO. If 0 consumers are alive at
#    wake time, the file persists and is picked up by check-deploy-status.sh
#    on the next UserPromptSubmit. No event is ever silently dropped.
#
# 4. Multiple event files for the same repo coexist (filename includes a
#    discriminator like commit SHA). This script processes each file
#    independently against all matching sessions.
#
# 5. Branch routing queries the LIVE branch from the session's cwd via
#    `git -C $cwd rev-parse --abbrev-ref HEAD`, NOT the cached value in
#    the registration JSON. The cache is only refreshed every 600s and
#    goes stale the moment the user runs `git checkout`.

REPO=$(echo "$1" | tr '/' '-')
TARGET_BRANCH="$2"
FIFO_WRITE_TIMEOUT="${WAKE_CLAUDE_FIFO_TIMEOUT:-5}"  # seconds

[ -z "$REPO" ] && exit 0

WAKE_DIR="/tmp/claude-wake/$REPO"
EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"

# Build the list of event files for this repo. Each file is processed
# independently. If no event files exist, fall back to a single synthetic
# wake event so the consumer at least learns the repo had activity.
EVENT_FILES=()
if [ -d "$EVENTS_DIR" ]; then
    for ef in "$EVENTS_DIR"/${REPO}*.json; do
        [ -f "$ef" ] && EVENT_FILES+=("$ef")
    done
fi

if [ ${#EVENT_FILES[@]} -eq 0 ]; then
    SYNTHETIC_EVENT='{"event":"wake","repository":"'"$REPO"'"}'
fi

# If no wake directory exists yet, no sessions can be woken via FIFO. The
# event files (if any) stay on disk for check-deploy-status.sh to drain on
# the next UserPromptSubmit.
if [ ! -d "$WAKE_DIR" ]; then
    if [ ${#EVENT_FILES[@]} -gt 0 ]; then
        echo "[wake-claude] No live sessions for $REPO; ${#EVENT_FILES[@]} event file(s) left for fallback" >&2
    fi
    exit 0
fi

# Try to deliver event data through a FIFO and wait for the consumer to
# acknowledge. A successful write to a FIFO blocks until the reader has
# consumed the data, so write-success == ack. Bounded by a timeout in case
# the consumer is wedged.
#
# The payload is passed via environment variables (not argv) so it does not
# count against ARG_MAX, and printf is used instead of echo so that backslash
# escapes and leading hyphens in the payload are preserved verbatim.
#
# Returns 0 on success (acked), 1 on failure or timeout.
write_with_ack() {
    local fifo="$1"
    local data="$2"
    WAKE_DATA="$data" WAKE_FIFO="$fifo" \
        timeout "$FIFO_WRITE_TIMEOUT" \
        bash -c 'printf "%s" "$WAKE_DATA" > "$WAKE_FIFO"' 2>/dev/null
}

deliver_event() {
    # $1 = event data string
    # $2 = optional event file path (deleted if at least one consumer acks)
    local event_data="$1"
    local event_file="$2"
    local woken=0
    local skipped=0

    for reg in "$WAKE_DIR"/*.json; do
        [ -f "$reg" ] || continue

        local pid cwd cached_branch fifo
        pid=$(jq -r '.pid' "$reg" 2>/dev/null)
        cwd=$(jq -r '.cwd' "$reg" 2>/dev/null)
        cached_branch=$(jq -r '.branch' "$reg" 2>/dev/null)
        fifo="$WAKE_DIR/$pid.fifo"

        # Check if process is still alive — clean up stale registration if not
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$reg" "$fifo"
            continue
        fi

        # Branch routing: query LIVE branch from session's cwd. Cached value
        # in the JSON is only refreshed every 600s and goes stale immediately
        # after a `git checkout`.
        local live_branch=""
        if [ -n "$cwd" ] && [ "$cwd" != "null" ] && [ -d "$cwd" ]; then
            live_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
        fi

        local effective_branch
        if [ -n "$live_branch" ]; then
            effective_branch="$live_branch"
        else
            effective_branch="$cached_branch"
        fi

        # Skip if a target branch was specified and we can determine that the
        # session is on a different branch. If we cannot determine the branch
        # at all, wake the session anyway (better to wake an extra session
        # than to drop an event silently).
        if [ -n "$TARGET_BRANCH" ] \
            && [ "$effective_branch" != "$TARGET_BRANCH" ] \
            && [ "$effective_branch" != "unknown" ] \
            && [ -n "$effective_branch" ]; then
            echo "[wake-claude] Skip PID=$pid (live=$live_branch cached=$cached_branch target=$TARGET_BRANCH)" >&2
            skipped=$((skipped + 1))
            continue
        fi

        # Try to deliver via FIFO with ack timeout
        if [ -p "$fifo" ]; then
            if write_with_ack "$fifo" "$event_data"; then
                woken=$((woken + 1))
                echo "[wake-claude] Wake PID=$pid acked (live=$live_branch target=$TARGET_BRANCH)" >&2
            else
                echo "[wake-claude] Wake PID=$pid FIFO write timed out after ${FIFO_WRITE_TIMEOUT}s" >&2
            fi
        fi
    done

    # Delete the event file ONLY if at least one consumer acked the delivery.
    # If 0 consumers acked, the file persists for the UserPromptSubmit fallback.
    if [ "$woken" -gt 0 ] && [ -n "$event_file" ] && [ -f "$event_file" ]; then
        rm -f "$event_file"
        echo "[wake-claude] Event file deleted after $woken ack(s): ${event_file##*/}" >&2
    elif [ "$woken" -eq 0 ] && [ -n "$event_file" ]; then
        echo "[wake-claude] Event file kept (0 acks): ${event_file##*/}" >&2
    fi

    echo "[wake-claude] Woke $woken session(s), skipped $skipped for $REPO${TARGET_BRANCH:+ branch=$TARGET_BRANCH}${event_file:+ event=${event_file##*/}}" >&2
}

# Process each event file independently. If none exist, deliver a synthetic
# wake so consumers know the repo had activity.
if [ ${#EVENT_FILES[@]} -gt 0 ]; then
    for ef in "${EVENT_FILES[@]}"; do
        EVENT_DATA=$(cat "$ef" 2>/dev/null)
        [ -z "$EVENT_DATA" ] && continue
        deliver_event "$EVENT_DATA" "$ef"
    done
else
    deliver_event "$SYNTHETIC_EVENT" ""
fi
