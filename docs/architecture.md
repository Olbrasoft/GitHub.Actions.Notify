# Architecture

> **For debugging "why didn't the wake event arrive" / "why did six arrive":**
> read [`wake-notification-system.md`](./wake-notification-system.md) FIRST.
> It has the failure-mode catalogue, exact `journalctl` recipes, and the
> known-limitations list. This file describes design intent; that file
> describes what actually happens and how to fix it.

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

This project guarantees that **the running Claude Code session working on a given repository is woken up** when:
- Copilot finishes the code review
- CI completes
- Deploy completes
- Post-deploy verification completes

Wake happens within seconds of the GitHub event, while the session is still alive. The assistant continues the workflow autonomously.

## Hard requirements (per project owner)

| # | Requirement |
|---|---|
| R1 | Delivery is **one transaction**: GitHub triggers → wake-claude.sh runs → either delivers to a live session or drops the event. Nothing in between. |
| R2 | **No background daemons**, no inbox queues drained later. The asyncRewake hook (which Claude Code spawns itself on Stop and SessionStart events) is the only consumer. wake-claude.sh's bounded retry loop (R5) is in-process and tied to the single delivery transaction — there is no out-of-band poller. |
| R3 | **No PR registry**, no PostToolUse auto-registration, no per-PR ownership state. wake-claude.sh enumerates running Claude sessions on its own at delivery time. |
| R4 | **Strict matching**: deliver only when exactly one running Claude session is on the matching repository. If 0 or 2+ matches, drop (refuse to guess). |
| R5 | If the consumer FIFO has no reader at the moment of write (the Claude session is actively running tools and the asyncRewake hook is in the gap between exit-2 and respawn), retry the write for up to 60 seconds, re-checking session liveness on each iteration. After 60s, drop. |
| R6 | **No silent drops**. Every drop logs a reason to stderr. |

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
│              │    extract repo + PR + commit        │               │
│              │    PRIMARY: read PR body marker      │               │
│              │      <!-- claude-pid: NNN -->        │               │
│              │      via gh pr view                  │               │
│              │    FALLBACK: enumerate live Claude   │               │
│              │      sessions via pgrep + /proc/cwd  │               │
│              │      strict count==1 → use it        │               │
│              │      else → drop                     │               │
│              │    kill orphan FIFO readers          │               │
│              │    bounded retry FIFO write (60s)    │               │
│              │    DELETE event file (always)        │               │
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
│ │  2. SUICIDE if no Claude ancestor (we're an orphan          │     │
│ │     reparented to systemd-user — no point listening)        │     │
│ │  3. SINGLETON CHECK: refuse to run if another wake-on-event │     │
│ │     instance is already reading the same FIFO for the same  │     │
│ │     Claude PID (multiple readers cause kernel-level         │     │
│ │     event stealing)                                         │     │
│ │  4. mkfifo /tmp/claude-wake/.session-{PID}.fifo             │     │
│ │  5. cat $FIFO   ← blocks at zero CPU                        │     │
│ │  6. On read: parse event, output instructions to stderr,    │     │
│ │     exit 2 → Claude Code re-prompts assistant with stderr   │     │
│ │     as a system reminder (this IS the "wake")               │     │
│ │  7. On real exit (Claude session dies): cleanup trap        │     │
│ │     removes FIFO and manifest                               │     │
│ └─────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────┘
```

## How wake-claude.sh finds the target session

```
1. Read event JSON
2. Extract PR number (from prNumber field, OR derive via gh api commits/$sha/pulls)
3. PRIMARY routing: if PR number is known, fetch PR body via
       gh pr view N --repo $REPO_FULL --json body
   and look for the session UUID marker:
       <!-- claude-session: UUID -->
   The UUID is the basename of the JSONL file in
   ~/.claude/projects/<encoded-cwd>/. Find the live Claude PID whose
   CURRENT session (most recently modified .jsonl in its cwd's project
   dir) matches this UUID:
     for each pid in `pgrep -x claude`:
         cwd = readlink /proc/$pid/cwd
         enc = cwd with / replaced by -
         latest = most recently modified .jsonl in $HOME/.claude/projects/$enc/
         if basename(latest) == "$UUID.jsonl":
             target_pid = pid
             break
