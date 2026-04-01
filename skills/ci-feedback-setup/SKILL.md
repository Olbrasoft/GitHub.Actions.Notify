---
name: ci-feedback-setup
description: Set up CI/CD feedback infrastructure for any Olbrasoft project. Registers self-hosted runner, modifies CI workflow, links monitoring skill. Use when starting work on a project that needs CI notifications and post-deploy verification.
---

# CI Feedback Setup

One-time setup skill that integrates CI/CD feedback into the current project. After running this skill, the project will have:
- TTS notifications from GitHub Actions (build, deploy, verify results)
- CronCreate-based pipeline monitoring via `ci-workflow-monitor` skill
- Post-deploy Playwright production verification

## Prerequisites

Before running this skill, ensure:
1. **VirtualAssistant** is running on `localhost:5055` with `ci-pipeline` agent type
2. **gh CLI** is authenticated (`gh auth status`)
3. **GitHub.Actions.Notify** repo is cloned at `~/GitHub/Olbrasoft/GitHub.Actions.Notify/`

## Setup Steps

### Step 1: Identify Project

Determine the current project:
```bash
# Get repo info
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
REPO_SHORT=$(basename "$PWD")
echo "Setting up CI feedback for: $REPO"
```

### Step 2: Check Existing Runner

```bash
# Check if self-hosted runner exists
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | "\(.name) \(.status)"'
```

If no runner exists, register one:
```bash
# Create runner directory
RUNNER_DIR="$HOME/actions-runner-${REPO_SHORT}"
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"

# Download runner
RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
curl -sL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" | tar xz

# Get token and configure
TOKEN=$(gh api "repos/${REPO}/actions/runners/registration-token" -X POST --jq '.token')
./config.sh --url "https://github.com/${REPO}" --token "$TOKEN" --name "$(hostname)-${REPO_SHORT}" --work "_work" --unattended

# Install as systemd service
sudo ./svc.sh install "$(whoami)"
sudo systemctl start "actions.runner.${REPO/\//-}.$(hostname)-${REPO_SHORT}.service"
```

### Step 3: Modify CI Workflow

Read the existing `.github/workflows/ci.yml` (or equivalent) and add:

**For the deploy job** (change `runs-on` to `self-hosted`):
```yaml
  deploy:
    runs-on: self-hosted  # Changed from ubuntu-latest
    # ... existing steps ...

    # ADD at the end:
    - name: Notify deploy result
      if: always()
      uses: Olbrasoft/GitHub.Actions.Notify/actions/deploy-status@main
      with:
        job-status: ${{ job.status }}
        repository: ${{ github.repository }}
```

**Add verify job** after deploy:
```yaml
  verify:
    name: Verify production
    runs-on: self-hosted
    needs: [deploy]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - name: Wait for deployment propagation
        run: sleep 10
      - name: Verify production
        uses: Olbrasoft/GitHub.Actions.Notify/actions/playwright-verify@main
        with:
          url: <PRODUCTION_URL>  # Replace with actual URL
          checks: health,homepage
```

**Important:** Identify the production URL from the project's CLAUDE.md, README, or configuration.

### Step 4: Link Monitoring Skill

```bash
# Create symlink to ci-workflow-monitor skill
mkdir -p .claude/skills
ln -sf ~/GitHub/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor .claude/skills/ci-workflow-monitor
echo "Skill linked: ci-workflow-monitor"
```

### Step 5: Update CLAUDE.md

Add the following section to the project's CLAUDE.md:

```markdown
## CI/CD Feedback

This project uses [GitHub.Actions.Notify](https://github.com/Olbrasoft/GitHub.Actions.Notify) for CI/CD feedback.

- **Deploy + Verify** jobs run on self-hosted runner with TTS notifications
- **CronCreate monitoring:** After creating a PR, use the `ci-workflow-monitor` skill
- **Production URL:** <URL>
```

### Step 6: Verify Setup

```bash
# Test notification endpoint
curl -s -X POST "http://localhost:5055/api/notifications" \
  -H "Content-Type: application/json" \
  -d '{"text":"CI feedback setup test pro '"${REPO_SHORT}"'","source":"ci-pipeline"}' \
  | jq .

# Verify runner is online
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | "\(.name): \(.status)"'

# Verify skill is linked
ls -la .claude/skills/ci-workflow-monitor
```

## Post-Setup Checklist

After running this skill, verify:
- [ ] Self-hosted runner is registered and online
- [ ] CI workflow has `deploy-status` notification step
- [ ] CI workflow has `verify` job with Playwright
- [ ] `ci-workflow-monitor` skill is linked in `.claude/skills/`
- [ ] CLAUDE.md updated with CI/CD feedback section
- [ ] Test notification received via TTS

## Project-Specific Adaptations

### Rust Projects (like cr)
- Keep build/test on `ubuntu-latest` (Rust compilation is CPU-heavy)
- Only deploy + verify on `self-hosted`

### .NET Projects
- Can run entire pipeline on `self-hosted` (fast builds)
- Or keep cloud runners for build/test

### Node.js / Frontend Projects
- Consider adding Playwright browser tests in verify job
- Use `npx playwright test` for comprehensive UI verification

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Runner not connecting | `sudo systemctl restart actions.runner.*.service` |
| Notification 400 error | Check VirtualAssistant has `ci-pipeline` agent type (ID 30) |
| Playwright not found | `npx playwright install chromium` |
| Deploy job can't reach VPS | Verify SSH secrets are set in repo settings |
