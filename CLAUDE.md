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

**Two feedback channels:**
1. **TTS notifications** (passive) — user hears the result via VirtualAssistant voice output
2. **CronCreate polling** (active) — Claude Code autonomously reacts to status changes via `gh pr checks`

## Repository Structure

- `actions/notify/` — Core composite action: curl POST to VirtualAssistant
- `actions/ci-status/` — CI pass/fail reporter (wraps notify)
- `actions/deploy-status/` — Deploy result reporter (wraps notify)
- `actions/playwright-verify/` — Post-deploy Playwright verification
- `skills/ci-workflow-monitor/` — Claude Code skill for CronCreate-based monitoring
- `scripts/` — Helper scripts (notify.sh, setup-runner.sh)
- `examples/` — Example CI workflows for Rust and .NET projects

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
