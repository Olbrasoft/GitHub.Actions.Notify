---
name: ci-workflow-monitor
description: Issue-driven autonomous CI/CD pipeline. From issue analysis through implementation, PR, CI, review, merge, deploy, to Playwright production verification of issue-specific changes. Handles parent issues with multiple sub-issues and parallel PRs. NEVER asks user — acts fully autonomously.
---

# CI Workflow Monitor — Issue-Driven Autonomous Pipeline

Fully autonomous issue-to-production pipeline. Given an issue (or parent issue with sub-issues), handles the entire lifecycle without asking the user anything.

## Critical Rules

1. **NEVER ask the user** — just act (merge, fix, verify, continue)
2. **NEVER send duplicate notifications** — only on state changes
3. **Issue-driven** — start from issue, verify issue-specific changes on production
4. **Pipeline processing** — never wait for review, continue with next issue
5. **Close issues** only after production verification confirms changes are visible
6. **NEVER say "issue done" after creating a PR** — issue is done ONLY after deploy + Playwright production verification confirms the changes are visible and working. Creating a PR is ~20% of the work.

## When Is an Issue "Done"?

An issue is complete ONLY when ALL of these are true:
- PR merged to main
- Deploy to production succeeded
- Playwright verified the **specific changes from the issue** are visible on production
- If the issue says "show photo gallery" → gallery must be visible on production
- If the issue says "fix breadcrumb" → breadcrumb must be correct on production

**NEVER close a GitHub issue (`gh issue close`) before Playwright production verification.** Closing = work is done and verified. If Playwright shows changes are NOT visible → fix, push, new PR, repeat the cycle.

**Notification and closing rules:**
| Event | What to say | Close issue? |
|---|---|---|
| PR created | "PR vytvořen, CI běží" | NO |
| CI passed | "CI prošlo, čekám na review" | NO |
| PR merged | "PR mergnut, sleduji deploy" | NO |
| Deploy done | "Deploy OK, ověřuji produkci" | NO |
| Production verified OK | "Issue #N hotová — [co ověřeno]" | **YES — now close** |
| Production verification FAILED | "Změny nefungují: [problém]. Opravuji." | NO — fix and retry |

## Workflow Overview

### Single Issue

```
Issue assigned
  └── Implement → commit → push → create PR
        ├── WAIT for code review push notification (asyncRewake hook)
        │     ├── review has comments → fix → push → wait for next review push
        │     └── review clean → MERGE
        ├── WAIT for deploy push notification (asyncRewake hook)
        │     ├── deploy failed → notify error
        │     └── deploy succeeded → verify production
        └── Verify production
              ├── Health + homepage check
              ├── Analyze issue → what changed?
              ├── Playwright: verify specific changes visible
              └── Notify result
```

**Push notifications arrive automatically** — no CronCreate polling needed:
- **Code review:** `gh webhook forward` service → `webhook-receiver.py` → event file + FIFO wake → correct Claude Code session wakes (routed by PR branch)
- **Deploy:** GitHub Actions writes event file + calls `wake-claude.sh` → ALL Claude Code sessions for the repo wake
- Claude Code wakes from idle state and reacts immediately
- Each session creates a FIFO pipe — zero CPU while waiting

### Parent Issue with Sub-Issues (Pipeline Processing)

Follows [Continuous PR Processing Workflow](~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/continuous-pr-processing-workflow.md):

```
Parent issue
  ├── List sub-issues: gh api graphql (query subIssues)
  ├── Group into logical parts (1-N issues per PR)
  ├── Identify dependencies between parts
  │
  ├── Part 1: Implement sub-issues → PR1
  │     └── WAIT for review + deploy push notifications
  │     └── IMMEDIATELY start Part 2 (don't wait!)
  │
  ├── Part 2: Implement sub-issues → PR2
  │     └── Check PR1 status → merge if ready
  │     └── WAIT for review + deploy push notifications
  │     └── Continue to Part 3
  │
  ├── Part N: Last sub-issues → PRN
  │     └── Check & merge all previous PRs
  │
  └── All PRs merged → deploy → verify ALL changes
        ├── For each sub-issue: verify its specific changes
        ├── Notify per-issue verification results
        └── Close sub-issues + parent issue
```

## DEPRECATED: CronCreate Prompt Templates

**CronCreate polling is NO LONGER USED.** Push notifications via asyncRewake hooks replaced it.
Code review and deploy events arrive automatically — no polling needed.

The templates below are kept only as historical reference. Do NOT use CronCreate for new work.

### Old CronCreate Prompt Template — Single Issue (DEPRECATED)

