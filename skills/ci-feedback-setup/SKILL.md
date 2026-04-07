---
name: ci-feedback-setup
description: Set up FIFO-based push wake CI/CD feedback for any Olbrasoft project. Adds deploy/verify event notifications, code review webhooks, and autonomous pipeline monitoring. Use when user says "nastav FIFO wake", "nastav CI feedback", or when starting work on a project that needs CI notifications.
---

# CI Feedback Setup — FIFO-Based Push Wake

One-time setup skill that integrates FIFO-based push wake CI/CD feedback into the current project. After running this skill, the project will have:
- **FIFO push wake** — Claude Code wakes instantly when deploy completes or Copilot reviews a PR
- **Deploy failure detection** — `failedStep` field identifies which step failed
- **Post-deploy Playwright verification** — automated production verification
- **TTS notifications** — user hears results via VirtualAssistant voice output

## How It Works

```
Deploy completes → GitHub Actions writes event file + calls wake-claude.sh → FIFO wakes Claude Code
Copilot reviews PR → gh webhook forward → webhook-receiver.py → FIFO wakes correct session (by branch)
```

Each Claude Code session creates a FIFO pipe at `/tmp/claude-wake/{REPO}/{PID}.fifo`. External processes write event data through the FIFO to wake the session. Zero CPU while waiting.

## Prerequisites — Install Hooks On This Machine

The hook scripts (FIFO consumer, wake script, webhook receiver, fallback reader) live in this repo under `hooks/` and are installed into `~/.claude/hooks/` by the install script. **Run this once per developer machine** (not per project):

```bash
cd ~/Olbrasoft/GitHub.Actions.Notify  # or wherever you cloned this repo
./hooks/install.sh
```

Verify the install:

```bash
# Drift check — should report no diff between repo and ~/.claude/hooks/
./hooks/install.sh --check

# Verify webhook forward service is running (one-time systemd setup)
systemctl --user status gh-webhook-forward.service
```

If `gh-webhook-forward.service` does not exist, see `docs/integration-guide.md` for the systemd unit setup. If `~/.claude/settings.json` does not register `wake-on-event.sh` as an asyncRewake hook, the install script will print the snippet you need to add.

## Setup Steps (Per-Project)

### Step 1: Identify Project

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
REPO_SHORT=$(basename "$PWD")
echo "Setting up FIFO wake CI feedback for: $REPO"
```

### Step 2: Add Repo to Webhook Forwards (Code Review Notifications)

Check if the repo is already in `~/.claude/hooks/start-webhook-forwards.sh`:

```bash
grep "$REPO" ~/.claude/hooks/start-webhook-forwards.sh
```

If NOT found, add it to the `REPOS` array:

```bash
# Edit ~/.claude/hooks/start-webhook-forwards.sh
# Add the repo to the REPOS array, e.g.:
#   "Olbrasoft/NewProject"

# Then restart the service to pick up the change:
systemctl --user restart gh-webhook-forward.service
```

**Why:** `gh webhook forward` receives Copilot code review events via WebSocket. Without this, code review FIFO wake won't work for this repo. Deploy FIFO wake works regardless (it runs on the self-hosted runner).

### Step 3: Ensure Self-Hosted Runner Exists

```bash
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | "\(.name) \(.status)"'
```

If no runner exists, register one:

```bash
RUNNER_DIR="$HOME/actions-runner-${REPO_SHORT}"
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"

RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
curl -sL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" | tar xz

TOKEN=$(gh api "repos/${REPO}/actions/runners/registration-token" -X POST --jq '.token')
./config.sh --url "https://github.com/${REPO}" --token "$TOKEN" --name "$(hostname)-${REPO_SHORT}" --work "_work" --unattended

