# Integration Guide

Step-by-step guide to integrate GitHub.Actions.Notify into any project.

## Prerequisites

- [VirtualAssistant](https://github.com/Olbrasoft/VirtualAssistant) running on `localhost:5055` with `ci-pipeline` agent type (AgentType ID 30)
- `gh` CLI authenticated (`gh auth status`)
- `sudo` access for systemd service installation
- `jq` and `curl` installed

## Step 1: Clone This Repository

```bash
cd ~/Olbrasoft  # or wherever you keep repos
git clone https://github.com/Olbrasoft/GitHub.Actions.Notify.git
```

## Step 2: Install Hooks (one-time per machine)

The wake hooks (FIFO consumer, wake script, webhook receiver, fallback reader) live in this repo under `hooks/`. Install them into `~/.claude/hooks/` once per developer machine:

```bash
cd ~/Olbrasoft/GitHub.Actions.Notify
./hooks/install.sh
```

Verify the install with:

```bash
./hooks/install.sh --check    # reports drift between repo and ~/.claude/hooks/
```

Then register `wake-on-event.sh` as an asyncRewake hook in `~/.claude/settings.json` (the install script prints the snippet you need):

```jsonc
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/home/USER/.claude/hooks/wake-on-event.sh",
            "asyncRewake": true
          }
        ]
      }
    ]
  }
}
```

For code review push wake (Copilot review notifications), enable the systemd user service that runs `gh webhook forward` + `webhook-receiver.py`:

```bash
# Edit hooks/start-webhook-forwards.sh to include your repos in the REPOS array
# Then install the systemd unit (one-time):
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/gh-webhook-forward.service <<EOF
[Unit]
Description=GitHub Webhook Forward - code review notifications for all Olbrasoft repos
After=network.target

[Service]
Type=simple
ExecStart=/home/%u/.claude/hooks/start-webhook-forwards.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now gh-webhook-forward.service
```

## Step 3: Register Self-Hosted Runner (per project)

Run the setup script (one-time per repository):

```bash
cd ~/Olbrasoft/GitHub.Actions.Notify
./scripts/setup-runner.sh Olbrasoft/<your-repo>
```

This will:
1. Download the latest GitHub Actions runner to `~/actions-runner-<repo>/`
2. Register it with your repository using a token from GitHub API
3. Install it as a systemd service (auto-start on boot)

Verify the runner is online:

```bash
# Check systemd service
sudo systemctl status actions.runner.Olbrasoft-<repo>.$(hostname)-<repo>.service

# Check on GitHub
gh api repos/Olbrasoft/<your-repo>/actions/runners --jq '.runners[] | "\(.name): \(.status)"'
```

## Step 4: Add Notification Steps to CI Workflow

Edit your `.github/workflows/ci.yml` (or equivalent). The key change: **deploy and verify jobs must run on `self-hosted`** to access VirtualAssistant on localhost.

### Minimal — Deploy notification only

Add a notification step at the end of your deploy job:

```yaml
  deploy:
    runs-on: self-hosted  # Required for localhost access
    needs: [test]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      # ... your existing deploy steps ...

      - name: Notify deploy result
        if: always()
        uses: Olbrasoft/GitHub.Actions.Notify/actions/deploy-status@v1
        with:
          job-status: ${{ job.status }}
          repository: ${{ github.repository }}
```

### Recommended — Deploy + production verification

Add a verify job after deploy:

```yaml
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
      - name: Wait for deployment propagation
        run: sleep 10

      - name: Verify production
        uses: Olbrasoft/GitHub.Actions.Notify/actions/playwright-verify@v1
        with:
          url: https://your-production-url.com
          checks: health,homepage
          repository: ${{ github.repository }}
```

### Per-stage CI notifications

To get TTS notifications for each CI stage (build, test, etc.), add to each job. Note: these jobs must also run on `self-hosted`:

```yaml
  test:
    runs-on: self-hosted
    steps:
      # ... your test steps ...

      - name: Notify test result
        if: always()
        uses: Olbrasoft/GitHub.Actions.Notify/actions/ci-status@v1
        with:
          job-status: ${{ job.status }}
          stage: test
          repository: ${{ github.repository }}
```

## Step 5: Hybrid Runner Strategy

For projects with expensive CI (e.g., Rust compilation), use a **hybrid approach** — cloud runners for build/test, self-hosted only for deploy/verify:

| Job | Runner | Why |
|-----|--------|-----|
| check, fmt, test | `ubuntu-latest` | Free cloud CI, parallel, no local CPU usage |
| deploy | `self-hosted` | VPS access + localhost notifications |
| verify | `self-hosted` | Playwright + localhost notifications |

For lightweight projects (.NET, Node.js), you can run everything on `self-hosted`.

## Step 6: Add Claude Code Skill (Recommended)

Link the CI workflow monitor skill to your project:

```bash
cd ~/your-project
mkdir -p .claude/skills
ln -sf ~/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor .claude/skills/ci-workflow-monitor
```

This skill drives the autonomous CI/CD pipeline reaction in Claude Code. It tells the assistant how to react when a deploy event, code review event, CI event, or verify event arrives via FIFO push wake.

## Step 7: Update Project CLAUDE.md (Recommended)

Add the following to your project's CLAUDE.md in the Development Workflow section:

```markdown
### CI/CD Feedback (FIFO push wake)

This project uses FIFO-based push wake for CI/CD notifications. When a deploy
or verify event arrives, Claude Code is instantly woken via a FIFO pipe and
reacts according to the `ci-workflow-monitor` skill — no polling.

- Deploy and verify jobs run on self-hosted runner
- Code review events arrive via `gh webhook forward` + `webhook-receiver.py`
- Push notifications wake Claude Code instantly via FIFO pipes
- Production URL: https://your-production-url.com
```

## Step 8: Test the Integration

1. Create a test branch with a small change
2. Push and create a PR
3. Watch GitHub Actions — CI should run on cloud, deploy on self-hosted
4. After deploy, you should hear the TTS notification AND Claude Code (if running) should be woken via FIFO within seconds
5. Verify job should check production health and homepage
6. Claude Code should react to the verify event by running issue-specific checks

## Troubleshooting

### Notification not arriving

```bash
# 1. Test VirtualAssistant endpoint directly
curl -s -X POST "http://localhost:5055/api/notifications" \
  -H "Content-Type: application/json" \
  -d '{"text":"Test notification","source":"ci-pipeline"}' | jq .

# 2. Check ci-pipeline agent exists
# Should return success. If 400 error about invalid agent name,
# the CiPipeline agent type needs to be added to VirtualAssistant.

# 3. Check runner can reach localhost
# SSH into runner or run on runner machine:
curl -s http://localhost:5055/health
```

### Runner offline

```bash
# Check service status
sudo systemctl status actions.runner.Olbrasoft-<repo>.*

# Restart
sudo systemctl restart actions.runner.Olbrasoft-<repo>.*

# View logs
sudo journalctl -u actions.runner.Olbrasoft-<repo>.* -f
```

### Action template validation error

If you see `Unrecognized named-value: 'job'` or similar — make sure you're using `@v1` tag (not `@main`). Earlier versions had expression syntax in input descriptions.

### Playwright not available

```bash
npx playwright install chromium
```

### Deploy works but verify is skipped

Check the `if` condition on the verify job. It should match the deploy job's conditions:

```yaml
if: github.ref == 'refs/heads/main' && github.event_name == 'push'
```
