---
name: ci-feedback-setup
description: Set up CI/CD feedback infrastructure for any Olbrasoft project. Registers self-hosted runner, modifies CI workflow, links monitoring skill. Use when starting work on a project that needs CI notifications and post-deploy verification.
---

# CI Feedback Setup

One-time setup skill that integrates CI/CD feedback into the current project. After running this skill, the project will have:
- TTS notifications from GitHub Actions (build, deploy, verify results)
- FIFO-based push wake notifications via `ci-workflow-monitor` skill
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

    # ADD: Write deploy event file + wake Claude Code via FIFO
    - name: Write deploy event for Claude Code
      if: always()
      continue-on-error: true
      shell: bash
      run: |
        EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"
        mkdir -p "$EVENTS_DIR"
        REPO_FILE="${GITHUB_REPOSITORY//\//-}"
        
        FAILED_STEP=""
        # Add step failure detection here based on project's deploy steps
        
        if command -v jq >/dev/null 2>&1; then
          jq -n \
            --arg event "deploy-complete" \
            --arg status "${{ job.status }}" \
            --arg failedStep "$FAILED_STEP" \
            --arg repository "${{ github.repository }}" \
            --arg commit "${GITHUB_SHA:0:7}" \
            --arg runUrl "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
            --arg environment "production" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{event: $event, status: $status, failedStep: $failedStep, repository: $repository, commit: $commit, runUrl: $runUrl, environment: $environment, timestamp: $timestamp}' \
            > "$EVENTS_DIR/${REPO_FILE}.json"
        fi
        
        # Wake ALL Claude Code sessions for this repo via FIFO
        WAKE_SCRIPT="$HOME/.claude/hooks/wake-claude.sh"
        if [ -x "$WAKE_SCRIPT" ]; then
          "$WAKE_SCRIPT" "${GITHUB_REPOSITORY}" || true
        fi
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
        uses: Olbrasoft/GitHub.Actions.Notify/actions/playwright-verify@v1
        with:
          url: <PRODUCTION_URL>  # Replace with actual URL
          checks: health,homepage
          repository: ${{ github.repository }}
          send-notification: 'false'
      - name: Write verify event for Claude Code
        if: always()
        continue-on-error: true
        shell: bash
        run: |
          EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"
          mkdir -p "$EVENTS_DIR"
          REPO_FILE="${GITHUB_REPOSITORY//\//-}"
          
          if command -v jq >/dev/null 2>&1; then
            jq -n \
              --arg event "verify-complete" \
              --arg status "${{ job.status }}" \
              --arg repository "${{ github.repository }}" \
              --arg commit "${GITHUB_SHA:0:7}" \
              --arg environment "production" \
              --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '{event: $event, status: $status, repository: $repository, commit: $commit, environment: $environment, timestamp: $timestamp}' \
              > "$EVENTS_DIR/${REPO_FILE}-verify.json"
          fi
          
          # Wake ALL Claude Code sessions for this repo via FIFO
          WAKE_SCRIPT="$HOME/.claude/hooks/wake-claude.sh"
          if [ -x "$WAKE_SCRIPT" ]; then
            "$WAKE_SCRIPT" "${GITHUB_REPOSITORY}" || true
          fi
```

**Important:** Identify the production URL from the project's CLAUDE.md, README, or configuration.

### Step 4: Link Monitoring Skill

```bash
# Create symlink to ci-workflow-monitor skill
mkdir -p .claude/skills
ln -sf ~/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor .claude/skills/ci-workflow-monitor
echo "Skill linked: ci-workflow-monitor"
```

### Step 5: Update CLAUDE.md

Add the following section to the project's CLAUDE.md:

```markdown
## CI/CD Feedback (FIFO-Based Push Wake)

This project uses FIFO-based push wake for CI/CD notifications.

- **Deploy + Verify** jobs run on self-hosted runner, write event files + call `wake-claude.sh`
- **Code review** events arrive via `gh webhook forward` + `webhook-receiver.py`
- **Push notifications** wake Claude Code instantly via FIFO pipes — no polling
- **Production URL:** <URL>

See `ci-workflow-monitor` skill for event handling details.
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
- [ ] CI workflow has deploy event file write + `wake-claude.sh` call
- [ ] CI workflow has `verify` job with Playwright + verify event write + `wake-claude.sh` call
- [ ] `ci-workflow-monitor` skill is linked in `.claude/skills/`
- [ ] CLAUDE.md updated with CI/CD feedback section
- [ ] `wake-on-event.sh` and `wake-claude.sh` are in `~/.claude/hooks/` and executable
- [ ] `gh-webhook-forward.service` is running (for code review notifications)

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
