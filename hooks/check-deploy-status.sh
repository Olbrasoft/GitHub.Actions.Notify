#!/bin/bash
# Hook script for UserPromptSubmit: checks for pending CI/CD event notifications.
# GitHub Actions writes events to ~/.config/claude-channels/deploy-events/
# This script reads them, outputs to stdout (injected into Claude Code context),
# and deletes the file so it's only shown once.

EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"

# Check if directory exists
if [ ! -d "$EVENTS_DIR" ]; then
  exit 0
fi

# Detect current repository to filter events
REPO_PREFIX=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' | tr '/' '-')

# If we cannot determine the current repository, do not process any events.
# An empty prefix would broaden the glob to ALL event files in the directory
# and we would delete notifications for other repos. Bail silently — the
# next prompt from inside a real repo will pick them up.
if [ -z "$REPO_PREFIX" ]; then
  exit 0
fi

# Process only events for current repository
for event_file in "$EVENTS_DIR"/${REPO_PREFIX}*.json; do
  [ -f "$event_file" ] || continue

  EVENT=$(cat "$event_file" 2>/dev/null)
  # Delete immediately after reading to prevent Stop hook re-detection
  rm -f "$event_file"
  if [ -z "$EVENT" ]; then
    continue
  fi

  EVENT_TYPE=$(echo "$EVENT" | jq -r '.event // "unknown"')
  STATUS=$(echo "$EVENT" | jq -r '.status // "unknown"')
  REPO=$(echo "$EVENT" | jq -r '.repository // "unknown"')

  case "$EVENT_TYPE" in
    deploy-complete)
      COMMIT_MSG=$(echo "$EVENT" | jq -r '.commitMessage // "unknown"')
      COMMIT_SHA=$(echo "$EVENT" | jq -r '.commit // "unknown"')
      RUN_URL=$(echo "$EVENT" | jq -r '.runUrl // ""')
      ENVIRONMENT=$(echo "$EVENT" | jq -r '.environment // "production"')
      FAILED_STEP=$(echo "$EVENT" | jq -r '.failedStep // ""')

      echo "<deploy-complete repository=\"$REPO\" status=\"$STATUS\" commit=\"$COMMIT_SHA\" environment=\"$ENVIRONMENT\" failedStep=\"$FAILED_STEP\">"
      echo "Deploy $STATUS for $REPO: $COMMIT_MSG ($COMMIT_SHA)"
      [ -n "$RUN_URL" ] && echo "Run: $RUN_URL"
      if [ "$STATUS" = "success" ]; then
        echo "ACTION REQUIRED: Verify the deployment is running correctly (systemctl status, health check, logs), then notify the user via mcp__notify__notify."
      else
        [ -n "$FAILED_STEP" ] && echo "FAILED STEP: $FAILED_STEP"
        echo "ACTION REQUIRED: Deploy FAILED! Read the failed CI logs: gh run view <RUN_ID> --repo $REPO --log-failed 2>&1 | tail -80. Analyze the error, fix the code, commit and push. Notify the user via mcp__notify__notify with details about what failed and what you're fixing."
      fi
      echo "</deploy-complete>"
      ;;

    code-review-complete)
      PR_NUM=$(echo "$EVENT" | jq -r '.prNumber // "unknown"')
      PR_TITLE=$(echo "$EVENT" | jq -r '.prTitle // "unknown"')
      PR_URL=$(echo "$EVENT" | jq -r '.prUrl // ""')
      REVIEWER=$(echo "$EVENT" | jq -r '.reviewer // "unknown"')
      COMMENT_COUNT=$(echo "$EVENT" | jq -r '.reviewComments // 0')

      echo "<code-review-complete repository=\"$REPO\" pr=\"$PR_NUM\" reviewer=\"$REVIEWER\" comments=\"$COMMENT_COUNT\" status=\"$STATUS\">"
      echo "Code review completed for $REPO PR #$PR_NUM: $PR_TITLE"
      echo "Reviewer: $REVIEWER, State: $STATUS, Comments: $COMMENT_COUNT"
      [ -n "$PR_URL" ] && echo "PR: $PR_URL"
      echo "ACTION REQUIRED: Read ALL review comments using 'gh api repos/$REPO/pulls/$PR_NUM/comments --jq .[].body' and 'gh api repos/$REPO/pulls/$PR_NUM/reviews --jq .[].body'. Fix ALL issues mentioned. Push fixes. Notify user via mcp__notify__notify."
      echo "</code-review-complete>"
      ;;

    ci-complete)
      PR_NUM=$(echo "$EVENT" | jq -r '.prNumber // "unknown"')
      PR_BRANCH=$(echo "$EVENT" | jq -r '.branch // "unknown"')

      echo "<ci-complete repository=\"$REPO\" pr=\"$PR_NUM\" status=\"$STATUS\" branch=\"$PR_BRANCH\">"
      if [ "$STATUS" = "success" ]; then
        echo "All CI checks passed for $REPO PR #$PR_NUM (branch: $PR_BRANCH)"
        echo "ACTION REQUIRED: Check if Copilot review is done. If so, merge the PR. If review has comments, fix them first."
      else
        echo "CI FAILED for $REPO PR #$PR_NUM (branch: $PR_BRANCH)"
        echo "ACTION REQUIRED: Read failed CI logs and fix. Notify user via mcp__notify__notify."
      fi
      echo "</ci-complete>"
      ;;

    verify-complete)
      COMMIT_SHA=$(echo "$EVENT" | jq -r '.commit // "unknown"')
      ENVIRONMENT=$(echo "$EVENT" | jq -r '.environment // "production"')

      echo "<verify-complete repository=\"$REPO\" status=\"$STATUS\" environment=\"$ENVIRONMENT\">"
      if [ "$STATUS" = "success" ]; then
        echo "Production verification PASSED for $REPO"
        echo "ACTION REQUIRED: Notify user via mcp__notify__notify that production verification passed. Close the issue if all checks pass."
      else
        echo "Production verification FAILED for $REPO"
        echo "ACTION REQUIRED: Notify user via mcp__notify__notify about verification failure. Analyze what went wrong and fix it."
      fi
      echo "</verify-complete>"
      ;;

    *)
      echo "<ci-event repository=\"$REPO\" event=\"$EVENT_TYPE\" status=\"$STATUS\">"
      echo "Unknown CI event: $EVENT_TYPE ($STATUS) for $REPO"
      echo "ACTION REQUIRED: Check what happened and notify user via mcp__notify__notify."
      echo "</ci-event>"
      ;;
  esac
