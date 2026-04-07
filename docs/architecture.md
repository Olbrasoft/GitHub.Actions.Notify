# Architecture

## Use case

A Claude Code session implements a feature end-to-end:

1. Implement code, push branch, run `gh pr create`
2. Wait for CI to finish
3. Wait for Copilot code review (typically 2-5 minutes)
4. Address review comments, merge PR
5. Wait for deploy to finish
6. Verify production
7. Close issue

Between steps 1 and 3 (and 4 and 5) the assistant has nothing to do. Without push wake, the assistant **falls asleep** — Claude Code returns to the prompt and waits for the user. The user comes back hours later expecting a finished feature and finds an open PR with unaddressed review comments.

This project guarantees that **the exact session that created the PR is woken up** when:
- Copilot finishes the code review
- CI completes
- Deploy completes
- Post-deploy verification completes

Wake happens within seconds of the GitHub event, while the session is still alive. The assistant continues the workflow autonomously.

## Hard requirements (per project owner)

| # | Requirement |
|---|---|
| R1 | The session that ran `gh pr create` is the **only** session that receives events for that PR. Other sessions on the same machine, in the same repo, working on different PRs, are not woken. |
| R2 | Each event is delivered **exactly once** to the owner session. |
| R3 | If the owner session is **dead** at the moment the event arrives, the event is **dropped immediately**. No persistence, no replay on the next session start, no fallback to other sessions. The user explicitly chose this: when they reopen Claude Code, they have a new task in mind and do not want stale events from a previous session. |
| R4 | No background polling. No retry loops. Delivery is **event-driven**: GitHub fires → wake-claude.sh delivers → done. |
| R5 | No silent drops because of system bugs. If an event cannot be delivered for any reason except R3, it is logged and the failure is debuggable via stderr. |

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ EVENT PRODUCERS                                                      │
│                                                                      │
│ ┌─────────────────────────┐   ┌──────────────────────────────────┐  │
│ │ GitHub Actions          │   │ gh webhook forward (systemd)     │  │
│ │ (self-hosted runner)    │   │ + webhook-receiver.py (port 9877)│  │
│ │                         │   │                                  │  │
│ │ deploy.yml + verify.yml │   │ Listens for:                     │  │
│ │ write event files       │   │   pull_request_review            │  │
│ │ then call wake-claude.sh│   │   check_suite                    │  │
│ └─────────┬───────────────┘   │ then call wake-claude.sh         │  │
│           │                   └────────┬─────────────────────────┘  │
│           │                            │                            │
│           ▼                            ▼                            │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │ ~/.config/claude-channels/deploy-events/   (event queue)   │    │
│   │   {repo}-deploy-{sha}-{run_id}-{attempt}.json              │    │
│   │   {repo}-verify-{sha}-{run_id}-{attempt}.json              │    │
│   │   {repo}-review-{pr}.json                                  │    │
│   │   {repo}-ci-{pr}.json                                      │    │
│   └────────────────────────────────────────────────────────────┘    │
│                            │                                        │
│                            ▼                                        │
│              ┌──────────────────────────────────────┐               │
│              │ wake-claude.sh                       │               │
│              │  for each event file:                │               │
│              │    derive (repo, pr_number)          │               │
│              │    look up owner from registry       │               │
│              │    if owner alive:                   │               │
│              │      sync FIFO write w/ ack timeout  │               │
│              │      DELETE event file (delivered)   │               │
│              │    if owner dead OR missing:         │               │
│              │      DELETE event file (dropped)     │               │
│              │      DELETE owner registration       │               │
│              └──────────┬───────────────────────────┘               │
└─────────────────────────┼────────────────────────────────────────────┘
                          │ writes through session FIFO (one per session)
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│ EVENT CONSUMER (per Claude Code session)                             │
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────┐     │
│ │ wake-on-event.sh (asyncRewake on SessionStart and Stop)     │     │
│ │                                                             │     │
│ │  1. Walk parent process tree → find Claude PID              │     │
│ │  2. mkfifo /tmp/claude-wake/.session-{PID}.fifo             │     │
│ │  3. Write session manifest to ditto.json                    │     │
│ │  4. cat $FIFO   ← blocks at zero CPU                        │     │
│ │  5. On read: parse event, output instructions to stderr,    │     │
│ │     exit 2 → Claude Code re-prompts assistant with stderr   │     │
│ │     as a system reminder (this IS the "wake")               │     │
│ │  6. On real exit (Claude session dies): cleanup trap        │     │
│ │     removes FIFO, manifest, AND every owner registration    │     │
│ │     pointing at this PID                                    │     │
│ └─────────────────────────────────────────────────────────────┘     │
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────┐     │
│ │ auto-register-pr-from-tool-output.sh (PostToolUse hook)     │     │
│ │                                                             │     │
│ │  Reads JSON on stdin from Claude Code after every Bash      │     │
│ │  tool call. If the output contains a github.com/.../pull/N  │     │
│ │  URL, calls register-pr-owner.sh which writes               │     │
│ │  ~/.config/claude-channels/pr-owners/{repo}-{pr}.json       │     │
│ │  with {pid, fifo, repo, pr, registered_at}.                 │     │
│ │                                                             │     │
│ │  This auto-registration is what binds (repo, pr) to the     │     │
│ │  exact session that ran `gh pr create`. The assistant       │     │
│ │  doesn't have to remember anything.                         │     │
│ └─────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────┘
```

## Owner registry — the routing key

```
~/.config/claude-channels/pr-owners/
├── Olbrasoft-VirtualAssistant-925.json
├── Olbrasoft-GitHub.Actions.Notify-22.json
└── ...
```

Each file:
```json
{
  "pid": 13008,
  "fifo": "/tmp/claude-wake/.session-13008.fifo",
  "repo": "Olbrasoft-VirtualAssistant",
  "pr": 925,
  "url": "https://github.com/Olbrasoft/VirtualAssistant/pull/925",
  "registered_at": "2026-04-07T13:30:00Z"
}
```

The registry is created by `register-pr-owner.sh`, called automatically by the PostToolUse hook when it sees a PR URL in any Bash tool output.

The Notifier (`wake-claude.sh`) reads this file to find the destination FIFO for an event. If the owner PID is dead, the registration is removed and the event is dropped.

## How exactly-once is guaranteed

```
Producer:
  1. Write event to {repo}-deploy-{sha}-{run_id}-{attempt}.json    [atomic create]
  2. Call wake-claude.sh

