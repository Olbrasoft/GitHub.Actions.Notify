# Wake Notification System — How It Actually Works

**Audience:** future Claude Code sessions debugging "why didn't the wake event arrive" or "why did six wake events arrive."

**Status:** authoritative as of 2026-04-15 after PRs #47–#51. Update this file whenever you change wake behavior — if you don't, the next session will repeat the same debug cycle from scratch.

---

## Contract

GitHub event happens → wake-claude.sh delivers → the matching Claude Code session is woken **once**, with the event injected as a system reminder.

When the contract holds, the user sees the wake immediately. When it doesn't, the failure is **always one of the modes below** — start from the mode list, not from guesswork.

---

## Architecture in one diagram

```
GitHub
  │
  ├── webhook (pull_request_review, check_suite)
  │     │
  │     └─► gh webhook forward (per-repo) ─► localhost:9877
  │           │
  │           └─► webhook-receiver.py (systemd: gh-webhook-forward.service)
  │                 │
  │                 ├─► writes event JSON to ~/.config/claude-channels/deploy-events/
  │                 └─► spawns wake-claude.sh <REPO>
  │
  └── self-hosted runner (deploy / verify workflow steps)
        │
        ├─► writes event JSON to ~/.config/claude-channels/deploy-events/
        └─► spawns wake-claude.sh <REPO>
                │
                ├─► sweep_stale_session_files (FIFOs, manifests, locks of dead PIDs)
                ├─► sweep_stale_event_files (drop files older than MAX_EVENT_AGE_SECS=3600s)
                ├─► dedup events by (event_type, commit, environment)
                └─► for each surviving event:
                      ├─► extract pr_num (direct or via gh api commits/SHA/pulls)
                      ├─► merged-PR guard (ONLY for ci-complete & code-review-complete)
                      ├─► resolve target Claude PID (PR body marker → cwd basename)
                      ├─► kill orphan readers on the FIFO
                      └─► write_with_retry → /tmp/claude-wake/.session-<PID>.fifo
                            │
                            ├─► success → DELIVERED, rm event file
                            └─► timeout → DEFER (file kept), clean stale reader.lock
                                  │
                                  └─► next reader on next Stop / next user prompt
                                        will pick it up via UserPromptSubmit drain
                                        (check-deploy-status.sh)
```

---

## The 6 components and what they own

| File | Role | Lifecycle |
|---|---|---|
| `webhook-receiver.py` | HTTP listener on :9877. Parses GitHub webhooks. Writes event files. Spawns wake-claude.sh. | Long-running systemd service |
| `wake-claude.sh` | One-shot delivery transaction. Finds target session, writes to FIFO. | Spawned per event, exits when done |
| `wake-on-event.sh` | asyncRewake hook in each Claude session. Blocks on FIFO. On read → exit 2 → injection. | Spawned by Claude Code on SessionStart and Stop |
| `check-deploy-status.sh` | UserPromptSubmit hook. Drains pending event files on disk. Cleans stale reader.lock. | Runs on every user prompt |
| `log-wake-feedback.sh` | Records session's classification (ok/late/stale/garbled/...) of received events to wake-feedback.md | Called explicitly from session after acting on a wake |
| `start-webhook-forwards.sh` | systemd service entrypoint. Runs `gh webhook forward` for each configured repo + the receiver. | Long-running |

---

## Event types and when they arrive

| Event | Source | Pre/Post-merge | Stale-PR guard applies? |
|---|---|---|---|
| `code-review-complete` | webhook (pull_request_review) | pre-merge | YES — drop if PR merged |
| `ci-complete` | webhook (check_suite) | pre-merge | YES — drop if PR merged |
| `deploy-complete` | runner workflow step | post-merge | NO — merged PR is normal |
| `verify-complete` | runner workflow step | post-merge | NO — merged PR is normal |

**If you're a session waiting for a deploy on a repo that has NO deploy workflow, no event will ever come — that's not a bug.** Repo inventory:

| Repo | Deploy event? | Verify event? |
|---|---|---|
| Olbrasoft/VirtualAssistant | YES | YES |
| Olbrasoft/cr | NO | NO |
| Olbrasoft/HandbookSearch | check workflow | check workflow |
| Olbrasoft/GitHub.Actions.Notify | NO (it's hooks/actions) | NO |
| Olbrasoft/Blog | check workflow | check workflow |

When in doubt, `gh run list --repo <REPO> --workflow <name>` to see what runs after merge.

---

## Where to look when "nothing came" or "too many came"

The answer is **always** in the journal first. Don't guess.

```bash
# Last 30 minutes of webhook + wake-claude activity
journalctl --user -u gh-webhook-forward.service --since "30 min ago" --no-pager | grep -E "webhook-receiver|wake-claude"
```

You'll see one of these patterns:

### Pattern A — event was DROPPED on purpose (good outcome)

```
[webhook-receiver] SKIP review for Olbrasoft/cr PR #429 (Copilot): PR is already merged — not waking
[webhook-receiver] SKIP check_suite for Olbrasoft/cr PR #431 (ef0ba98): PR is already merged — not waking
[wake-claude] DROP <file> — PR #429 is already MERGED (stale at delivery, not waking)
[wake-claude] DROP stale-on-disk (age=4321s > MAX_EVENT_AGE_SECS=3600s): <file>
```

These are the **stale-suppression** lines. If you see them, the event was real but obsolete; the session does NOT wake. This is correct.

### Pattern B — event was DEFER'd (no reader available)

```
[wake-claude] DEFER <file> → PID <X> (PR=Y) — file kept for UserPromptSubmit fallback
[wake-claude] Cleaning stale reader.lock for PID <X> (held by dead <Y>)
```

The file stays on disk. The next user prompt in the matching session will trigger `check-deploy-status.sh`, which drains the file and injects it. **If the user never prompts, the file sits until age ≥ 1h, then GC drops it.**

### Pattern C — event was DELIVERED

```
[wake-claude] DELIVERED <file> → PID <X> (PR=Y)
```

The session received it. If the user says "nothing arrived" anyway, the session itself either suppressed the message or the user is looking at the wrong terminal.

### Pattern D — no log lines at all for the expected wake

The event was never produced. Two sub-cases:

1. **Webhook event** (review/CI) — receiver didn't receive it. Check `gh webhook forward` is running for that repo. `gh webhook list --repo <REPO>` should show an entry for `webhook-forwarder.github.com/hook`. If missing, register it.
2. **Runner event** (deploy/verify) — workflow didn't execute the `Notify Claude Code` step. Check `gh run view <ID> --log` for that step. If absent, the workflow is missing the notification block.

---

## Failure modes we've seen and the PRs that fixed them

| Mode | What user saw | Fixed in | Notes |
|---|---|---|---|
| Garbled NDJSON (every-other-byte) | "WAKE EVENT not valid JSON" + invalid-payloads dumps | PR #47 | Multiple wake-on-event.sh readers raced for individual bytes (bash `read -r` is byte-at-a-time). Singleton lock per session enforced via hard-link claim. |
| Stale review event for merged PR | session woken for review on PR it just merged | PR #47 | `_handle_review` skips if `pr.merged` or `pr.state != "open"` |
| Stale CI event for merged PR | session woken for CI on PR it just merged | PR #49 | `_handle_check_suite` skips on same condition |
| Stale event file delivered hours later | "EVENT AGE 61h30m" for ancient PR | PR #47 | `sweep_stale_event_files` drops files older than 1h (configurable) |
| Reader dies, session goes deaf | wake events DEFER forever, user sees nothing | PR #48 | Signal traps + stale-lock cleanup in wake-claude.sh DEFER + check-deploy-status.sh on UserPromptSubmit |
| Stale event delivered after producer was correct | DEFER'd file delivered post-merge as stale wake | PR #49 | Delivery-side merged-PR guard in wake-claude.sh |
| Deploy event dropped because PR is merged | session waited for deploy that was silently dropped | PR #50 | Guard scoped to ci-complete/code-review-complete only |
| wake-claude.sh decisions invisible | journal showed "Wake signal sent" but no result | PR #51 | webhook-receiver inherits stderr instead of DEVNULL |

---

## Known limitations (no current fix)

These are NOT bugs to debug — they're inherent to the design. Don't waste time on them.

### L1 — Reader killed by SIGKILL leaves stale lock until next user interaction

`SIGKILL` (kill -9, OOM, kernel) cannot be trapped. The lock file lingers with a dead PID. Recovery happens on:
- The next `wake-claude.sh` DEFER (cleans the lock, but doesn't deliver — there's no reader)
- The next `UserPromptSubmit` in that session (cleans the lock; the model's response triggers Stop → new reader)

So between SIGKILL and the next user prompt, the session is "deaf" but events accumulate on disk and get drained on prompt.

### L2 — Verify-complete race vs. manual verification

Session merges + verifies manually in 30s. CI's verify job takes 3 min. When the wake arrives, the work is already done — session classifies as `stale`. **Not preventable** at the producer; the verify event is correct, just slower than the human.

### L3 — Post-merge CI on main never triggers a wake

`check_suite` for main-branch runs has empty `pull_requests` → handler skips. By design — a CI run on main isn't about any PR. If you want post-merge CI notifications, that's a separate event type that doesn't exist yet.

### L4 — Copilot reviews each PR exactly once

If a session pushes a fix and waits for a second Copilot review, it'll wait forever. **Workflow rule #7:** after addressing Copilot comments, MERGE DIRECTLY. Don't wait for a second wake. Source: `engineering-handbook/.../continuous-pr-processing-workflow.md`.

### L5 — Sessions can wait for events that don't exist

Common confusion: session is in repo X with no deploy workflow, but expects a `deploy-complete` after merge. There's nothing to send it. Check the table above; if the repo doesn't ship a deploy event, don't wait for one.

---

## The exact diagnostic procedure when "it's not working"

Run these in order. Stop at the first one that returns a useful answer.

```bash
# 1. Is the webhook service alive?
systemctl --user is-active gh-webhook-forward.service

# 2. Did the webhook event reach the receiver?
journalctl --user -u gh-webhook-forward.service --since "10 min ago" --no-pager | grep -E "webhook-receiver|wake-claude"

# 3. Are events stuck on disk?
ls -la ~/.config/claude-channels/deploy-events/

# 4. Is a wake-on-event reader alive for the target session?
ls -la /tmp/claude-wake/.session-*.{fifo,reader.lock}
for f in /tmp/claude-wake/.session-*.reader.lock; do
  pid=$(cat "$f")
  if kill -0 "$pid" 2>/dev/null; then echo "$f: live $pid"; else echo "$f: DEAD $pid (stale)"; fi
done

# 5. What did the session classify recent wakes as?
tail -60 ~/.config/claude-channels/wake-feedback.md

# 6. Was the workflow step (deploy/verify) actually executed?
gh run view <RUN_ID> --repo <REPO> --log | grep -A 5 "Notify Claude Code"
```

---

## The rules for changing this system

1. **Every event-handling change must log.** Producer → stderr → journal. No silent drops, ever. The reason this system kept burning sessions for weeks is that wake-claude.sh was running with `stderr=DEVNULL` and we couldn't see what it did.
2. **Test the event_type dimension explicitly.** PR #49 dropped deploy events because we only tested merged-vs-open, not deploy-vs-ci. Any new guard MUST be tested against ALL four event types.
3. **Producer-side and delivery-side are different problems.** Producer guards run when the event is created; delivery guards run when wake-claude.sh picks up the file. PR #47 had producer for review only; PR #49 added producer for CI + delivery for both. Track both sides.
4. **Locks must be released on every trappable signal AND continue execution must NOT happen.** PR #48 trapped SIGTERM but forgot the explicit `exit 0`; the script kept reading WITHOUT the lock, breaking singleton. Always: `trap 'cleanup; exit 0' SIGNAL`, never just `trap cleanup SIGNAL`.
5. **TOCTOU is real.** Any "read state, decide, modify" pattern needs re-read-and-compare before modify. PR #48 had this race in 3 places; Copilot caught it on PR #48 review.
6. **Update this file when you change wake behavior.** If you don't, the next session will repeat your investigation from scratch and the user will (rightly) be furious.

---

## Configuration knobs

| Env var | Default | What it does |
|---|---|---|
| `WAKE_CLAUDE_RETRY_SECS` | 60 | How long wake-claude.sh waits for a reader before DEFER |
| `WAKE_CLAUDE_WRITE_TIMEOUT` | 3 | Per-attempt FIFO write timeout |
| `WAKE_CLAUDE_MAX_EVENT_AGE` | 3600 | Drop event files older than this (sec) |
| `WAKE_FEEDBACK_MAX_ENTRIES` | 5 | How many recent feedback entries check-deploy-status.sh surfaces on prompt |

---

## Files at a glance

```
~/.config/claude-channels/
├── deploy-events/                       # Pending event JSON files
├── invalid-payloads/                    # Forensic dumps of garbled wakes (should be empty post-PR-47)
├── wake-feedback.md                     # Session classifications
├── ports.json                           # Port allocation registry
└── .wake-feedback.lock

/tmp/claude-wake/
├── .session-<PID>.fifo                  # Per-session named pipe
├── .session-<PID>.json                  # Manifest (cwd, created)
└── .session-<PID>.reader.lock           # Singleton claim by wake-on-event.sh

~/.claude/hooks/
├── wake-claude.sh                       # Producer-side delivery
├── wake-on-event.sh                     # asyncRewake reader (one per session)
├── check-deploy-status.sh               # UserPromptSubmit drain + lock cleanup
├── log-wake-feedback.sh                 # Feedback logger
├── webhook-receiver.py                  # HTTP listener
└── start-webhook-forwards.sh            # systemd entrypoint
```

The canonical source for all hook files lives in `hooks/` of this repo. `./hooks/install.sh --force` copies them to `~/.claude/hooks/`. The webhook-receiver.py change requires `systemctl --user restart gh-webhook-forward.service` to take effect; the .sh files are read fresh on every spawn.

---

## When this document is wrong

It will be. The next time you fix a wake-system bug, do these three things in the same PR:

1. Update the relevant section above with the new fix.
2. Add the failure mode to the "Failure modes we've seen" table with the PR number.
3. If you added a new event type, configuration knob, or env var, add it to the appropriate table.

This file is the contract between your work today and the next session's debug effort. Keep it honest.
