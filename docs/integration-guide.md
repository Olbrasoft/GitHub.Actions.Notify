# Integration Guide

Step-by-step setup of GitHub.Actions.Notify + ghnotify for a new
Olbrasoft project.

## Prerequisites

- [VirtualAssistant](https://github.com/Olbrasoft/VirtualAssistant) running on
  `localhost:5055` with the `ci-pipeline` agent type (AgentType ID 30).
- `gh` CLI authenticated (`gh auth status`).
- `tmux` installed.
- `jq` and `curl` installed.
- Rust toolchain (for installing the ghnotify binary).

## Step 1 — Install ghnotify (one-time per machine)

```bash
cargo install --git https://github.com/Olbrasoft/ghnotify
ghnotify install                    # writes the claude() shell wrapper
```

The wrapper makes every `claude` invocation land inside a tmux session named
`claude-<repo>`, which is the address ghnotify uses to route incoming
webhook events.

Open a new shell (or `source ~/.bashrc`) for the wrapper to take effect.

## Step 2 — Run ghnotify as a systemd user service

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
journalctl --user -u ghnotify-watch -n 30 --no-pager
```

`ghnotify watch` auto-discovers your active GitHub repos by walking `/proc`
for running `claude` processes and reading each cwd's git remote.

## Step 3 — Register a self-hosted runner for this project

```bash
cd ~/Olbrasoft/GitHub.Actions.Notify
./scripts/setup-runner.sh Olbrasoft/<your-repo>
```

## Step 4 — Add notification actions to the workflow

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
    if: github.ref == 'refs/heads/main'
    steps:
      # ... your deploy steps ...
      - if: always()
        uses: Olbrasoft/GitHub.Actions.Notify/actions/deploy-status@v1
        with:
          job-status: ${{ job.status }}
          repository: ${{ github.repository }}

  verify:
    runs-on: self-hosted
    needs: [deploy]
    if: github.ref == 'refs/heads/main'
    steps:
      - run: sleep 10
      - uses: Olbrasoft/GitHub.Actions.Notify/actions/playwright-verify@v1
        with:
          url: https://your-production-url.com
          checks: health,homepage
          repository: ${{ github.repository }}
```

## Step 5 — Link the Claude Code skill (optional)

```bash
mkdir -p .claude/skills
ln -s ~/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor \
      .claude/skills/ci-workflow-monitor
```

## Verify the wake path

1. `claude` inside the project (now wrapped in tmux as `claude-<repo>`).
2. Trigger a CI run on a PR.
3. `journalctl --user -u ghnotify-watch -f` — you should see
   `prompt delivered session=claude-<repo> event_type=workflow_run` (or
   `check_suite`) when GitHub fires the event.
4. The event text appears in the assistant's input box on its next prompt
   cycle and the assistant reacts per the `ci-workflow-monitor` skill.