wake-claude.sh:
  3. Read event JSON
  4. Look up owner from pr-owners/{repo}-{pr}.json
  5. If owner.pid is alive:
       6. Synchronous FIFO write with ack timeout
          ← kernel BLOCKS the write until the consumer reads
          ← write returns success ⇔ consumer has the data in memory
       7. DELETE the event file
       (no retry, no replay — file is gone)
     If owner.pid is dead:
       6'. DELETE the owner record
       7'. DELETE the event file
       (no retry, no replay — file is gone)

Consumer (wake-on-event.sh, blocked on cat $FIFO):
  8. Reads the data (the FIFO write at step 6 unblocks)
  9. Outputs human-readable instructions to stderr
  10. Exits with code 2 → Claude Code re-prompts the assistant
```

The exactly-once guarantee comes from three primitives:

| Step | Kernel guarantee |
|---|---|
| Producer step 1 | Filesystem `O_CREAT|O_EXCL` ensures one event = one file. No producer ever writes two files for the same logical event because the filename includes a globally unique discriminator (commit SHA + run ID + run attempt for deploy/verify; PR number for code review). |
| Notifier step 6 | A FIFO write is synchronous: the kernel blocks the writer until a reader has consumed the data. Write success ⇔ reader has the bytes. |
| Notifier step 7 | `unlink()` is atomic: once the event file is gone, no future Notifier invocation can find it, so no second delivery is possible. |

## What this design does NOT do (and why)

| Behavior | Why we omit it |
|---|---|
| Persistence beyond owner lifetime | Per R3: a dead session means the user has moved on. Stale events would only confuse them when they next open Claude Code. |
| Drain pending events on session start | Same reason. The new session has a new task; old events are noise. |
| Retry loop on the producer side | Per R4: there is no background polling. The producer fires once. If the FIFO write times out (consumer wedged), the event is dropped and logged. In practice the consumer is never wedged because it is just `cat`. |
| TTL / cron purge of old events | Not needed: events are deleted immediately after delivery or drop, so the queue never accumulates. |
| Delivery to multiple sessions in the same repo | Per R1: each PR has exactly one owner. The Notifier delivers to that owner only. Multi-terminal users get correct routing because each terminal owns the PRs it created. |
| Branch-based routing | Replaced by PR-based routing via the owner registry. The branch a PR lives on is irrelevant to delivery. |
| UserPromptSubmit fallback (`check-deploy-status.sh`) | Per R3: would replay stale events on the next session, which the user does not want. The fallback hook has been removed. |

## Components

| File | Role |
|---|---|
| `hooks/wake-on-event.sh` | asyncRewake hook in each Claude session. Creates the per-session FIFO, blocks on read, processes events, exits 2 to wake the assistant. |
| `hooks/wake-claude.sh` | Producer-side Notifier. Looks up PR owner, delivers via FIFO with ack, drops on dead owner. |
| `hooks/register-pr-owner.sh` | Helper that records `(repo, pr) → (pid, fifo)` in the owner registry. |
| `hooks/auto-register-pr-from-tool-output.sh` | PostToolUse hook. Reads tool JSON on stdin, finds PR URLs in Bash output, calls `register-pr-owner.sh` automatically. |
| `hooks/webhook-receiver.py` | HTTP server on port 9877 that receives `pull_request_review` and `check_suite` webhooks from GitHub via `gh webhook forward`, writes event files, calls `wake-claude.sh`. |
| `hooks/start-webhook-forwards.sh` | systemd service entry point that runs `gh webhook forward` for all configured repos plus the webhook receiver. |
| `hooks/install.sh` | One-shot installer. Copies hooks into `~/.claude/hooks/` and verifies the asyncRewake + PostToolUse hook configuration in `~/.claude/settings.json`. |
| `actions/notify` | Composite GitHub Action — POST notification to VirtualAssistant for the TTS channel. |
| `actions/deploy-status` | Wraps `notify` for deploy results. |
| `actions/ci-status` | Wraps `notify` for per-stage CI results. |
| `actions/playwright-verify` | Post-deploy production verification with Playwright. |
| `skills/ci-workflow-monitor` | Claude Code skill: tells the assistant how to react to each event type. |
| `skills/ci-feedback-setup` | One-time per-project setup skill. |

## VirtualAssistant TTS API contract

The TTS notification channel (separate from FIFO push wake) posts to:

```
POST http://localhost:5055/api/notifications
Content-Type: application/json