4. FALLBACK routing: if no marker, or marker session not running, enumerate
   `pgrep -x claude` and select PIDs whose /proc/PID/cwd basename equals
   the repo basename. STRICT:
     - exactly 1 match → target_pid = that one
     - 0 matches OR 2+ matches → DROP (ambiguous, refuse to guess)
5. If target_pid is not a live Claude → DROP
6. Find FIFO at /tmp/claude-wake/.session-{target_pid}.fifo
7. Kill any orphan readers on that FIFO (wake-on-event.sh processes
   whose process tree has no `claude` ancestor — they were reparented
   after their original session died). Detection walks the orphan's
   own descendant tree to confirm it actually owns a `cat` reading
   our FIFO before killing.
8. Bounded retry write loop (default 300s, configurable via
   WAKE_CLAUDE_RETRY_SECS):
     for each iteration:
       re-check target liveness
       try `printf %s "$data" > $FIFO` with WRITE_TIMEOUT (default 3s)
       if write succeeds → DELIVERED
       sleep 1
     if loop expires → DROP
9. Always delete the event file at the end (delivered or dropped)
```

## How the session UUID gets into PR bodies

Claude Code sessions are identified by the JSONL filename in
`~/.claude/projects/<encoded-cwd>/`. The current session for a running
Claude process is the most recently modified `.jsonl` in that directory.

When Claude creates a PR, it must embed this UUID at the top of the PR
body so wake-claude.sh can route events back to it. This is documented
in the user's CLAUDE.md and in the `dotnet-coding` skill. The model uses
the helper script `~/.claude/hooks/get-session-id.sh`:

```bash
SESSION_ID=$(~/.claude/hooks/get-session-id.sh)
gh pr create --title "feat: X" --body "$(cat <<EOF
<!-- claude-session: $SESSION_ID -->

Closes #123

## Summary
…
EOF
)"
```

The helper walks up the parent process tree to find the Claude PID, reads
its `/proc/PID/cwd`, encodes that to find the project directory, and emits
the most recently modified `.jsonl` basename.

## What this design does NOT do (and why)

| Behavior | Why we omit it |
|---|---|
| PR ownership registry | Per R3: wake-claude.sh enumerates sessions on its own at delivery time. The registry was a complication that introduced staleness, race conditions, and a PostToolUse hook to maintain. Eliminated entirely. |
| Inbox files queued for later drain | Per R1/R2: the user explicitly chose "one transaction, no retroactive checking". Inbox files = retroactive checking. |
| Background poller / daemon | Per R2: no daemons. The asyncRewake hook spawned by Claude Code itself is the only local consumer. |
| Persistence beyond session lifetime | Per R1: drops on dead session. Stale events confuse the next session. |
| Drain pending events on session start | Same reason. |
| Delivery to multiple sessions in same repo | Per R4: strict count==1 matching. Refuses to guess when ambiguous. |
| Branch-based routing | Replaced by repo-cwd matching plus optional PR body marker. |

## How orphan readers are handled

A wake-on-event.sh hook process becomes "orphan" when:
- Its original Claude session died (the user closed Claude Code)
- The hook process is no longer in any live `claude` ancestor's process tree
  (typically reparented to systemd-user, but the exact reaper PID is not
  load-bearing — what matters is the absence of a `claude` ancestor)
- It is still alive, blocked on `cat $FIFO`, and would steal future events

Two layers of defense:

1. **Suicide on startup** (`wake-on-event.sh`): walks the parent process tree, and if no Claude ancestor exists, exits immediately. New hooks never become orphans.

2. **Pre-write kill** (`wake-claude.sh`): before writing to a target FIFO, scans all wake-on-event.sh processes whose process tree has no `claude` ancestor. For each such orphan, walks its descendant tree (script → bash subshell → timeout → cat) looking for a `cat` whose argv literally contains the target FIFO path (fixed-string match against `/proc/<pid>/cmdline`, no regex). If found, kills the entire descendant tree of the orphan, then the orphan itself. This handles legacy orphans that pre-existed the suicide check.

## Components

| File | Role |
|---|---|
| `hooks/wake-on-event.sh` | asyncRewake hook in each Claude session. Suicide check, singleton check, creates the per-session FIFO, blocks on read, processes events, exits 2 to wake the assistant. |
| `hooks/wake-claude.sh` | Producer-side Notifier. Enumerates running Claude sessions, finds the target by PR body marker or strict cwd matching, kills orphan readers, delivers via FIFO with bounded retry. |
| `hooks/webhook-receiver.py` | HTTP server on port 9877 that receives `pull_request_review` and `check_suite` webhooks from GitHub via `gh webhook forward`, writes event files, calls `wake-claude.sh`. |
| `hooks/start-webhook-forwards.sh` | systemd service entry point that runs `gh webhook forward` for all configured repos plus the webhook receiver. |
| `hooks/install.sh` | One-shot installer. Copies hooks into `~/.claude/hooks/` and verifies the asyncRewake hook configuration in `~/.claude/settings.json`. |
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
T+0    Developer pushes a commit to main
T+0    GitHub fires the deploy workflow on the self-hosted runner
T+30s  Deploy step finishes (build, test, publish, restart, health check)
T+30s  Notification step writes
       ~/.config/claude-channels/deploy-events/Olbrasoft-VirtualAssistant-deploy-32f4d49-24079371158-1.json
       and calls wake-claude.sh Olbrasoft/VirtualAssistant
T+30s  wake-claude.sh:
         - Reads the event
         - Derives PR number from commit SHA via gh API
         - Reads PR body, finds <!-- claude-pid: 13008 --> marker (if present)
         - Falls back to enumerating `pgrep -x claude` and matching cwd
         - Single match: PID 13008 in /home/jirka/Olbrasoft/VirtualAssistant
         - Finds FIFO /tmp/claude-wake/.session-13008.fifo
         - Kills any orphan readers
         - Synchronous write with 60s bounded retry
         - Returns success → DELETE the event file
T+30s  The asyncRewake hook in Claude session 13008 was blocked on the FIFO.
       It receives the event JSON, parses it, outputs:
         "Deploy success for Olbrasoft/VirtualAssistant: Merge pull request #925 (32f4d49)"
         "Verify deployment. Notify user via mcp__notify__notify."
       to stderr, then exits 2.
T+31s  Claude Code re-prompts the assistant with the stderr as a system reminder.
T+31s  The assistant verifies the deployment, runs Playwright on the changed
       pages, notifies the user, and closes the issue.
```