sudo ./svc.sh install "$(whoami)"
sudo systemctl start "actions.runner.${REPO/\//-}.$(hostname)-${REPO_SHORT}.service"
```

### Step 4: Add Deploy Event + FIFO Wake to CI Workflow

Read the existing `.github/workflows/ci.yml` (or deploy workflow). The deploy job MUST run on `self-hosted`.

**Add at the end of the deploy job** (after all deploy steps):

```yaml
    - name: Write deploy event for Claude Code
      if: always()
      continue-on-error: true
      shell: bash
      run: |
        EVENTS_DIR="$HOME/.config/claude-channels/deploy-events"
        mkdir -p "$EVENTS_DIR"
        REPO_FILE="${GITHUB_REPOSITORY//\//-}"
        COMMIT_SHA="${GITHUB_SHA:0:7}"
        # RUN_ID + RUN_ATTEMPT ensure filename uniqueness even for re-runs
        # and workflow_dispatch of the same commit (COMMIT_SHA alone is not
        # enough — re-runs of the same SHA would otherwise collide).

        # Detect which step failed — customize these step IDs for this project!
        FAILED_STEP=""
        # if [ "${{ steps.build.outcome }}" = "failure" ]; then FAILED_STEP="build"; fi
        # if [ "${{ steps.test.outcome }}" = "failure" ]; then FAILED_STEP="test"; fi
        # if [ "${{ steps.deploy.outcome }}" = "failure" ]; then FAILED_STEP="deploy"; fi
        # if [ "${{ steps.health.outcome }}" = "failure" ]; then FAILED_STEP="health"; fi

        if command -v jq >/dev/null 2>&1; then
          jq -n \
            --arg event "deploy-complete" \
            --arg status "${{ job.status }}" \
            --arg failedStep "$FAILED_STEP" \
            --arg repository "${{ github.repository }}" \
            --arg commit "$COMMIT_SHA" \
            --arg commitMessage "$(git log -1 --pretty=%s 2>/dev/null || echo unknown)" \
            --arg runUrl "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
            --arg environment "production" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{event: $event, status: $status, failedStep: $failedStep, repository: $repository, commit: $commit, commitMessage: $commitMessage, runUrl: $runUrl, environment: $environment, timestamp: $timestamp}' \
            > "$EVENTS_DIR/${REPO_FILE}-deploy-${COMMIT_SHA}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.json"

          # Wake ALL Claude Code sessions for this repo via FIFO. wake-claude.sh
          # uses ack semantics: it deletes the event file ONLY after a live
          # consumer has positively read it. If no session is alive at this
          # moment, the file persists and will be picked up by
          # check-deploy-status.sh on the next UserPromptSubmit. Two concurrent
          # deploys cannot collide because the filename includes the commit SHA.
          WAKE_SCRIPT="$HOME/.claude/hooks/wake-claude.sh"
          if [ -x "$WAKE_SCRIPT" ]; then
            "$WAKE_SCRIPT" "${GITHUB_REPOSITORY}" || true
          else
            echo "Claude wake script not found: $WAKE_SCRIPT" >&2
          fi
        else
          echo "jq not installed; skipping deploy event write." >&2
        fi
```

**IMPORTANT:** Customize the `FAILED_STEP` detection — uncomment and adjust the step IDs to match this project's actual deploy steps. Look at existing step `id:` fields in the workflow.

### Step 5: Add Verify Job (After Deploy)

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
          COMMIT_SHA="${GITHUB_SHA:0:7}"
          # RUN_ID + RUN_ATTEMPT ensure filename uniqueness across re-runs.

          if command -v jq >/dev/null 2>&1; then
            jq -n \
              --arg event "verify-complete" \
              --arg status "${{ job.status }}" \
              --arg repository "${{ github.repository }}" \
              --arg commit "$COMMIT_SHA" \
              --arg environment "production" \
              --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '{event: $event, status: $status, repository: $repository, commit: $commit, environment: $environment, timestamp: $timestamp}' \
              > "$EVENTS_DIR/${REPO_FILE}-verify-${COMMIT_SHA}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.json"

            WAKE_SCRIPT="$HOME/.claude/hooks/wake-claude.sh"
            if [ -x "$WAKE_SCRIPT" ]; then
              "$WAKE_SCRIPT" "${GITHUB_REPOSITORY}" || true
            else
              echo "Claude wake script not found: $WAKE_SCRIPT" >&2
            fi
          else
            echo "jq not installed; skipping verify event write." >&2
          fi
```