{
  "text": "Deploy cr na production uspesne dokoncen.",
  "source": "ci-pipeline",
  "issueIds": [166]
}
```

`source: "ci-pipeline"` maps to `AgentType.CiPipeline = 30` in VirtualAssistant. This agent has its own TTS voice profile so CI/CD notifications are distinguishable from Claude Code or Gemini notifications.

## End-to-end happy path

```
T+0   Developer pushes a commit to main
T+0   GitHub fires the deploy workflow on the self-hosted runner
T+30s Deploy step finishes (build, test, publish, restart, health check)
T+30s Notification step writes
      ~/.config/claude-channels/deploy-events/Olbrasoft-VirtualAssistant-deploy-32f4d49-24079371158-1.json
      and calls wake-claude.sh Olbrasoft/VirtualAssistant
T+30s wake-claude.sh:
        - Reads the event
        - Derives PR number from commit SHA via gh API
        - Looks up the owner: PID 13008, FIFO /tmp/claude-wake/.session-13008.fifo
        - kill -0 13008 → ALIVE
        - Synchronous write to the FIFO with 5s ack timeout
        - Returns success → DELETE the event file
T+30s The asyncRewake hook in Claude session 13008 was blocked on the FIFO.
      It receives the event JSON, parses it, outputs:
        "Deploy success for Olbrasoft/VirtualAssistant: Merge pull request #925 (32f4d49)"
        "Verify deployment. Notify user via mcp__notify__notify."
      to stderr, then exits 2.