Total latency from "deploy completes" to "assistant reacts": **~1 second** when the session is idle, up to **~60 seconds** when the session is actively running tools (waiting for the next Stop boundary so the asyncRewake hook respawns and becomes a FIFO reader again).

## End-to-end sad path: target session was busy too long

```
T+0    GitHub fires deploy → event written → wake-claude.sh called
T+0    wake-claude.sh: target found, FIFO write attempted
T+0..60s  Each retry iteration: liveness check, write attempt
       No reader → write times out after 3s → sleep 1s → retry
T+60s  Loop expires → DROPPED
       Logs: "DROP after 60s retry: ... (PID 13008, PR=925)"
```

This drop happens when the Claude session is processing tools continuously for >60 seconds without a Stop boundary. The user explicitly accepts this outcome ("doručeno NEBO zahozeno"). It is rare in practice because deploy/verify events arrive minutes after the user's last interaction, when the session is typically idle.

## End-to-end sad path: no matching session

```
T+0    GitHub fires deploy → event written → wake-claude.sh called
T+0    wake-claude.sh: no PR body marker, enumerates `pgrep -x claude`
       Result: no Claude session has /proc/PID/cwd basename matching the repo
T+0    DROPPED
       Logs: "DROP no Claude session on Olbrasoft/cr (PR=308): ..."
```

The user closed the Claude session for that project. The event is dropped without persistence.

## End-to-end sad path: ambiguous match

```
T+0    GitHub fires deploy → event written → wake-claude.sh called
T+0    wake-claude.sh: no PR body marker, enumerates `pgrep -x claude`
       Result: 2 Claude sessions both have cwd in /home/jirka/Olbrasoft/cr
       (e.g. one in main, one in a worktree)
T+0    DROPPED
       Logs: "DROP ambiguous: 2 Claude sessions on Olbrasoft/cr ..."
```

To unblock this case, the user can have Claude embed `<!-- claude-pid: NNN -->` in PR bodies. With the marker, routing is unambiguous regardless of how many sessions are active in the repo.
