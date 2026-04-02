# CLAUDE.md

Instructions for Claude Code when working in this repository.

## What This Is

**Olbrasoft/GitHub.Actions.Notify** — Reusable GitHub Actions composite actions that send CI/CD event notifications to VirtualAssistant (localhost:5055). Provides TTS voice feedback for build results, deploy status, and post-deploy Playwright verification.

## Architecture

```
GitHub Actions (self-hosted runner)
  ├── CI jobs → actions/ci-status → POST localhost:5055/api/notifications → TTS
  ├── Deploy job → actions/deploy-status → POST localhost:5055/api/notifications → TTS
  └── Verify job → actions/playwright-verify → Playwright + notify result
```

**Three feedback channels:**
1. **Channel MCP push** (primary, instant) — GitHub Actions POSTs to Channel MCP server → Claude Code session receives push event immediately after deploy
2. **TTS notifications** (passive) — user hears the result via VirtualAssistant voice output
3. **CronCreate polling** (fallback) — Claude Code polls status via `gh pr checks` (only when Channel not available)

## Repository Structure

- `channel-server/` — Channel MCP server (Node.js/TypeScript): receives webhooks, pushes to Claude Code
- `actions/notify/` — Core composite action: curl POST to VirtualAssistant (TTS)
- `actions/channel-notify/` — Channel push action: curl POST to Channel MCP server
- `actions/ci-status/` — CI pass/fail reporter (wraps notify)
- `actions/deploy-status/` — Deploy result reporter (wraps notify)
- `actions/playwright-verify/` — Post-deploy Playwright verification
- `skills/ci-workflow-monitor/` — Claude Code skill for autonomous monitoring (Channel + CronCreate)
- `scripts/assign-port.sh` — Assigns unique port per project from central registry
- `scripts/` — Helper scripts (notify.sh, setup-runner.sh)
- `examples/` — Example CI workflows for Rust and .NET projects

## Channel MCP Setup

Each project gets a unique port from `~/.config/claude-channels/ports.json`:
```bash
# 1. Build the Channel server (one-time)
cd ~/Olbrasoft/GitHub.Actions.Notify/channel-server
npm ci && npm run build

# 2. Assign port for a project
./scripts/assign-port.sh Olbrasoft/VirtualAssistant  # → 9878

# 3. Configure MCP for the project (run in project directory)
claude mcp add --scope local ci-channel -- \
  node ~/Olbrasoft/GitHub.Actions.Notify/channel-server/dist/index.js --port 9878
```

## Integration

Any Olbrasoft project integrates by:
1. Registering a self-hosted runner (for deploy/verify jobs)
2. Adding notification steps to their CI workflow using these actions
3. Optionally adding the `ci-workflow-monitor` skill to `.claude/skills/`

## VirtualAssistant API

All actions POST to `http://localhost:5055/api/notifications`:
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
- Verify notifications appear in VirtualAssistant database and are spoken via TTS

## Engineering Handbook

General development standards: `~/GitHub/Olbrasoft/engineering-handbook/`
