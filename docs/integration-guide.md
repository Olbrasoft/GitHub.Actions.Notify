# Integration Guide

Step-by-step guide to integrate GitHub.Actions.Notify into any project.

## Prerequisites

- [VirtualAssistant](https://github.com/Olbrasoft/VirtualAssistant) running on `localhost:5055` with `ci-pipeline` agent type (AgentType ID 30)
- `gh` CLI authenticated (`gh auth status`)
- `sudo` access for systemd service installation
- `jq` and `curl` installed

## Step 1: Clone This Repository

```bash
cd ~/GitHub/Olbrasoft  # or wherever you keep repos
git clone https://github.com/Olbrasoft/GitHub.Actions.Notify.git
```

## Step 2: Register Self-Hosted Runner

Run the setup script (one-time per repository):

```bash
cd ~/GitHub/Olbrasoft/GitHub.Actions.Notify
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

## Step 3: Add Notification Steps to CI Workflow

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

## Step 4: Hybrid Runner Strategy

For projects with expensive CI (e.g., Rust compilation), use a **hybrid approach** — cloud runners for build/test, self-hosted only for deploy/verify:

| Job | Runner | Why |
|-----|--------|-----|
| check, fmt, test | `ubuntu-latest` | Free cloud CI, parallel, no local CPU usage |
| deploy | `self-hosted` | VPS access + localhost notifications |
| verify | `self-hosted` | Playwright + localhost notifications |

For lightweight projects (.NET, Node.js), you can run everything on `self-hosted`.

## Step 5: Add Claude Code Skill (Recommended)

Link the CI workflow monitor skill to your project:

```bash
cd ~/your-project
mkdir -p .claude/skills
ln -sf ~/GitHub/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor .claude/skills/ci-workflow-monitor
```

This skill contains the CronCreate prompt template that Claude Code uses to autonomously monitor the entire CI/CD pipeline after creating a PR.

## Step 6: Update Project CLAUDE.md (Recommended)

Add the following to your project's CLAUDE.md in the Development Workflow section:

```markdown
### CI/CD Feedback (Autonomous)

After creating a PR, ALWAYS set up CronCreate monitoring — this is mandatory.

Use the template from `ci-workflow-monitor` skill:
- CronCreate polls every 2 minutes
- Autonomously: fixes CI failures, addresses review comments, merges PRs
- After merge: monitors deploy, verifies production
- Reads issue description and verifies issue-specific changes on production
- NEVER asks the user — acts fully autonomously

Deploy and verify jobs run on self-hosted runner with TTS notifications via VirtualAssistant.
Production URL: https://your-production-url.com
```

## Step 7: Test the Integration

1. Create a test branch with a small change
2. Push and create a PR
3. Watch GitHub Actions — CI should run on cloud, deploy on self-hosted
4. After deploy, you should hear the TTS notification
5. Verify job should check production health and homepage
6. If using Claude Code: CronCreate should detect the status changes

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
