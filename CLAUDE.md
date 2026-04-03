# CLAUDE.md

Instructions for Claude Code when working in this repository.

## What This Is

**Olbrasoft/GitHub.Actions.Notify** — Reusable GitHub Actions composite actions and skills for CI/CD event notifications. Provides deploy/verify event files for FIFO-based push wake of Claude Code sessions, TTS voice feedback via VirtualAssistant, and post-deploy Playwright verification.

## Architecture

```
GitHub Actions (self-hosted runner)
  ├── Deploy job → write event file + wake-claude.sh → FIFO wake → Claude Code
  ├── Verify job → actions/playwright-verify → write event file + wake-claude.sh → FIFO wake
  └── TTS notification → POST localhost:5055/api/notifications → VirtualAssistant speaks

GitHub webhook (Copilot code review)
  └── gh webhook forward → webhook-receiver.py → write event file + wake-claude.sh → FIFO wake
```

**Two feedback channels:**
1. **FIFO-based push wake** (primary, instant) — event files + FIFO pipes wake the correct Claude Code session
2. **TTS notifications** (passive) — user hears the result via VirtualAssistant voice output

**FIFO Wake components (global, in `~/.claude/hooks/`):**
- `wake-on-event.sh` — asyncRewake hook in each Claude Code session (creates FIFO, blocks on read)
- `wake-claude.sh` — wake script (finds matching FIFOs by repo/branch, writes to them)
- `webhook-receiver.py` — HTTP server on port 9877 (parses webhooks, writes events, calls wake-claude.sh)
- `check-deploy-status.sh` — UserPromptSubmit fallback reader

## Repository Structure

- `actions/notify/` — Core composite action: curl POST to VirtualAssistant (TTS)
- `actions/ci-status/` — CI pass/fail reporter (wraps notify)
- `actions/deploy-status/` — Deploy result reporter (wraps notify)
- `actions/playwright-verify/` — Post-deploy Playwright verification
- `skills/ci-workflow-monitor/` — Claude Code skill for autonomous CI/CD pipeline monitoring
- `skills/ci-feedback-setup/` — One-time setup skill for new projects
- `scripts/` — Helper scripts (notify.sh, setup-runner.sh)
- `examples/` — Example CI workflows for Rust and .NET projects

## Integration

Any Olbrasoft project integrates by:
1. Registering a self-hosted runner (for deploy/verify jobs)
2. Adding event file write + `wake-claude.sh` call to deploy/verify workflow steps
3. Linking the `ci-workflow-monitor` skill to `.claude/skills/`
4. Ensuring `gh-webhook-forward.service` includes the repo (for code review notifications)

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
- Verify FIFO wake works: check `/tmp/claude-wake/{REPO}/` for session registrations

## Engineering Handbook

General development standards: `~/GitHub/Olbrasoft/engineering-handbook/`