```
AUTONOMOUS issue-driven CI/CD monitor for {OWNER}/{REPO}.
Working on issue #{ISSUE_NUM}, PR #{PR_NUMBER}, branch {BRANCH}.

Act fully autonomously. NEVER ask the user. Only notify on STATE CHANGES.

## Phase 1: CI + Review (while PR is open)

1. Check PR state:
   gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json state --jq '.state'
   - "MERGED" → skip to Phase 2
   - "CLOSED" → notify "PR uzavřen" → CronDelete

2. Check CI:
   gh pr checks {PR_NUMBER} --repo {OWNER}/{REPO}
   - pending → "CI running" (once) → stop
   - fail → read logs: gh run list --repo {OWNER}/{REPO} --branch {BRANCH} --limit 1 --json databaseId --jq '.[0].databaseId'
     Then: gh run view <ID> --repo {OWNER}/{REPO} --log-failed 2>&1 | tail -50
     Analyze error. Fix code. Commit and push. Notify: "CI selhalo, opravuji: {error}"
   - all pass → step 3

3. Check review:
   gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json reviewDecision,reviews

   Branch protection requires CI checks (Check & Clippy, Format, Test).
   Copilot code review runs as "Agent" check-run — MUST wait for it before merging.

   **NEVER attempt merge before both CI and Copilot review are done.**

   a) Check Copilot review status (deterministicky přes API):
      HEAD=$(gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json headRefOid --jq '.headRefOid')
      AGENT_STATUS=$(gh api "repos/{OWNER}/{REPO}/commits/${HEAD}/check-runs" --jq '.check_runs[] | select(.name == "Agent") | .status' 2>/dev/null)

      - AGENT_STATUS is empty → Copilot not active/subscribed → skip review, go to step (c)
      - AGENT_STATUS is "in_progress" or "queued" → say "Waiting for Copilot review" → STOP
      - AGENT_STATUS is "completed" → go to step (b)

   b) Read and fix Copilot review comments:
      gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/comments --jq '.[].body'
      - Has actionable comments → fix ALL, commit, push. Notify: "Review komentáře opraveny."
        After push, new CI + review cycle starts → STOP, wait for next tick
      - No actionable comments → go to step (c)

   c) Merge:
      gh pr merge {PR_NUMBER} --repo {OWNER}/{REPO} --merge 2>&1
      - SUCCEEDS → Notify: "PR #{PR_NUMBER} mergnut (issue #{ISSUE_NUM}). Sleduji deploy."
      - FAILS → report error, STOP

## Phase 2: Deploy + Verify

4. Monitor deploy:
   gh run list --repo {OWNER}/{REPO} --branch main --limit 1 --json status,conclusion,databaseId
   - in_progress → "Deploy running" (once) → stop
   - failure → Notify: "Deploy selhal!" + read logs
   - success → step 5

5. Basic health check:
   curl -s -o /dev/null -w "%{{http_code}}" --max-time 10 {PRODUCTION_URL}/health
   curl -s -o /dev/null -w "%{{http_code}}" --max-time 10 {PRODUCTION_URL}/
   - not 200 → Notify: "Produkce neodpovídá!"
   - both 200 → step 6

6. Issue-specific verification (curl + Playwright):
   Read the issue to understand what changed:
   gh issue view {ISSUE_NUM} --repo {OWNER}/{REPO} --json title,body

   **Step A — curl checks** (quick, automated):
   - Verify new URLs return HTTP 200
   - Verify HTML contains expected src/alt/title attributes (grep)
   - Verify no old numeric-ID URLs remain in HTML

   **Step B — Playwright interactive end-to-end test** (MANDATORY, final check):

   Playwright runs from our LOCAL PC against production URL. NEVER install Playwright/Chromium on the server.

   Open the production page in Playwright and perform a FULL interactive test — not just a screenshot.
   The test must simulate what a real user would do:

   **For static pages (displaying data):**
   - Navigate to URL, wait for content to load
   - Verify expected elements are visible (images render, text correct, layout OK)
   - Take screenshot as proof

   **For interactive features (forms, buttons, downloads):**
   - Navigate to the page
   - Fill inputs with test data
   - Click buttons and wait for results
   - Verify the result is correct (preview appears, data loads, download starts)
   - Take screenshot at each step
   - Example: video download page → paste URL → click "Načíst info" → verify preview → click "Stáhnout" → verify download

   **For API features:**
   - First test API directly via curl (quick sanity check)
   - Then test the full user flow via Playwright UI

   Based on the issue description, verify specific changes:
   - New image/flag/coat → screenshot, confirm image visually renders
   - New page/route → navigate, screenshot, confirm it loads
   - UI change → screenshot, compare with expected result
   - Interactive feature → full user flow test (fill, click, verify result)
   - Bug fix → reproduce original scenario, screenshot, confirm fix
   - SEO change → check page source + visual appearance

   **MANDATORY: Test ALL UI elements on changed pages:**
   - Click every button and verify its effect
   - Toggle every switch and verify both states
   - Fill every input and verify validation
   - Check every link (href, target)
   - Disabled/non-functional controls must NOT be shown
   - Capture console errors: `page.on('console')` + `page.on('pageerror')` — must be ZERO

   If verification FAILS (broken image, missing content, wrong layout):
   - Notify: "Verifikace selhala: {what's wrong}. Opravuji."
   - Fix the issue, create new PR, restart pipeline
   - Do NOT close the issue

   If verification PASSES (both curl and visual):
   - Notify: "Issue #{ISSUE_NUM} ověřena na produkci: {what was confirmed}"
   - Then: "PIPELINE COMPLETE — run CronDelete."

Issue IDs for notifications: {ISSUE_IDS}
```