done

###############################################################################
# Surface recent wake feedback log entries (issue #40)
###############################################################################
#
# Show the most recent N entries from ~/.config/claude-channels/wake-feedback.md
# so the current session has context about prior wake mechanism quirks observed
# by other sessions. Bounded by entry count to avoid blowing up Claude's
# context window with months of history.
WAKE_FEEDBACK_LOG="$HOME/.config/claude-channels/wake-feedback.md"
WAKE_FEEDBACK_MAX_ENTRIES="${WAKE_FEEDBACK_MAX_ENTRIES:-5}"

if [ -f "$WAKE_FEEDBACK_LOG" ]; then
    # Each entry is a level-2 markdown header `## <timestamp> — <event>`
    # followed by bullets and a `---` separator. We grab the last N
    # entries by accumulating into an array and printing the tail.
    recent_entries=$(awk -v max="$WAKE_FEEDBACK_MAX_ENTRIES" '
        BEGIN { count = 0; entry = "" }
        /^## / { in_entry = 1 }
        in_entry { entry = entry $0 "\n" }
        /^---$/ && in_entry {
            entries[++count] = entry
            entry = ""
            in_entry = 0
        }
        END {
            start = count - max + 1
            if (start < 1) start = 1
            for (i = start; i <= count; i++) printf "%s", entries[i]
        }
    ' "$WAKE_FEEDBACK_LOG")

    if [ -n "$recent_entries" ]; then
        echo "<wake-feedback-log path=\"$WAKE_FEEDBACK_LOG\" recent=\"$WAKE_FEEDBACK_MAX_ENTRIES\">"
        echo "Recent wake mechanism feedback entries from this and other Claude sessions."
        echo "Read these to spot patterns (late deliveries, stale events, garbled JSON, ...)."
        echo "If something here is relevant to current work, mention it. Otherwise treat as background context."
        echo ""
        echo "$recent_entries"
        echo "</wake-feedback-log>"
    fi
fi
