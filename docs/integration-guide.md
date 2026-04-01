# Integration Guide

Step-by-step guide to integrate GitHub.Actions.Notify into any Olbrasoft project.

## Prerequisites

- VirtualAssistant running on `localhost:5055` with `ci-pipeline` agent type (AgentType ID 30)
- `gh` CLI authenticated
- sudo access for systemd service installation

## Step 1: Register Self-Hosted Runner

Run the setup script (one-time per repository):

```bash
cd ~/GitHub/Olbrasoft/GitHub.Actions.Notify
./scripts/setup-runner.sh Olbrasoft/<your-repo>
```

This will:
1. Download the latest GitHub Actions runner
2. Register it with your repository
3. Install it as a systemd service

Verify the runner is running:

```bash
sudo systemctl status actions.runner.Olbrasoft-<your-repo>.$(hostname)-<your-repo>.service
```

Also check: `https://github.com/Olbrasoft/<your-repo>/settings/actions/runners`

## Step 2: Add Notification Steps to CI Workflow

### Minimal — Deploy notification only

Add to the end of your deploy job (must run on `self-hosted`):

```yaml
  deploy:
    runs-on: self-hosted
    steps:
      # ... your existing deploy steps ...

      - name: Notify deploy result
        if: always()
        uses: Olbrasoft/GitHub.Actions.Notify/actions/deploy-status@main
        with:
          job-status: ${{ job.status }}
```

### Full — Deploy + production verification

Add a verify job after deploy:

```yaml
  verify:
    runs-on: self-hosted
    needs: [deploy]
    if: github.ref == 'refs/heads/main'
    steps:
      - name: Wait for deployment propagation
        run: sleep 10
      - uses: Olbrasoft/GitHub.Actions.Notify/actions/playwright-verify@main
        with:
          url: https://your-production-url.com
          checks: health,homepage
```

### CI stage notifications

Add to any CI job for per-stage notifications:

```yaml
  test:
    runs-on: self-hosted  # Must be self-hosted for localhost access
    steps:
      # ... your test steps ...
      - name: Notify test result
        if: always()
        uses: Olbrasoft/GitHub.Actions.Notify/actions/ci-status@main
        with:
          job-status: ${{ job.status }}
          stage: test
```

## Step 3: Add Claude Code Skill (Optional)

Link the CI workflow monitor skill to your project:

```bash
cd ~/GitHub/Olbrasoft/<your-repo>
mkdir -p .claude/skills
ln -s ~/GitHub/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor .claude/skills/ci-workflow-monitor
```

This enables Claude Code to autonomously monitor CI/CD pipeline status after creating PRs.

## Step 4: Update CLAUDE.md (Optional)

Add to your project's CLAUDE.md:

```markdown
## CI/CD Feedback

After creating a PR, use the `ci-workflow-monitor` skill to set up CronCreate polling.
Deploy and verify jobs run on self-hosted runner with TTS notifications via VirtualAssistant.
```

## Hybrid Runner Strategy

For projects with expensive CI (like Rust compilation):

| Job | Runner | Why |
|-----|--------|-----|
| check, fmt, test | `ubuntu-latest` | Free cloud CI, parallel execution |
| deploy | `self-hosted` | Access to VPS secrets, localhost notifications |
| verify | `self-hosted` | Local Playwright, localhost notifications |

For lightweight projects (.NET, Node.js), you can run everything on `self-hosted`.

## Troubleshooting

### Notification not arriving

1. Check VirtualAssistant is running: `curl http://localhost:5055/api/notifications -X POST -H "Content-Type: application/json" -d '{"text":"test","source":"ci-pipeline"}'`
2. Check the `ci-pipeline` agent type exists in VirtualAssistant database
3. Check runner can reach localhost: run `curl localhost:5055/health` on the runner

### Runner offline

```bash
sudo systemctl restart actions.runner.Olbrasoft-<repo>.<hostname>-<repo>.service
sudo journalctl -u actions.runner.Olbrasoft-<repo>.<hostname>-<repo>.service -f
```

### Playwright not available

```bash
npx playwright install chromium
```