### Old CronCreate Prompt Template — Parent Issue (DEPRECATED)

```
AUTONOMOUS pipeline for parent issue #{PARENT_NUM} on {OWNER}/{REPO}.
Production URL: {PRODUCTION_URL}.

1. List sub-issues:
   PARENT_ID=$(gh issue view {PARENT_NUM} --repo {OWNER}/{REPO} --json id --jq '.id')
   gh api graphql -f query="query {{ node(id: \"$PARENT_ID\") {{ ... on Issue {{ subIssues(first: 50) {{ nodes {{ number title state }} }} }} }} }}" --jq '.data.node.subIssues.nodes[]'

2. Check which sub-issues are still open.
   For each open sub-issue: check if there's already a PR or branch.

3. Track PRs:
   gh pr list --repo {OWNER}/{REPO} --state open --json number,title,headRefName
   Match PRs to sub-issues by branch name or title.

4. For each PR:
   - Check CI + review status (same as single issue Phase 1)
   - If ready → merge
   - Continue to next sub-issue

5. When ALL sub-issues are closed and all PRs merged:
   - Monitor final deploy
   - Verify ALL changes on production (per sub-issue)
   - Notify: "Parent issue #{PARENT_NUM} kompletní. Všechny sub-issues ověřeny."
   - CronDelete
```

## Key Commands Reference

```bash
# List sub-issues of parent
PARENT_ID=$(gh issue view <NUM> --repo <REPO> --json id --jq '.id')
gh api graphql -f query="query { node(id: \"$PARENT_ID\") { ... on Issue { subIssues(first: 50) { nodes { number title state } } } } }"

# CI status
gh pr checks <PR> --repo <REPO>

# PR state and review
gh pr view <PR> --repo <REPO> --json state,reviewDecision,reviews

# Failed CI logs
gh run view <RUN_ID> --repo <REPO> --log-failed 2>&1 | tail -50

# Review comments (inline)
gh api repos/<OWNER>/<REPO>/pulls/<PR>/comments --jq '.[].body'

# Merge
gh pr merge <PR> --repo <REPO> --merge

# Deploy status
gh run list --repo <REPO> --branch main --limit 1 --json status,conclusion,databaseId

# Issue details (for verification)
gh issue view <NUM> --repo <REPO> --json title,body

# Production checks
curl -s -o /dev/null -w "%{http_code}" <URL>/health
curl -s -o /dev/null -w "%{http_code}" <URL>/
```

## FIFO-Based Push Wake Notifications

Push notifications arrive automatically via FIFO pipes. **No CronCreate polling needed. No inotifywait. No flock.**

### Architecture
```
Webhook arrives → webhook-receiver.py → writes event file + writes to FIFO → Claude Code wakes
Deploy completes → GitHub Actions → writes event file + calls wake-claude.sh → Claude Code wakes
```

Each Claude Code session creates a FIFO pipe at `/tmp/claude-wake/{REPO}/{PID}.fifo` and blocks on `read` — zero CPU. External processes write to the FIFO to wake the session.

### Deploy Notification
GitHub Actions writes event file after deploy → calls `wake-claude.sh` → wakes ALL Claude Code sessions for the repo.

### Code Review Notification
`gh webhook forward` service receives `pull_request_review` events via WebSocket → `webhook-receiver.py` writes event file → calls `wake-claude.sh` with branch parameter → wakes ONLY the session working on that PR's branch.

### Event Routing
- **Code review:** Routed by PR branch name. Session on `feat/xyz` gets woken only for reviews of `feat/xyz`.
- **Deploy:** ALL sessions for the repo. Deploy affects everyone.

### How to react to push events

When Claude Code wakes from FIFO push, `wake-on-event.sh` reads event files and outputs instructions via stderr. React based on event type:

