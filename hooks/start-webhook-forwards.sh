#!/bin/bash
# Starts gh webhook forward for repositories with active Claude Code sessions.
# Dynamically discovers repos — no hardcoded list.
# Webhook receiver listens on port 9877 for all of them.
#
# On startup: scan running Claude processes, derive repo names from their cwds.
# This is both universal (works for any repo) and efficient (only active repos).
# When a new Claude session opens a new repo, restart this service to pick it up.

discover_active_repos() {
    local repos=()
    local seen=()
    for pid in $(pgrep -x claude 2>/dev/null); do
        local cwd
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
        local remote
        remote=$(git -C "$cwd" remote get-url origin 2>/dev/null) || continue
        local repo
        repo=$(echo "$remote" | sed 's|.*github.com[:/]||;s|\.git$||')
        [ -z "$repo" ] && continue
        # Dedup
        local already=0
        for s in "${seen[@]:-}"; do [ "$s" = "$repo" ] && already=1 && break; done
        [ "$already" = "1" ] && continue
        seen+=("$repo")
        repos+=("$repo")
    done
    printf '%s\n' "${repos[@]}"
}

echo "[webhook-forwards] Discovering repos from active Claude Code sessions..." >&2
REPOS=()
while IFS= read -r repo; do
    [ -n "$repo" ] && REPOS+=("$repo")
done < <(discover_active_repos)

if [ "${#REPOS[@]}" -eq 0 ]; then
    echo "[webhook-forwards] No active Claude sessions found. Waiting 60s and retrying..." >&2
    sleep 60
    while IFS= read -r repo; do
        [ -n "$repo" ] && REPOS+=("$repo")
    done < <(discover_active_repos)
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
    echo "[webhook-forwards] Still no active sessions. Exiting (systemd will restart)." >&2
    exit 1
fi

echo "[webhook-forwards] Forwarding ${#REPOS[@]} repos: ${REPOS[*]}" >&2

# Clean up zombie webhook-forwarder hooks
for REPO in "${REPOS[@]}"; do
    HOOK_IDS=$(gh api "repos/$REPO/hooks" --jq '.[] | select(.config.url == "https://webhook-forwarder.github.com/hook") | .id' 2>/dev/null)
    for HOOK_ID in $HOOK_IDS; do
        gh api -X DELETE "repos/$REPO/hooks/$HOOK_ID" 2>/dev/null
        echo "[webhook-forwards] Cleaned up zombie hook $HOOK_ID from $REPO" >&2
    done
done

# Start webhook receiver
if [ -z "$HOME" ]; then
    echo "[webhook-forwards] HOME is not set" >&2
    exit 1
fi

RECEIVER_PATH="$HOME/.claude/hooks/webhook-receiver.py"
if [ ! -f "$RECEIVER_PATH" ] || [ ! -r "$RECEIVER_PATH" ]; then
    echo "[webhook-forwards] Receiver not found: $RECEIVER_PATH" >&2
    exit 1
fi

python3 "$RECEIVER_PATH" 9877 &
RECEIVER_PID=$!
sleep 1
echo "[webhook-forwards] Receiver started (PID $RECEIVER_PID)" >&2

# Start gh webhook forward for each repo
PIDS=()
for REPO in "${REPOS[@]}"; do
    gh webhook forward \
        --repo="$REPO" \
        --events=pull_request_review,check_suite \
        --url=http://localhost:9877 &
    PIDS+=($!)
    echo "[webhook-forwards] Started forward for $REPO (PID ${PIDS[-1]})" >&2
    sleep 1
done

echo "[webhook-forwards] All ${#REPOS[@]} forwards running. Waiting..." >&2

wait -n
EXIT_CODE=$?
echo "[webhook-forwards] A process exited ($EXIT_CODE), stopping all..." >&2

kill $RECEIVER_PID "${PIDS[@]}" 2>/dev/null
exit $EXIT_CODE
