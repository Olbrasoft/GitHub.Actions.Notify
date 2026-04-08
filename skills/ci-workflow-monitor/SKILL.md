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
7. **Copilot reviews each PR ONCE — but human reviewers may re-review.** This rule applies SPECIFICALLY to the GitHub Copilot review bot (`copilot-pull-request-reviewer`), not to all reviewers. After addressing Copilot's comments and pushing the fix commits, MERGE THE PR DIRECTLY — there is no automatic re-review from Copilot, and waiting for a second wake event from Copilot will hang the session forever. Source of truth: `~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/continuous-pr-processing-workflow.md` ("no re-review after fixes"). If you ever genuinely want a fresh Copilot pass after pushing fixes, you must explicitly re-request the review via `gh api repos/<OWNER>/<REPO>/pulls/<N>/requested_reviewers -X POST -f reviewers='["Copilot"]'`. Default flow does NOT do this — it just merges.<br/><br/>**Human reviewers** are different: a human may push back after a fix push and submit another review on the same PR. For human-authored reviews (`reviewer` is NOT `copilot-pull-request-reviewer*`), do not assume "merge directly" — verify whether the human is satisfied (e.g. a follow-up `APPROVED` review) before merging, or merge only if you are confident the comments are addressed and no re-review was requested.

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
        │     ├── Copilot review with comments → fix → push → MERGE
        │     │     (Copilot reviews each PR ONCE — no re-review fires
        │     │      automatically on push. Do NOT wait passively after
        │     │      pushing fixes; merge directly. See ~/GitHub/Olbrasoft/
        │     │      engineering-handbook/development-guidelines/workflow/
        │     │      continuous-pr-processing-workflow.md "no re-review
        │     │      after fixes". Critical Rule #7.)
        │     ├── Human review with comments → fix → push → verify
        │     │     reviewer is satisfied before merging (humans may
        │     │      re-review unlike Copilot)
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

**Push notifications arrive automatically** — no polling needed:
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

## Legacy polling templates removed

Earlier versions of this skill shipped prompt templates that asked Claude
Code to poll PR/CI/review/deploy state every two minutes via repeated
`gh pr checks` calls. That polling mechanism has been completely replaced
by FIFO-based push wake (see the "FIFO-Based Push Wake Notifications"
section below). The templates were removed in PR #22 to avoid confusing
future readers; the git history retains them if anyone needs to
reconstruct the old flow.

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

Push notifications arrive automatically via FIFO pipes. **No polling. No inotifywait. No flock.**

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

The state machine is split into TWO phases by Copilot's review:

**Phase A — initial commit, awaiting first Copilot review:**

| State | Trigger | Autonomous Action |
|---|---|---|
| ISSUE_ASSIGNED | start | Implement, create branch, commit, push, create PR |
| CI_PENDING | — | Silent wait (CI runs on GitHub cloud) |
| CI_FAILED | — | Analyze logs → fix → push (still in Phase A — back to CI_PENDING) |
| CI_PASSED_AWAITING_REVIEW | — | Wait for `code-review-complete` push notification |
| REVIEW_COMPLETE | push (asyncRewake) | Read comments, fix if any → push fixes → **transition to Phase B** |

**Phase B — fix push after first Copilot review, NO second review will fire:**

| State | Trigger | Autonomous Action |
|---|---|---|
| AWAITING_FIX_CI | — | Wait for `ci-complete` push notification on the fix commit |
| FIX_CI_FAILED | push (asyncRewake) | Read failed logs, fix more, push (still Phase B — back to AWAITING_FIX_CI) |
| FIX_CI_PASSED | push (asyncRewake) | **MERGE IMMEDIATELY** — Copilot reviews each PR EXACTLY ONCE, Critical Rule #7 applies. Do NOT mention "waiting for Copilot review" in notifications. Do NOT enter CI_PASSED_AWAITING_REVIEW again. |
| PR_MERGED | — | Wait for deploy push notification |

**Phase C — post-merge:**

| State | Trigger | Autonomous Action |
|---|---|---|
| DEPLOY_COMPLETE | push (asyncRewake) | Verify production (health + Playwright) |
| DEPLOY_FAILED | push (asyncRewake) | Notify error |
| VERIFIED | after Playwright | Notify per-issue results → close issue |

**Key invariant:** Phase B is NEVER re-entered if Copilot has already reviewed once. Once you have pushed a fix in response to Copilot, the next `ci-complete success` event always means MERGE. Notifications during Phase B must NOT include the phrase "čekám na Copilot review" / "waiting for Copilot review" — the only thing being waited on in Phase B is CI on the fix commit.

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
