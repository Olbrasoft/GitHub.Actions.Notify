#!/bin/bash
# Starts gh webhook forward for all registered Olbrasoft repositories.
# Each forward runs as a background process.
# Webhook receiver listens on port 9877 for all of them.

REPOS=(
  "Olbrasoft/VirtualAssistant"
  "Olbrasoft/cr"
  "Olbrasoft/HandbookSearch"
  "Olbrasoft/GitHub.Actions.Notify"
  "Olbrasoft/Blog"
)

# Clean up zombie webhook-forwarder hooks left by previous crashes of this
# service. KNOWN LIMITATION: this scope is "all hooks pointing at the gh
# webhook-forwarder URL", which means a second concurrently running
# `gh webhook forward` (e.g. another developer's machine sharing the same
# repo, or a manually started one) would have its hooks deleted too.
# In practice this is acceptable because gh webhook forward is a
# per-developer service running once per machine; running it twice for the
# same repo on the same machine is the failure mode this cleanup recovers
# from. If we ever need cross-instance safety, track our hook IDs in a
# state file under $XDG_RUNTIME_DIR and delete only those.
for REPO in "${REPOS[@]}"; do
  HOOK_IDS=$(gh api "repos/$REPO/hooks" --jq '.[] | select(.config.url == "https://webhook-forwarder.github.com/hook") | .id' 2>/dev/null)
  for HOOK_ID in $HOOK_IDS; do
    gh api -X DELETE "repos/$REPO/hooks/$HOOK_ID" 2>/dev/null
    echo "[webhook-forwards] Cleaned up zombie hook $HOOK_ID from $REPO" >&2
  done
done

# Start webhook receiver. Resolve the path via $HOME so this works for any
# user/machine after `./hooks/install.sh` has run. Validate the file exists
# and is readable before launching to fail fast with a clear error.
if [ -z "$HOME" ]; then
  echo "[webhook-forwards] HOME is not set; cannot resolve webhook receiver path" >&2
  exit 1
fi

RECEIVER_PATH="$HOME/.claude/hooks/webhook-receiver.py"
if [ ! -f "$RECEIVER_PATH" ] || [ ! -r "$RECEIVER_PATH" ]; then
  echo "[webhook-forwards] Receiver script not found or not readable: $RECEIVER_PATH" >&2
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

echo "[webhook-forwards] All forwards running. Waiting..." >&2

# Wait for any process to exit, then restart all
wait -n
EXIT_CODE=$?
echo "[webhook-forwards] A process exited ($EXIT_CODE), stopping all..." >&2

kill $RECEIVER_PID "${PIDS[@]}" 2>/dev/null
exit $EXIT_CODE
