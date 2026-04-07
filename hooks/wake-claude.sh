#!/bin/bash
# Notifier: deliver one CI/CD event to the Claude Code session that owns
# the related PR. Producer-side script — invoked by GitHub Actions
# workflows (deploy.yml, verify.yml) and by webhook-receiver.py.
#
# Session-bound contract (see docs/architecture.md):
#
#   1. Each event file in $EVENTS_DIR carries a repo + PR number (or a
#      commit SHA from which the PR can be derived).
#   2. Each PR has at most ONE owner session, recorded in
#      ~/.config/claude-channels/pr-owners/{repo}-{pr}.json. The owner is
#      the Claude Code session that ran `gh pr create` for the PR; the
#      ownership is registered automatically by the PostToolUse hook.
#   3. Delivery rules:
#      - Owner record exists AND owner PID is alive →
#        synchronous FIFO write with ack timeout. On success, delete
#        the event file. The owner session is woken via its asyncRewake
#        hook, sees the event in its system reminder, and reacts.
#      - Owner record exists BUT owner PID is dead →
#        delete the owner record AND delete the event file. No fallback,
#        no broadcast, no future delivery. The user explicitly chose
#        "drop on dead" semantics: opening a new session later does NOT
#        replay missed events.
#      - No owner record →
#        delete the event file (the PR was created without registration
#        — should never happen with PostToolUse auto-register, treated
#        as a producer bug).
#
# Usage:
#   wake-claude.sh <REPO>
#
#   REPO: e.g. "Olbrasoft-VirtualAssistant" or "Olbrasoft/VirtualAssistant"
#         (auto-converted)
#
# The script processes ALL event files matching the repo prefix in one
# invocation, each delivered (or dropped) independently.

set -u

REPO=$(echo "$1" | tr '/' '-')
FIFO_WRITE_TIMEOUT="${WAKE_CLAUDE_FIFO_TIMEOUT:-5}"  # seconds

[ -z "$REPO" ] && exit 0

EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"
PR_OWNERS_DIR="$HOME/.config/claude-channels/pr-owners"

[ -d "$EVENTS_DIR" ] || exit 0

# Try to deliver event data through a FIFO and wait for the consumer to
# acknowledge. A successful write to a FIFO blocks until the reader has
# consumed the data, so write-success == ack. Bounded by a timeout in case
# the consumer is wedged.
#
# Payload is passed via env vars (not argv) so it does not count against
# ARG_MAX, and printf is used instead of echo so backslash escapes are
# preserved verbatim.
#
# Returns 0 on success (acked), 1 on failure or timeout.
write_with_ack() {
    local fifo="$1"
    local data="$2"
    WAKE_DATA="$data" WAKE_FIFO="$fifo" \
        timeout "$FIFO_WRITE_TIMEOUT" \
        bash -c 'printf "%s" "$WAKE_DATA" > "$WAKE_FIFO"' 2>/dev/null
}

# Look up the owner record for a given (repo, pr) tuple. Echoes the
# owner JSON to stdout if found, or empty string if no owner.
lookup_owner() {
    local repo="$1"
    local pr="$2"
    local owner_file="$PR_OWNERS_DIR/${repo}-${pr}.json"
    [ -f "$owner_file" ] || { echo ""; return 1; }
    cat "$owner_file"
}

# Drop both the event file and (if applicable) the owner registration.
# Used when the owner is dead or missing — no replay, no fallback.
drop_event() {
    local event_file="$1"
    local reason="$2"
    rm -f "$event_file"
    echo "[wake-claude] DROPPED ${event_file##*/}: $reason" >&2
}

# Process a single event file. Returns silently — diagnostic logging via
# stderr only.
process_event_file() {
    local event_file="$1"
    [ -f "$event_file" ] || return

    local event_data
    event_data=$(cat "$event_file" 2>/dev/null)
    if [ -z "$event_data" ]; then
        drop_event "$event_file" "empty payload"
        return
    fi

    if ! echo "$event_data" | jq empty 2>/dev/null; then
        drop_event "$event_file" "invalid JSON"
        return
    fi

    # Extract the PR number. Different event types put it in different
    # places: code-review-complete and ci-complete have prNumber at the
    # top level; deploy-complete and verify-complete carry only commit
    # info — for those we need to look up the PR by commit SHA via gh.
    local pr_num
    pr_num=$(echo "$event_data" | jq -r '.prNumber // empty')

    if [ -z "$pr_num" ]; then
        # Deploy/verify event without explicit prNumber. Look up the PR
        # whose merge commit matches the event's commit SHA. The lookup
        # uses gh and is bounded by a short timeout — if it fails, drop.
        local commit_sha
        commit_sha=$(echo "$event_data" | jq -r '.commit // empty')
        local repo_full
        repo_full=$(echo "$event_data" | jq -r '.repository // empty')
        if [ -n "$commit_sha" ] && [ -n "$repo_full" ]; then
            pr_num=$(timeout 10 gh api "repos/${repo_full}/commits/${commit_sha}/pulls" --jq '.[0].number // empty' 2>/dev/null)
        fi
    fi

    if [ -z "$pr_num" ]; then
        drop_event "$event_file" "no PR number could be derived"
        return
    fi

    # Look up the owner.
    local owner_json
    owner_json=$(lookup_owner "$REPO" "$pr_num")
    if [ -z "$owner_json" ]; then
        drop_event "$event_file" "no owner registered for PR #$pr_num"
        return
    fi

    local owner_pid owner_fifo
    owner_pid=$(echo "$owner_json" | jq -r '.pid // 0')
    owner_fifo=$(echo "$owner_json" | jq -r '.fifo // empty')

    if [ -z "$owner_fifo" ] || [ "$owner_pid" = "0" ]; then
        drop_event "$event_file" "owner record for PR #$pr_num is malformed"
        rm -f "$PR_OWNERS_DIR/${REPO}-${pr_num}.json"
        return
    fi

    # Drop on dead owner.
    if ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f "$PR_OWNERS_DIR/${REPO}-${pr_num}.json"
        drop_event "$event_file" "owner PID $owner_pid for PR #$pr_num is dead"
        return
    fi

    # Owner alive — try synchronous FIFO write with ack timeout.
    if [ ! -p "$owner_fifo" ]; then
        # Owner PID is alive but FIFO disappeared (e.g. hook just respawning).
        # Wait briefly and re-check; the asyncRewake spawn cycle is short.
        local i=0
        while [ "$i" -lt 10 ] && [ ! -p "$owner_fifo" ]; do
            sleep 0.2
            i=$((i + 1))
        done
        if [ ! -p "$owner_fifo" ]; then
            drop_event "$event_file" "owner FIFO $owner_fifo not found after wait"
            return
        fi
    fi

    if write_with_ack "$owner_fifo" "$event_data"; then
        rm -f "$event_file"
        echo "[wake-claude] DELIVERED ${event_file##*/} → PID $owner_pid (PR #$pr_num)" >&2
    else
        drop_event "$event_file" "FIFO write to PID $owner_pid timed out after ${FIFO_WRITE_TIMEOUT}s"
    fi
}

# Process every event file matching this repo. Each file is processed
# independently; one failure does not affect the others.
for ef in "$EVENTS_DIR"/${REPO}*.json; do
    [ -f "$ef" ] || continue
    process_event_file "$ef"
done
