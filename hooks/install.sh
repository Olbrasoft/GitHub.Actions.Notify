#!/bin/bash
# Install (or update) the FIFO push wake hooks into ~/.claude/hooks/.
#
# Usage:
#   ./hooks/install.sh           # install with prompts
#   ./hooks/install.sh --force   # install without prompts (overwrite)
#   ./hooks/install.sh --check   # report drift without installing
#
# What this installs:
#   - wake-on-event.sh           : asyncRewake hook (per-session FIFO consumer)
#   - wake-claude.sh             : producer-side FIFO writer with ack semantics
#   - webhook-receiver.py        : HTTP listener for `gh webhook forward` (port 9877)
#   - check-deploy-status.sh     : UserPromptSubmit fallback reader
#   - start-webhook-forwards.sh  : systemd service entrypoint (forwards + receiver)
#
# Configuration NOT touched by this script (you must do it manually once):
#   - ~/.claude/settings.json    : register wake-on-event.sh as asyncRewake hook
#   - systemd user unit          : enable gh-webhook-forward.service

set -euo pipefail

REPO_HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.claude/hooks"
HOOKS=(
    wake-on-event.sh
    wake-claude.sh
    webhook-receiver.py
    start-webhook-forwards.sh
    register-pr-owner.sh
    auto-register-pr-from-tool-output.sh
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
            diff -u "$dst" "$src" 2>/dev/null | head -20 >&2 || true
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
        echo ""
        echo "[install] DRIFT DETECTED: $drift_count file(s) differ from repo. Run without --check to install." >&2
        exit 1
    fi
    echo ""
    echo "[install] No drift. All hooks match repo."
    exit 0
fi

echo ""
echo "[install] Summary: $install_count installed, $skip_count skipped"

# Sanity-check Claude Code hook configuration. Two hooks need to be wired:
#
#   1. wake-on-event.sh — asyncRewake on SessionStart and Stop. Provides
#      the per-session FIFO and the wake mechanism.
#   2. auto-register-pr-from-tool-output.sh — PostToolUse hook (matcher:
#      "Bash"). Auto-registers PR ownership when `gh pr create` is run,
#      so future events for that PR can be routed back to this session.
#
# The script does not modify settings.json directly (too risky); instead it
# reports what is missing and prints a copy-paste-ready snippet.
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    missing=()
    grep -q "wake-on-event.sh" "$SETTINGS" || missing+=("wake-on-event.sh")
    grep -q "auto-register-pr-from-tool-output.sh" "$SETTINGS" || missing+=("auto-register-pr-from-tool-output.sh")

    if [ "${#missing[@]}" -eq 0 ]; then
        echo "[install] OK: wake-on-event.sh and auto-register-pr-from-tool-output.sh are both referenced in $SETTINGS"
    else
        cat <<EOF >&2

WARNING: $SETTINGS is missing one or more hook references:
${missing[*]}

Add the following fragments to the "hooks" section (merge with any
existing entries):

  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$INSTALL_DIR/wake-on-event.sh",
            "asyncRewake": true
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$INSTALL_DIR/wake-on-event.sh",
            "asyncRewake": true
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$INSTALL_DIR/auto-register-pr-from-tool-output.sh"
          }
        ]
      }
    ]
  }

EOF
    fi
else
    echo "[install] NOTE: $SETTINGS does not exist yet. Create it and register the hooks above." >&2
fi

# Sanity-check webhook forward systemd service (optional, only if user wants
# code review notifications)
if systemctl --user list-unit-files gh-webhook-forward.service >/dev/null 2>&1; then
    if systemctl --user is-active gh-webhook-forward.service >/dev/null 2>&1; then
        echo "[install] OK: gh-webhook-forward.service is active"
    else
        echo "[install] WARNING: gh-webhook-forward.service is installed but not active. Run: systemctl --user start gh-webhook-forward.service" >&2
    fi
else
    echo "[install] NOTE: gh-webhook-forward.service is not installed. Code review push wake will not work without it." >&2
    echo "[install]       See docs/integration-guide.md for systemd unit setup." >&2
fi
