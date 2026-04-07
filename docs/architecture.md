# Architecture

## Overview

GitHub.Actions.Notify provides CI/CD event feedback through two complementary channels:

1. **FIFO push wake** (primary, instant) — event files + named pipes wake the correct Claude Code session within milliseconds of an event being produced
2. **TTS notifications** (passive, voice) — the user hears the result via VirtualAssistant voice output

The two channels are independent. A project may use either, both, or neither. The FIFO wake channel is what makes Claude Code react autonomously to CI/CD events without polling.

```
┌─────────────────────────────────────────────────────────────────────┐
│ EVENT PRODUCERS                                                      │
│                                                                      │
│ ┌─────────────────────────┐   ┌──────────────────────────────────┐  │
│ │ GitHub Actions          │   │ gh webhook forward (systemd)     │  │
│ │ (self-hosted runner)    │   │ + webhook-receiver.py (port 9877)│  │
│ │                         │   │                                  │  │
│ │ deploy.yml writes:      │   │ Listens for:                     │  │
│ │   {repo}-deploy-{sha}   │   │   pull_request_review            │  │
│ │   {repo}-verify-{sha}   │   │   check_suite                    │  │
│ │                         │   │                                  │  │
│ │ then calls              │   │ writes:                          │  │
│ │   wake-claude.sh REPO   │   │   {repo}-review-{pr}             │  │
│ └─────────┬───────────────┘   │   {repo}-ci-{pr}                 │  │
│           │                   │ then calls                       │  │
│           │                   │   wake-claude.sh REPO BRANCH     │  │
│           │                   └────────┬─────────────────────────┘  │
│           │                            │                            │
│           ▼                            ▼                            │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │ ~/.config/claude-channels/deploy-events/  (DURABLE QUEUE)  │    │
│   │   Olbrasoft-VirtualAssistant-deploy-32f4d49.json           │    │
│   │   Olbrasoft-VirtualAssistant-review-924.json               │    │
│   │   ...                                                      │    │
│   └────────────────────────────────────────────────────────────┘    │
│                            │                                        │
│                            ▼                                        │
│              ┌──────────────────────────────┐                       │
│              │ wake-claude.sh               │                       │
│              │  - reads event file          │                       │
│              │  - finds matching sessions   │                       │
│              │    (queries LIVE branch)     │                       │
│              │  - synchronous FIFO write    │                       │
│              │    (= ack from consumer)     │                       │
│              │  - deletes file ONLY if      │                       │
│              │    at least one ack          │                       │
│              └──────────┬───────────────────┘                       │
└─────────────────────────┼────────────────────────────────────────────┘
                          │ writes through FIFO
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│ EVENT CONSUMER (per Claude Code session)                             │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ wake-on-event.sh (asyncRewake hook)                         │    │
│  │                                                             │    │
│  │  1. mkfifo /tmp/claude-wake/{REPO}/{PID}.fifo               │    │
│  │  2. Write registration JSON (pid, branch, repo, cwd)        │    │
│  │  3. Drain ONE pending event file on startup (close gap)     │    │
│  │  4. cat $FIFO  ← blocks at zero CPU                         │    │
│  │  5. On event:                                               │    │
│  │     - parse JSON, output instructions to stderr             │    │
│  │     - exit 2 → Claude Code re-prompts assistant             │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                          ▲
                          │ fallback (UserPromptSubmit) if wake missed
                          │
┌─────────────────────────┴────────────────────────────────────────────┐
│ FALLBACK READER (per Claude Code session)                            │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ check-deploy-status.sh (UserPromptSubmit hook)              │    │
│  │                                                             │    │
│  │  - Reads any pending event files for current repo           │    │
│  │  - Outputs them to stdout (Claude Code reads as context)    │    │
│  │  - Deletes after reading                                    │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

## Design Contract

### Durable queue + best-effort fast path

- **Event files** in `~/.config/claude-channels/deploy-events/` are a **durable queue**. They persist on disk until a consumer has positively confirmed receipt.
- **FIFO writes** are the **fast path**. Each FIFO write is *synchronous*: the kernel blocks the writer until a reader has consumed the data. Therefore, "the FIFO write succeeded" IS the ack from the consumer.
- Producers (GitHub Actions, webhook-receiver.py) write the event file, then call `wake-claude.sh` as a hint to deliver immediately. The producer never deletes the file directly.
- `wake-claude.sh` deletes the event file ONLY after at least one live consumer has acked it via FIFO. If 0 consumers are alive (e.g. between asyncRewake spawns), the file persists and is picked up by `check-deploy-status.sh` on the next user prompt — no event is ever silently dropped.

### Filename uniqueness

Event filenames include a discriminator (commit SHA for deploy/verify events, PR number for code review events) so two events for the same repo can coexist on disk. Sequential deploys never overwrite each other.

```
Olbrasoft-VirtualAssistant-deploy-32f4d49.json
Olbrasoft-VirtualAssistant-deploy-637deaa.json
Olbrasoft-VirtualAssistant-verify-637deaa.json
Olbrasoft-VirtualAssistant-review-924.json
```

`wake-claude.sh` processes each matching file independently, attempting delivery to all matching sessions for each one.

### Live branch routing

`wake-on-event.sh` writes a `branch` field into the registration JSON, but `wake-claude.sh` **does not trust it for routing**. Instead, `wake-claude.sh` queries the live branch from the session's working directory via `git -C $cwd rev-parse --abbrev-ref HEAD`. The cached value is only refreshed every 600 seconds, so it goes stale immediately after the user runs `git checkout`. Querying live closes that race window completely.

## Components

| Component | Location | Role |
|---|---|---|
| `actions/notify` | `actions/notify/` | Composite GitHub Action — curl POST to VirtualAssistant TTS |
| `actions/deploy-status` | `actions/deploy-status/` | Wraps `notify` for deploy results |
| `actions/ci-status` | `actions/ci-status/` | Wraps `notify` for per-stage CI results |
| `actions/playwright-verify` | `actions/playwright-verify/` | Post-deploy production verification |
| `hooks/wake-on-event.sh` | `hooks/` | asyncRewake hook (per-session FIFO consumer) |
| `hooks/wake-claude.sh` | `hooks/` | Producer-side FIFO writer with ack semantics |
| `hooks/webhook-receiver.py` | `hooks/` | HTTP listener (port 9877) for `gh webhook forward` |
| `hooks/check-deploy-status.sh` | `hooks/` | UserPromptSubmit fallback reader |
| `hooks/start-webhook-forwards.sh` | `hooks/` | systemd service entrypoint (forwards + receiver) |
| `hooks/install.sh` | `hooks/` | One-shot installer that copies hooks into `~/.claude/hooks/` |
| `skills/ci-feedback-setup` | `skills/` | Per-project setup skill for Claude Code |
| `skills/ci-workflow-monitor` | `skills/` | Autonomous CI/CD pipeline monitoring skill |

## VirtualAssistant API contract (TTS channel)

```
POST http://localhost:5055/api/notifications
Content-Type: application/json