| Event | Status | Action |
|---|---|---|
| `code-review-complete` | `commented` | Read comments: `gh api repos/{REPO}/pulls/{PR}/comments --jq '.[].body'`. Fix ALL issues. Push. |
| `deploy-complete` | `success` | Verify: `curl <url>/health`. Run Playwright verification. Notify user via `mcp__notify__notify`. |
| `deploy-complete` | `failure` | Check `failedStep` field (see below). Read logs, fix, push. Notify user. |
| `deploy-complete` | `cancelled` | Notify user: "Deploy zrušen." Investigate and re-run if needed. |
| `verify-complete` | `success` | Production verified by CI. Run issue-specific Playwright test. Close issue if OK. |
| `verify-complete` | `failure` | Notify user. Investigate and fix. |
| `verify-complete` | `cancelled` | Notify user: "Verifikace zrušena." Investigate and re-run if needed. |

### Deploy failure — failedStep detection

When `deploy-complete` has `status: failure`, the `failedStep` field tells you which step failed:

| failedStep | Meaning | How to fix |
|---|---|---|
| `validate` | Missing secrets (VPS_HOST, VPS_SSH_KEY, VPS_SSH_PORT) | Check repository secrets in GitHub Settings |
| `sync` | rsync to VPS failed (network, SSH, disk space) | Check VPS connectivity: `ssh -p 2222 root@<VPS_HOST> echo ok` |
| `build-restart` | Docker build or restart failed on VPS | Read logs: `gh run view <ID> --log-failed`. SSH to VPS and check: `docker compose logs web` |
| `health-check` | Health check failed after deploy (public URL not responding) | Check: `curl https://ceskarepublika.wiki/health`. SSH to VPS: `docker compose logs web` |
| (empty) | No specific step detected as failed | Read full job logs: `gh run view <ID> --log-failed` |

### After deploy-complete/success:

1. Verify production: `curl -s -o /dev/null -w "%{http_code}" <PRODUCTION_URL>/health`
2. Run issue-specific Playwright verification
3. Notify user via `mcp__notify__notify`: "Issue #N ověřena na produkci: [details]"
4. Close issue if verification passed

### Infrastructure (global, already configured)

- `~/.claude/hooks/wake-on-event.sh` — FIFO-based asyncRewake hook (creates FIFO, blocks on read, processes events)
- `~/.claude/hooks/wake-claude.sh` — Wake script (finds matching FIFOs by repo/branch, writes to them)
- `~/.claude/hooks/check-deploy-status.sh` — UserPromptSubmit fallback reader
- `~/.claude/hooks/webhook-receiver.py` — HTTP server on port 9877 (parses webhooks, writes events, calls wake-claude.sh)
- `~/.config/claude-channels/deploy-events/` — event files directory
- `/tmp/claude-wake/{REPO}/` — FIFO pipes and session registrations
- `gh-webhook-forward.service` — systemd service forwarding webhooks for all Olbrasoft repos

## State Machine

| State | Trigger | Autonomous Action |
|---|---|---|
| ISSUE_ASSIGNED | start | Implement, create branch, commit, push, create PR |
| CI_PENDING | — | Silent wait (CI runs on GitHub cloud) |
| CI_FAILED | — | Analyze logs → fix → push |
| CI_PASSED | — | Wait for review push notification |
| REVIEW_COMPLETE | push (asyncRewake) | Read comments, fix if any → merge |
| PR_MERGED | — | Wait for deploy push notification |
| DEPLOY_COMPLETE | push (asyncRewake) | Verify production (health + Playwright) |
| DEPLOY_FAILED | push (asyncRewake) | Notify error |
| VERIFIED | after Playwright | Notify per-issue results → close issue |

## Server / Docker Rules

- Docker image MUST be minimal — only production binary + static assets + data
- NEVER install testing tools (Playwright, Chromium, Selenium) in Docker image
- NEVER install Python or pip in Docker image unless required by production code (e.g., yt-dlp)
- All Playwright testing runs from the local development PC against the production URL
- If a feature needs a subprocess tool (e.g., yt-dlp), that is a PRODUCTION dependency — OK to install
- If a tool is only for testing — it stays on the local PC, NOT in Docker

## Anti-Patterns

| Wrong | Right |
|---|---|
| "Chceš mergovat?" | Just merge it |
| "CI prošlo" (every poll) | Only notify on state change |
| Waiting for review | Continue with next sub-issue |
| Generic health check only | Verify issue-specific changes on production |
| Closing issue before verification | First verify on production, then close |
| One PR for entire parent issue | Split into logical parts, one PR per group |
| Playwright screenshot only | Full interactive test (fill, click, verify) |
| Installing Playwright in Docker | Playwright runs from local PC only |
| curl test = done | curl + full Playwright interactive test = done |

## Integration

This skill works with:
- [Continuous PR Processing](~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/continuous-pr-processing-workflow.md) — pipeline pattern for parent issues
- [GitHub Issues](github-issues skill) — issue creation with proper GraphQL sub-issue linking
- [Git Workflow](~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/git-workflow-workflow.md) — branch naming, commits