**Replace `<PRODUCTION_URL>`** with the actual production URL from the project's CLAUDE.md or README.

### Step 6: Link Monitoring Skill

```bash
mkdir -p .claude/skills
ln -sf ~/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor .claude/skills/ci-workflow-monitor
echo "Skill linked: ci-workflow-monitor"
```

### Step 7: Update Project CLAUDE.md

Add to the project's CLAUDE.md:

```markdown
## CI/CD Feedback (FIFO-Based Push Wake)

This project uses FIFO-based push wake for CI/CD notifications.

- **Deploy + Verify** jobs run on self-hosted runner, write event files + call `wake-claude.sh`
- **Code review** events arrive via `gh webhook forward` + `webhook-receiver.py`
- **Push notifications** wake Claude Code instantly via FIFO pipes — no polling
- **Production URL:** <URL>

See `ci-workflow-monitor` skill for event handling details.
```

### Step 8: Verify Setup

```bash
# 1. Verify runner is online
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | "\(.name): \(.status)"'

# 2. Verify skill is linked
ls -la .claude/skills/ci-workflow-monitor/SKILL.md

# 3. Verify repo is in webhook forwards
grep "$REPO" ~/.claude/hooks/start-webhook-forwards.sh

# 4. Verify webhook forward service is running
systemctl --user status gh-webhook-forward.service --no-pager | head -3

# 5. Verify FIFO hooks are executable
ls -x ~/.claude/hooks/wake-on-event.sh ~/.claude/hooks/wake-claude.sh

# 6. Test TTS notification endpoint (optional)
curl -s -X POST "http://localhost:5055/api/notifications" \
  -H "Content-Type: application/json" \
  -d '{"text":"CI feedback setup test pro '"${REPO_SHORT}"'","source":"ci-pipeline"}' \
  | jq .
```

## Post-Setup Checklist

- [ ] Self-hosted runner registered and online
- [ ] Repo added to `~/.claude/hooks/start-webhook-forwards.sh`
- [ ] `gh-webhook-forward.service` restarted (if repo was added)
- [ ] CI workflow: deploy event write + `wake-claude.sh` call added
- [ ] CI workflow: verify job with Playwright + verify event write added
- [ ] `failedStep` detection customized for project's deploy steps
- [ ] `ci-workflow-monitor` skill linked in `.claude/skills/`
- [ ] CLAUDE.md updated with CI/CD feedback section
- [ ] Production URL set correctly in verify job

## Project-Specific Adaptations

### Rust Projects (like cr)
- Keep build/test on `ubuntu-latest` (Rust compilation is CPU-heavy)
- Only deploy + verify on `self-hosted`
- failedStep IDs: `validate`, `sync`, `build-restart`, `health-check`

### .NET Projects (like VirtualAssistant)
- Can run entire pipeline on `self-hosted` (fast builds)
- failedStep IDs: `restore`, `build`, `test`, `publish`, `copy-assets`, `restart`, `health`

### Node.js / Frontend Projects
- Consider adding Playwright browser tests in verify job
- Use `npx playwright test` for comprehensive UI verification

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Code review FIFO wake not working | Check repo is in `start-webhook-forwards.sh` and service restarted |
| Deploy FIFO wake not working | Check `wake-claude.sh` call is in CI workflow, inside `jq` block |
| Runner not connecting | `sudo systemctl restart actions.runner.*.service` |
| FIFO registration not created | Session must be started from project directory (not `~`) |
| Event file not written | Check `jq` is installed on runner: `command -v jq` |
| Multiple sessions, only one gets event | Verify `wake-claude.sh` sends data THROUGH FIFO (not just "wake") |
| TTS notification 400 error | Check VirtualAssistant has `ci-pipeline` agent type (ID 30) |
| Playwright not found | `npx playwright install chromium` (local PC only, never server) |
| Deploy job can't reach VPS | Verify SSH secrets are set in repo settings |
