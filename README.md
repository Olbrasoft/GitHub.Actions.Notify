# GitHub.Actions.Notify

Reusable GitHub Actions for CI/CD feedback with **TTS voice notifications** and
**push-wake of Claude Code sessions**. Solves the problem of AI coding agents
(Claude Code, OpenCode, etc.) "going blind" after creating a Pull Request —
they don't know when CI finishes, code review completes, or deploy succeeds.

## Problem

When an AI coding agent creates a PR:

1. CI builds and tests run — agent doesn't know the result.
2. Code review happens — agent doesn't know when it's done.
3. Deploy to production happens — agent doesn't know when to verify.
4. Production verification is needed — agent never runs it.

The agent either blocks waiting, or the user must manually check and relay status.

## Solution

**Two complementary feedback channels:**

1. **TTS Voice Notifications** — GitHub Actions posts to
   [VirtualAssistant](https://github.com/Olbrasoft/VirtualAssistant) on
   `localhost:5055`. The user hears "Deploy finished" or "Tests failed"
   spoken aloud.
2. **Push wake of the Claude session** — GitHub webhooks (CI complete, code
   review done, deploy result, etc.) hit
   [ghnotify](https://github.com/Olbrasoft/ghnotify), a single Rust binary
   running as a systemd user service. ghnotify resolves the target
   `claude-<repo>` tmux session and types the event in via `tmux send-keys`,
   so the assistant picks it up on its next prompt cycle and reacts per the
   `ci-workflow-monitor` skill (fix failures, address review comments, merge,
   verify production).

```
GitHub Actions (self-hosted runner)
  ├── Deploy job → actions/deploy-status (TTS to VirtualAssistant)
  ├── Verify job → actions/playwright-verify
  └── CI job   → actions/ci-status     (TTS to VirtualAssistant)

GitHub webhook events (CI, code review, deploy)
  └── ghnotify watch (systemd user service)
       ├── one `gh webhook forward` subprocess per repo
       └── HTTP receiver on 127.0.0.1:9877
            └── tmux send-keys → claude-<repo> session
```

The previous push-wake mechanism in this repo (MCP Channels + per-session FIFO
+ python webhook receiver + Bun/TS channel server) was removed on 2026-04-16.
MCP Channels were proven empirically to silently drop events on self-hosted
setups, even with `--dangerously-load-development-channels`.

## Actions

| Action | Purpose | Runs On |
|--------|---------|---------|
| [`actions/notify`](actions/notify/) | Core: POST notification to VirtualAssistant | self-hosted |
| [`actions/ci-status`](actions/ci-status/) | Report CI job pass/fail with stage context | self-hosted |
| [`actions/deploy-status`](actions/deploy-status/) | Report deploy success/failure | self-hosted |
| [`actions/playwright-verify`](actions/playwright-verify/) | Run health/homepage checks against production URL | self-hosted |

All actions are **composite** (shell-based, no Node.js, no Docker) — just
`curl` POST to VirtualAssistant.

## Quick Start

### 1. Install ghnotify (the wake forwarder)

```bash
cargo install --git https://github.com/Olbrasoft/ghnotify
ghnotify install        # adds claude() shell wrapper to ~/.bashrc
```

Run it as a systemd user service so it auto-starts and restarts:

```ini
# ~/.config/systemd/user/ghnotify-watch.service
[Unit]
Description=ghnotify watch - GitHub webhook → Claude Code tmux forwarder
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.cargo/bin/ghnotify watch
Restart=always
RestartSec=30
Environment=PATH=%h/.cargo/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now ghnotify-watch.service
```

`ghnotify watch` auto-discovers GitHub repos from running `claude` processes,
spawns a `gh webhook forward` per repo, and dispatches incoming events to the
matching `claude-<repo>` tmux session.

### 2. Register a self-hosted runner

```bash
git clone https://github.com/Olbrasoft/GitHub.Actions.Notify.git
cd GitHub.Actions.Notify
./scripts/setup-runner.sh Olbrasoft/<your-repo>
```

### 3. Add to your CI workflow

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: your-test-command

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

  verify:
    runs-on: self-hosted
    needs: [deploy]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - run: sleep 10
      - uses: Olbrasoft/GitHub.Actions.Notify/actions/playwright-verify@v1
        with:
          url: https://your-production-url.com
          checks: health,homepage
          repository: ${{ github.repository }}
```

### 4. (Optional) Add the Claude Code skill

```bash
mkdir -p .claude/skills
ln -s ~/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor \
      .claude/skills/ci-workflow-monitor
```

## Prerequisites

- **[VirtualAssistant](https://github.com/Olbrasoft/VirtualAssistant)** running
  on `localhost:5055` with `ci-pipeline` agent type (AgentType ID 30).
- **[ghnotify](https://github.com/Olbrasoft/ghnotify)** installed and running
  as a systemd user service (see Quick Start).
- **Self-hosted GitHub Actions runner** on the same machine as VirtualAssistant.
- **`gh` CLI** authenticated (for runner registration and `ghnotify watch`).
- **`tmux`** installed (ghnotify routes via tmux session names).
- **`jq`** and **`curl`** installed (used in notification action).

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

### `ci-workflow-monitor`

Issue-driven autonomous CI/CD pipeline monitor. Drives the assistant's reaction
when a wake event arrives via ghnotify:

- On `ci-complete` events: checks if Copilot review is done, then merges the PR.
- On `code-review-complete` events: reads review comments, fixes issues, pushes.
- On `deploy-complete` events: verifies the deployment, runs issue-specific
  Playwright checks.
- On `verify-complete` events: closes the issue if production is healthy.

### `ci-feedback-setup`

One-time setup skill for integrating CI feedback into a new project.

## Examples

- [Rust CI workflow](examples/rust-ci.yml) — Hybrid: cloud build/test,
  self-hosted deploy/verify.
- [.NET CI workflow](examples/dotnet-ci.yml) — .NET project with deploy
  notifications.

## License

MIT