{
  "text": "Deploy cr na production uspesne dokoncen.",
  "source": "ci-pipeline",
  "issueIds": [166]
}

Response 200:
{
  "success": true,
  "id": 456,
  "text": "Deploy cr na production uspesne dokoncen.",
  "source": "ci-pipeline"
}
```

The `source: "ci-pipeline"` value maps to `AgentType.CiPipeline = 30` in VirtualAssistant. This agent has its own TTS voice profile so CI/CD notifications are distinguishable from Claude Code or Gemini notifications.

## Data flow — happy path

1. Developer pushes a commit to `main`
2. GitHub triggers the deploy workflow on a self-hosted runner
3. Deploy step runs (build, test, publish, restart, health check)
4. Notification step writes `~/.config/claude-channels/deploy-events/{repo}-deploy-{sha}.json` and calls `wake-claude.sh {repo}`
5. `wake-claude.sh` reads the file, finds the live Claude Code session for the repo (live branch query), and writes the event JSON through the session's FIFO with a 5s ack timeout
6. The session's `wake-on-event.sh` (blocked on `cat $FIFO`) receives the data, formats it as a stderr message ("Deploy success for ...; verify deployment"), and exits with code 2
7. Claude Code re-prompts the assistant with the stderr output as a system reminder
8. The assistant verifies the deployment and notifies the user via `mcp__notify__notify`

Latency from "GitHub Actions workflow finishes" to "assistant reacts" is typically under 1 second on the same machine.

## Data flow — fallback path (no live session)

1. Same as steps 1-4 above
2. `wake-claude.sh` finds no live sessions (or all FIFO writes time out), the file is left on disk
3. Some time later the user opens a Claude Code session and submits a prompt
4. The `UserPromptSubmit` hook fires `check-deploy-status.sh`
5. `check-deploy-status.sh` reads any pending event files for the current repo, outputs them to stdout (which Claude Code injects as a system reminder), and deletes them
6. The assistant sees the deploy result on its first response

The fallback path means events are durable across hook respawns, machine reboots, and sessions that were not running at deploy time.

## Why two channels (TTS + FIFO push wake)?

| Feature | TTS notifications | FIFO push wake |
|---|---|---|
| Audience | Human (voice) | AI assistant (Claude Code) |
| Latency | Sub-second | Sub-second |
| Persistence | None (TTS plays once) | Durable queue |
| Use case | "Did the deploy succeed?" | "Verify production, fix any failures" |
| Requires | VirtualAssistant running | Claude Code running OR fallback |

A typical project enables both: the developer hears the deploy result over the speakers AND Claude Code wakes up to verify production and react to any failures.
