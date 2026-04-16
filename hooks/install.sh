#!/bin/bash
# Install (or update) hooks and channel server into ~/.claude/hooks/.
#
# Usage:
#   ./hooks/install.sh           # install with prompts
#   ./hooks/install.sh --force   # install without prompts (overwrite)
#   ./hooks/install.sh --check   # report drift without installing
#
# What this installs:
#   - webhook-receiver.py        : HTTP listener for `gh webhook forward` (port 9877)
#                                  Receives GitHub webhooks, writes event files to disk
#   - start-webhook-forwards.sh  : systemd service entrypoint — auto-discovers repos
#                                  from active Claude sessions, no hardcoded list
#   - log-wake-feedback.sh       : helper for logging wake event classification
#   - get-session-id.sh          : helper for PR body session markers
#
# Event delivery is handled by channel/webhook.ts (MCP channel server),
# NOT by asyncRewake hooks. Start Claude Code with:
#   claude --dangerously-load-development-channels server:github-webhook

set -euo pipefail

REPO_HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.claude/hooks"
HOOKS=(
    log-wake-feedback.sh
    get-session-id.sh
    webhook-receiver.py
    start-webhook-forwards.sh
)

MODE="install"
case "${1:-}" in
    --force)  MODE="force" ;;
    --check)  MODE="check" ;;
    "" )      MODE="install" ;;
    *) echo "Usage: $0 [--force|--check]" >&2; exit 1 ;;
esac

mkdir -p "$INSTALL_DIR"

drift_count=0
install_count=0
skip_count=0

for hook in "${HOOKS[@]}"; do
    src="$REPO_HOOKS_DIR/$hook"
    dst="$INSTALL_DIR/$hook"

    if [ ! -f "$src" ]; then
        echo "[install] MISSING in repo: $hook" >&2
        continue
    fi

    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "[install] up-to-date: $hook"
        continue
    fi

    if [ "$MODE" = "check" ]; then
        if [ -f "$dst" ]; then
            echo "[install] DRIFT: $hook (live differs from repo)" >&2
        else
            echo "[install] MISSING in install dir: $hook" >&2
        fi
        drift_count=$((drift_count + 1))
        continue
    fi

    if [ "$MODE" = "install" ] && [ -f "$dst" ]; then
        printf "[install] %s exists and differs. Overwrite? [y/N] " "$hook"
        read -r answer
        case "$answer" in
            y|Y|yes) ;;
            *) echo "[install] skipped: $hook"; skip_count=$((skip_count + 1)); continue ;;
        esac
    fi

    install -m 755 "$src" "$dst"
    echo "[install] installed: $hook"
    install_count=$((install_count + 1))
done

if [ "$MODE" = "check" ]; then
    if [ "$drift_count" -gt 0 ]; then
        echo "[install] DRIFT DETECTED: $drift_count file(s) differ from repo." >&2
        exit 1
    fi
    echo "[install] No drift. All hooks match repo."
    exit 0
fi

echo "[install] Summary: $install_count installed, $skip_count skipped"

# Check MCP channel server registration
CLAUDE_JSON="$HOME/.claude.json"
if [ -f "$CLAUDE_JSON" ]; then
    if grep -q "github-webhook" "$CLAUDE_JSON"; then
        echo "[install] OK: github-webhook channel registered in $CLAUDE_JSON"
    else
        cat <<EOF >&2

NOTE: github-webhook channel not found in $CLAUDE_JSON.
Add to mcpServers:

  "github-webhook": {
    "type": "stdio",
    "command": "bun",
    "args": ["$(cd "$REPO_HOOKS_DIR/.." && pwd)/channel/webhook.ts"]
  }

Then start with: claude --dangerously-load-development-channels server:github-webhook
EOF
    fi
fi

# Check webhook forward service
if systemctl --user is-active gh-webhook-forward.service >/dev/null 2>&1; then
    echo "[install] OK: gh-webhook-forward.service is active"
else
    echo "[install] WARNING: gh-webhook-forward.service not active" >&2
fi
