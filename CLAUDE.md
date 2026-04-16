# CLAUDE.md

Instructions for Claude Code when working in this repository.

## What This Is

**Olbrasoft/GitHub.Actions.Notify** — Reusable GitHub Actions composite actions and skills for CI/CD event notifications. Uses MCP Channels for push wake of Claude Code sessions, TTS voice feedback via VirtualAssistant, and post-deploy Playwright verification.

## Architecture

```
GitHub Actions (self-hosted runner)
  ├── Deploy job → write event file → channel/webhook.ts → Claude Code session
  ├── Verify job → actions/playwright-verify → write event file → channel/webhook.ts
  └── TTS notification → POST localhost:5055/api/notifications → VirtualAssistant speaks

GitHub webhook (Copilot code review)
  └── gh webhook forward → webhook-receiver.py → write event file → channel/webhook.ts
```

**Two feedback channels:**
1. **MCP Channel push wake** (primary, instant) — event files in `~/.config/claude-channels/deploy-events/` are watched by `channel/webhook.ts` and pushed to the Claude Code session via MCP Channels
2. **TTS notifications** (passive) — user hears the result via VirtualAssistant voice output

**Components:**
- `channel/webhook.ts` — MCP channel server. Watches deploy-events directory (fs.watch + 5s poll fallback), pushes events to Claude Code session. Each session spawns its own instance — no port conflicts.
- `webhook-receiver.py` — HTTP server on port 9877 (parses GitHub webhooks, writes event files to disk)
- `start-webhook-forwards.sh` — systemd service entrypoint that runs `gh webhook forward`, auto-discovers repos from active Claude sessions.
- `install.sh` — Installer for helper scripts. Cleans up legacy FIFO artifacts. Run `./hooks/install.sh --check` to detect drift.

## Repository Structure

- `actions/notify/` — Core composite action: curl POST to VirtualAssistant (TTS)
- `actions/ci-status/` — CI pass/fail reporter (wraps notify)
- `actions/deploy-status/` — Deploy result reporter (wraps notify)
- `actions/playwright-verify/` — Post-deploy Playwright verification
- `channel/` — MCP channel server for GitHub webhook event delivery
- `hooks/` — Helper scripts and webhook receiver (install with `./hooks/install.sh`)
- `skills/ci-workflow-monitor/` — Claude Code skill for autonomous CI/CD pipeline monitoring
- `skills/ci-feedback-setup/` — One-time setup skill for new projects
- `scripts/` — Helper scripts (notify.sh, setup-runner.sh)
- `examples/` — Example CI workflows for Rust and .NET projects
- `docs/` — Architecture and integration guide

## Integration

Any Olbrasoft project integrates by:
1. Registering a self-hosted runner (for deploy/verify jobs)
2. Adding event file write to deploy/verify workflow steps (writes to `~/.config/claude-channels/deploy-events/`)
3. Linking the `ci-workflow-monitor` skill to `.claude/skills/`
4. Registering `github-webhook` MCP channel server in `~/.claude.json`
5. Ensuring `gh-webhook-forward.service` is active (auto-discovers repos from active sessions)

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

- Actions are composite (shell-based), no build step needed
- Test by triggering a workflow that uses the actions on a self-hosted runner
- Verify channel delivery: check `~/.config/claude-channels/deploy-events/` for pending event files

## Wake Event Handling

When your session receives a wake event (ci-complete, code-review-complete, deploy-complete, verify-complete), follow the runbook: **`docs/session-wake-runbook.md`**

Key rules that prevent sessions from getting stuck:

1. **Copilot reviews ONCE** — after CI green on fix commit, MERGE. No second review arrives.
2. **cr has NO deploy workflow** — after merge, your job ends. No deploy-complete event will come.
3. **Post-merge CI on main does NOT trigger a wake** — don't wait for it.

For system-level debugging (events not arriving): **`docs/wake-notification-system.md`**

## Engineering Handbook

General development standards: `~/GitHub/Olbrasoft/engineering-handbook/`
