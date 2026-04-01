# GitHub.Actions.Notify

Reusable GitHub Actions for CI/CD feedback with TTS voice notifications. Solves the problem of AI coding agents (Claude Code, OpenCode, etc.) "going blind" after creating a Pull Request — they don't know when CI finishes, code review completes, or deploy succeeds.

## Problem

When an AI coding agent creates a PR:
1. CI builds and tests run — agent doesn't know the result
2. Code review happens — agent doesn't know when it's done
3. Deploy to production happens — agent doesn't know when to verify
4. Production verification is needed — agent never runs it

The agent either blocks waiting, or the user must manually check and relay status.

## Solution

**Two complementary feedback channels:**

1. **TTS Voice Notifications** — GitHub Actions posts to [VirtualAssistant](https://github.com/Olbrasoft/VirtualAssistant) on `localhost:5055`. The user hears "Deploy finished" or "Tests failed" spoken aloud.
2. **CronCreate Polling** — Claude Code autonomously polls CI/review/deploy status every 2 minutes and reacts: fixes failures, merges PRs, verifies production.

```
GitHub Actions (self-hosted runner)
  ├── Deploy job → POST localhost:5055 → VirtualAssistant → TTS "Deploy OK"
  └── Verify job → Playwright health check → POST → TTS "Produkce ověřena"

Claude Code (local session)
  └── CronCreate (every 2 min) → gh pr checks → autonomous merge/fix/verify
```

## Actions

| Action | Purpose | Runs On |
|--------|---------|---------|
| [`actions/notify`](actions/notify/) | Core: POST notification to VirtualAssistant | self-hosted |
| [`actions/ci-status`](actions/ci-status/) | Report CI job pass/fail with stage context | self-hosted |
| [`actions/deploy-status`](actions/deploy-status/) | Report deploy success/failure | self-hosted |
| [`actions/playwright-verify`](actions/playwright-verify/) | Run health/homepage checks against production URL | self-hosted |

All actions are **composite** (shell-based, no Node.js, no Docker) — just `curl` POST to VirtualAssistant.

## Quick Start

### 1. Register a self-hosted runner

```bash
git clone https://github.com/Olbrasoft/GitHub.Actions.Notify.git
cd GitHub.Actions.Notify
./scripts/setup-runner.sh Olbrasoft/<your-repo>
```

### 2. Add to your CI workflow

```yaml
jobs:
  # Build/test can stay on cloud runner
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: your-test-command

  # Deploy + notifications on self-hosted runner
  deploy:
    runs-on: self-hosted
    needs: [test]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      # ... your deploy steps ...

      - name: Notify deploy result
        if: always()
        uses: Olbrasoft/GitHub.Actions.Notify/actions/deploy-status@v1
        with:
          job-status: ${{ job.status }}
          repository: ${{ github.repository }}

  # Post-deploy verification
  verify:
    runs-on: self-hosted
    needs: [deploy]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - name: Wait for deployment propagation
        run: sleep 10
      - uses: Olbrasoft/GitHub.Actions.Notify/actions/playwright-verify@v1
        with:
          url: https://your-production-url.com
          checks: health,homepage
          repository: ${{ github.repository }}
```

### 3. (Optional) Add Claude Code skill

```bash
mkdir -p .claude/skills
ln -s ~/GitHub/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor .claude/skills/ci-workflow-monitor
```

This enables Claude Code to autonomously monitor the pipeline after creating a PR.

## Prerequisites

- **[VirtualAssistant](https://github.com/Olbrasoft/VirtualAssistant)** running on `localhost:5055` with `ci-pipeline` agent type (AgentType ID 30)
- **Self-hosted GitHub Actions runner** on the same machine as VirtualAssistant
- **`gh` CLI** authenticated (for runner registration)
- **`jq`** installed (used in notification action)
- **`curl`** installed (used in all actions)

## Action Inputs

### `actions/notify` (Core)

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `text` | yes | — | Notification text (Czech recommended for TTS) |
| `source` | no | `ci-pipeline` | Agent source identifier |
| `issue-ids` | no | `""` | Comma-separated GitHub issue IDs |
| `virtual-assistant-url` | no | `http://localhost:5055` | VirtualAssistant API URL |

### `actions/ci-status`

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `job-status` | yes | — | `${{ job.status }}` |
| `stage` | yes | — | CI stage: check, format, test, build |
| `repository` | yes | — | `${{ github.repository }}` |
| `run-url` | no | `""` | Link to workflow run |

### `actions/deploy-status`

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `job-status` | yes | — | `${{ job.status }}` |
| `repository` | yes | — | `${{ github.repository }}` |
| `environment` | no | `production` | Deploy environment name |
| `run-url` | no | `""` | Link to workflow run |

### `actions/playwright-verify`

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `url` | yes | — | Production URL to verify |
| `checks` | no | `health,homepage` | Checks to run: health, homepage, title |
| `repository` | no | `""` | Repository name |
| `timeout` | no | `30` | Request timeout in seconds |

## Claude Code Skills

Two skills are included for AI coding agent integration:

### `ci-workflow-monitor`

Issue-driven autonomous CI/CD pipeline monitor. After creating a PR, sets up CronCreate polling that:
- Monitors CI status and fixes failures
- Monitors code review and addresses comments
- Merges PR when ready (no asking!)
- Monitors deploy and verifies production
- Reads issue description and verifies issue-specific changes on production

### `ci-feedback-setup`

One-time setup skill for integrating CI feedback into a new project. Guides through:
- Runner registration
- CI workflow modification
- Skill linking
- CLAUDE.md update

## Architecture

See [docs/architecture.md](docs/architecture.md) for detailed diagrams and data flow.

## Examples

- [Rust CI workflow](examples/rust-ci.yml) — Hybrid: cloud build/test, self-hosted deploy/verify
- [.NET CI workflow](examples/dotnet-ci.yml) — .NET project with deploy notifications

## How It Works

1. **GitHub Actions** runs your CI pipeline (build, test)
2. **Deploy job** runs on self-hosted runner, deploys your app
3. **Deploy-status action** POSTs notification to VirtualAssistant on localhost
4. **VirtualAssistant** saves notification, speaks it via TTS (e.g., "Deploy cr finished successfully")
5. **Verify job** runs curl checks against production URL
6. **Playwright-verify action** POSTs verification result to VirtualAssistant
7. **Claude Code** (if running) detects status changes via CronCreate and acts autonomously

## Integration Guide

See [docs/integration-guide.md](docs/integration-guide.md) for complete step-by-step setup.

## License

MIT