T+31s Claude Code re-prompts the assistant with the stderr as a system reminder.
T+31s The assistant verifies the deployment, runs Playwright on the changed
      pages, notifies the user, and closes the issue.
```

Total latency from "deploy completes" to "assistant reacts": **~1 second**.

## Owner adoption on session start

When the user closes Claude Code and reopens it in the same project, the new session adopts orphaned owner records that point at the now-dead previous PID. This is a one-shot scan run by `wake-on-event.sh` on every spawn:

```
For each pr-owners/{my_repo}-*.json:
    if owner.pid is alive  → leave alone (live session, exact-once preserved)
    if owner.pid is dead AND PR is OPEN on GitHub:
        rewrite owner record: pid = my_pid, fifo = my_fifo, adopted_at = now
    if owner.pid is dead AND PR is MERGED/CLOSED:
        delete owner record (no longer interesting)
    if gh API fails (timeout, network error):
        leave alone (better orphan than lost state)
```

Adoption is restricted to the cwd's git repo (so a session in repo A does not adopt PRs from repo B). Each `gh pr view` call is bounded by `timeout 5`, but the scan performs that check **once per orphaned record**, so total session-start time is proportional to the number of orphans. With a typical 1–3 open PRs per project the scan completes well under 15 seconds; with many orphans it can be longer. The scan never blocks the assistant — it runs as part of the asyncRewake hook between turns, not on a user prompt.

Multi-terminal in the same project enforces strict first-wins: the adoption rewrite is serialized via `flock -x` on a per-owner-file lock and uses a compare-and-swap check (re-read the record under the lock and only rewrite if `pid` still equals the dead value we observed). Subsequent sessions either see the record as live (`kill -0` succeeds and the FIFO exists) or fail the CAS check, so no double delivery is possible.

This closes the gap for users who close and reopen Claude Code mid-workflow:

```
T+0   Session A (PID 100) creates PR #925 → owner: pid=100
T+5m  User closes Claude Code → PID 100 dies
T+5m  Owner record still on disk pointing at 100
T+10m User opens new Claude Code, PID 200, in the same project
T+10m wake-on-event.sh starts:
        - Creates new FIFO /tmp/claude-wake/.session-200.fifo
        - Scans pr-owners/Olbrasoft-VirtualAssistant-*.json
        - Finds PR #925: pid=100 (DEAD), state=OPEN
        - Adopts: rewrites record to pid=200, fifo=.session-200.fifo
T+15m GitHub Copilot finishes review → wake-claude.sh
T+15m Notifier looks up owner #925 → pid=200 (alive) → delivers via FIFO
T+15m Session B is woken with the review event → continues the workflow
```

## End-to-end sad path (owner truly gone, no successor)

```
T+0   Developer's Claude session 13008 created PR #925, then closed.
      Did NOT reopen Claude Code in that project afterwards.
T+1d  Owner record still on disk pointing at the now-dead PID 13008.
T+1d  GitHub fires deploy → event file written → wake-claude.sh called
T+1d  wake-claude.sh:
        - Reads the event
        - Derives PR number
        - Looks up owner: PID 13008, FIFO /tmp/claude-wake/.session-13008.fifo
        - kill -0 13008 → DEAD
        - DELETE owner record
        - DELETE event file
        - Logs to stderr: "DROPPED ... owner PID 13008 for PR #925 is dead"
T+1d  Nothing happens. No retry. No future delivery.
```

The user explicitly accepts this outcome: when they truly never come back to that project, stale events would only confuse them on a future fresh task. Adoption only fires when there IS a session in the same project.
