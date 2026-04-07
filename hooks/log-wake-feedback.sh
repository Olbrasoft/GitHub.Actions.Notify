#!/bin/bash
# log-wake-feedback.sh — append a structured entry to the wake feedback log.
#
# Called by Claude Code sessions after processing a wake event, to record
# whether the event was timely, contradictory with current state, garbled,
# etc. Future sessions surface this log on SessionStart so they have
# context about prior issues without the original session being alive to
# tell them. See issue #40.
#
# Usage:
#   log-wake-feedback.sh \
#     event=code-review-complete \
#     repo=Olbrasoft/VirtualAssistant \
#     pr=939 \
#     classification=stale \
#     note="Event arrived after PR was already merged; skipped."
#
# Required keys:
#   event           — event type (code-review-complete, deploy-complete, ci-complete, …)
#   repo            — owner/repo
#   classification  — one of: ok | late | stale | garbled | wrong-target | other
#
# Optional keys:
#   pr              — PR number (if applicable)
#   commit          — commit SHA (if applicable)
#   delay           — observed delay (e.g. "7 minutes")
#   note            — free-form one-line description (quote if it has spaces)

set -u

LOG_DIR="$HOME/.config/claude-channels"
LOG_FILE="$LOG_DIR/wake-feedback.md"

mkdir -p "$LOG_DIR"

# Parse key=value arguments into variables.
event=""
repo=""
pr=""
commit=""
classification=""
delay=""
note=""

for arg in "$@"; do
    case "$arg" in
        event=*)          event="${arg#event=}" ;;
        repo=*)           repo="${arg#repo=}" ;;
        pr=*)             pr="${arg#pr=}" ;;
        commit=*)         commit="${arg#commit=}" ;;
        classification=*) classification="${arg#classification=}" ;;
        delay=*)          delay="${arg#delay=}" ;;
        note=*)           note="${arg#note=}" ;;
        *)
            echo "[log-wake-feedback] unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

if [ -z "$event" ] || [ -z "$repo" ] || [ -z "$classification" ]; then
    echo "[log-wake-feedback] usage: $0 event=... repo=owner/repo classification=ok|late|stale|garbled|wrong-target|other [pr=N] [commit=sha] [delay=...] [note=\"...\"]" >&2
    exit 1
fi

case "$classification" in
    ok|late|stale|garbled|wrong-target|other) ;;
    *)
        echo "[log-wake-feedback] invalid classification '$classification' (expected: ok|late|stale|garbled|wrong-target|other)" >&2
        exit 1
        ;;
esac

# Resolve current Claude session UUID via the existing helper. The script
# walks up from this hook's PID, so we need to be invoked from inside a
# Claude tool call (which is the only intended caller anyway).
session_uuid=""
if [ -x "$HOME/.claude/hooks/get-session-id.sh" ]; then
    session_uuid=$("$HOME/.claude/hooks/get-session-id.sh" 2>/dev/null || true)
fi
[ -z "$session_uuid" ] && session_uuid="unknown"

timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build entry first into a tmp string, then append under flock so two
# concurrent appends never interleave. flock on the log file itself
# (non-blocking would risk losing entries; blocking with a short timeout
# is the right trade-off).
entry=$(cat <<MARKDOWN
## $timestamp — $event on $repo${pr:+ PR #$pr}
- **session**: $session_uuid
- **classification**: $classification
${delay:+- **delay**: $delay
}${commit:+- **commit**: $commit
}${note:+- **note**: $note
}
---
MARKDOWN
)

# Auto-create the file with a header on first use.
if [ ! -e "$LOG_FILE" ]; then
    cat > "$LOG_FILE" <<'HEADER'
# Wake Mechanism Feedback Log

This file collects post-hoc evaluations of wake events from Claude Code sessions.
Each entry is appended by `log-wake-feedback.sh` after a session processes a
wake event. New sessions read recent entries on startup so they have context
about prior wake mechanism quirks (late delivery, stale state, garbled JSON,
etc.) without the original session being alive to tell them.

Format: each entry is a level-2 header with the UTC timestamp and event type,
followed by key-value bullets. Entries are separated by `---` rules.

See https://github.com/Olbrasoft/GitHub.Actions.Notify/issues/40 for the
design rationale.

---

HEADER
fi

# Append the entry under an exclusive file lock.
(
    flock -x -w 5 9 || {
        echo "[log-wake-feedback] failed to acquire lock on $LOG_FILE within 5s" >&2
        exit 1
    }
    printf '%s\n' "$entry" >> "$LOG_FILE"
) 9>>"$LOG_FILE"

echo "[log-wake-feedback] logged: $event $repo${pr:+ PR #$pr} → $classification" >&2
