# CLAUDE.md

Instructions for Claude Code when working in this repository.

## What This Is

**Olbrasoft/GitHub.Actions.Notify** — Reusable GitHub Actions composite actions
and skills for CI/CD event notifications. TTS voice feedback via VirtualAssistant
plus optional post-deploy Playwright verification.

The wake-on-webhook side of the system has been split into a separate project:
**[Olbrasoft/ghnotify](https://github.com/Olbrasoft/ghnotify)** — a single Rust
binary that takes incoming GitHub webhook events and delivers them as prompts
into the matching `claude-<repo>` tmux session via `tmux send-keys`.

## Architecture

```
GitHub Actions (self-hosted runner)
  ├── Deploy job → actions/deploy-status (TTS POST to VirtualAssistant)
  ├── Verify job → actions/playwright-verify
  └── CI job   → actions/ci-status     (TTS POST to VirtualAssistant)

GitHub webhook events (CI, code review, etc.)
  └── ghnotify watch (systemd user service)
       ├── gh webhook forward subprocess(es) — one per repo
       └── HTTP receiver on 127.0.0.1:9877
            └── tmux send-keys → claude-<repo> session
```

The MCP-channel push-wake mechanism that this repo previously used was
**proven empirically to silently drop events** (verified against
claude-code 2.1.111 with `--dangerously-load-development-channels`). It was
deleted on 2026-04-16 along with the python webhook receiver, the FIFO
scripts, and the per-session port allocator.

## Repository Structure

- `actions/notify/` — Core composite action: curl POST to VirtualAssistant (TTS)
- `actions/ci-status/` — CI pass/fail reporter (wraps notify)
- `actions/deploy-status/` — Deploy result reporter (wraps notify)
- `actions/playwright-verify/` — Post-deploy Playwright verification
- `hooks/` — `get-session-id.sh` (used in PR session markers)
- `skills/ci-workflow-monitor/` — Claude Code skill for autonomous CI/CD monitoring
- `skills/ci-feedback-setup/` — One-time setup skill for new projects
- `scripts/notify.sh`, `scripts/setup-runner.sh` — Helper scripts
- `examples/` — Example CI workflows for Rust and .NET projects
- `docs/` — Architecture and integration guide

## Integration

Any Olbrasoft project integrates by:

1. Registering a self-hosted runner (for deploy/verify jobs).
2. Calling `actions/notify` (or `actions/ci-status` / `actions/deploy-status`)
   from the workflow to drive TTS announcements.
3. Linking the `ci-workflow-monitor` skill to `.claude/skills/`.
4. Ensuring `ghnotify-watch.service` (user systemd unit) is enabled — it routes
   GitHub webhook events to the right Claude tmux session.

## VirtualAssistant API

TTS notification actions POST to `http://localhost:5055/api/notifications`:

```json
{
  "text": "Czech notification text",
  "source": "ci-pipeline",
  "issueIds": [123]
}
```

Requires the `ci-pipeline` agent type in VirtualAssistant (AgentType.CiPipeline = 30).

## Testing

- Actions are composite (shell-based), no build step needed.
- Test by triggering a workflow that uses the actions on a self-hosted runner.
- Verify wake delivery: trigger a CI run, then watch `journalctl --user -u
  ghnotify-watch -f` for the `prompt delivered session=…` line.

## Wake Event Handling

When your session receives a wake event (ci-complete, code-review-complete,
deploy-complete, verify-complete), follow the runbook:
**`docs/session-wake-runbook.md`**.

Key rules that prevent sessions from getting stuck:

1. **Copilot reviews ONCE** — after CI green on fix commit, MERGE. No second
   review arrives.
2. **cr has NO deploy workflow** — after merge, your job ends.
3. **Post-merge CI on main does NOT trigger a wake** — don't wait for it.

## Engineering Handbook

General development standards: `~/GitHub/Olbrasoft/engineering-handbook/`
