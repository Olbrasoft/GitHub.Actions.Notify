---
name: ci-workflow-monitor
description: Fully autonomous CI/CD pipeline monitor. After PR creation, polls CI, review, deploy, and production verification — acts on each state change without asking. Use after creating a PR to avoid blocking on GitHub Actions.
---

# CI Workflow Monitor

Fully autonomous CI/CD pipeline monitoring for Claude Code. After creating a PR, this sets up a CronCreate monitor that **acts on every state change without asking the user**.

## Critical Rules

1. **NEVER ask the user** "should I merge?", "should I fix?" — just do it
2. **NEVER send duplicate notifications** — only notify on STATE CHANGES
3. **Act immediately** on each event — fix errors, merge PRs, verify production
4. **Delete cron** when pipeline is complete

## Workflow — Fully Autonomous

```
PR Created → CronCreate (every 2 min)
  │
  ├─ CI pending → do nothing (no notification)
  │
  ├─ CI FAILED → analyze error log → fix code → commit → push
  │   └─ notify: "CI selhalo: {error}. Opravuji."
  │
  ├─ CI PASSED, review pending → do nothing (no notification)
  │
  ├─ CI PASSED, review COMMENTED/APPROVED →
  │   ├─ Has review comments? → read comments → fix → push
  │   │   └─ notify: "Review komentáře opraveny."
  │   └─ No actionable comments? → MERGE PR immediately
  │       └─ notify: "PR mergnut. Sleduji deploy."
  │
  ├─ PR MERGED, deploy running → do nothing (no notification)
  │
  ├─ DEPLOY SUCCEEDED → verify production (curl health + homepage)
  │   └─ notify: "Deploy OK. Produkce ověřena."
  │
  ├─ DEPLOY FAILED → notify: "Deploy selhal! {details}"
  │
  └─ PRODUCTION VERIFIED → CronDelete
      └─ notify: "Pipeline kompletní."
```

## CronCreate Prompt Template

Replace `{PR_NUMBER}`, `{OWNER}/{REPO}`, `{PRODUCTION_URL}`, and `{ISSUE_IDS}` with actual values.

```
AUTONOMOUS CI/CD pipeline monitor for {OWNER}/{REPO} PR #{PR_NUMBER}.

Act fully autonomously. NEVER ask the user anything. Only notify on STATE CHANGES — no duplicate notifications.

Track state internally. States: CI_PENDING → CI_PASSED → REVIEW_PENDING → REVIEW_DONE → MERGING → DEPLOY_RUNNING → DEPLOY_DONE → VERIFIED → COMPLETE

## Phase 1: CI + Review (while PR is open)

1. gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json state --jq '.state'
   - If "MERGED" → skip to Phase 2
   - If "CLOSED" → notify "PR uzavřen" → CronDelete → done

2. gh pr checks {PR_NUMBER} --repo {OWNER}/{REPO}
   - If any "pending"/"in_progress" → say "CI running" (only once) → stop
   - If any "fail" →
     gh run list --repo {OWNER}/{REPO} --branch {BRANCH} --limit 1 --json databaseId --jq '.[0].databaseId'
     Then: gh run view <ID> --repo {OWNER}/{REPO} --log-failed 2>&1 | tail -50
     Analyze the error. Fix the code. Commit and push.
     Notify: "CI selhalo pro PR #{PR_NUMBER}. Opravuji: {brief_error}."
   - If all "pass" → proceed to step 3

3. gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json reviewDecision,reviews
   gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/comments --jq '.[].body'
   - If review comments exist with actionable feedback → fix code, commit, push
     Notify: "Opravuji review komentáře pro PR #{PR_NUMBER}."
   - If no actionable comments or review approved →
     gh pr merge {PR_NUMBER} --repo {OWNER}/{REPO} --merge
     Notify: "PR #{PR_NUMBER} mergnut. Sleduji deploy na produkci."

## Phase 2: Deploy + Verify (after merge)

4. gh run list --repo {OWNER}/{REPO} --branch main --limit 1 --json status,conclusion,databaseId
   - If status "in_progress"/"queued" → say "Deploy running" (only once) → stop
   - If conclusion "failure" →
     Notify: "Deploy {REPO} na produkci selhal!"
     gh run view <ID> --repo {OWNER}/{REPO} --log-failed 2>&1 | tail -30
     Report error details.
   - If conclusion "success" → proceed to step 5

5. Verify production — basic health:
   HEALTH=$(curl -s -o /dev/null -w "%{{http_code}}" --max-time 10 {PRODUCTION_URL}/health)
   HOME=$(curl -s -o /dev/null -w "%{{http_code}}" --max-time 10 {PRODUCTION_URL}/)
   - If not 200 → Notify: "Produkce neodpovídá! Health: $HEALTH, Homepage: $HOME" → stop
   - If both 200 → proceed to step 6

6. Verify production — issue-specific changes:
   Read the PR and linked issues to understand WHAT changed:
   gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json body,title,closedIssues
   For each linked issue: gh issue view <ISSUE_NUM> --repo {OWNER}/{REPO} --json title,body

   Analyze what the issues describe (new feature, bug fix, UI change, etc.).
   Then use Playwright MCP or curl to verify the specific changes are visible on production:
   - If the issue added a new page/route → navigate to it, verify it loads
   - If the issue changed UI elements → take a screenshot, verify the change
   - If the issue fixed a bug → reproduce the original scenario, verify it's fixed
   - If the issue changed data/content → verify the content is correct

   Report findings for each issue. Notify:
   "Deploy {REPO} kompletní. Ověřeno: [issue descriptions and verification results]."
   Say: "PIPELINE COMPLETE — run CronDelete to stop this monitor."

Issue IDs for notifications: {ISSUE_IDS}
```

## CronCreate Parameters

```javascript
CronCreate({
  cron: "*/2 * * * *",   // Every 2 minutes
  prompt: "...",          // Use template above with filled values
  recurring: true
})
```

## Key Commands Reference

```bash
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

# Latest main workflow run
gh run list --repo <REPO> --branch main --limit 1 --json status,conclusion,databaseId

# Production verification
curl -s -o /dev/null -w "%{http_code}" <URL>/health
curl -s -o /dev/null -w "%{http_code}" <URL>/
```

## State Machine

| State | Trigger | Autonomous Action |
|---|---|---|
| CI_PENDING | poll | Silent wait |
| CI_FAILED | poll | Analyze + fix + push |
| CI_PASSED | poll | Check review |
| REVIEW_PENDING | poll | Silent wait |
| REVIEW_DONE | poll | Fix comments if any → merge |
| MERGING | merge cmd | Notify, switch to deploy tracking |
| DEPLOY_RUNNING | poll | Silent wait |
| DEPLOY_DONE | poll | Health check → issue-specific verification |
| DEPLOY_FAILED | poll | Notify error |
| HEALTH_OK | poll | Analyze issues → verify changes on production via Playwright |
| VERIFIED | poll | Notify success with per-issue results → CronDelete |

## Anti-Patterns

| Wrong | Right |
|---|---|
| "Chceš mergovat?" | Just merge it |
| "CI prošlo" (every poll) | Only notify on first pass or state change |
| Waiting for user input | Act immediately on each state |
| Sending same notification twice | Track what was already reported |
| Leaving cron running after completion | CronDelete when done |

## Notes

- CronCreate jobs are session-only (max 7 days)
- Always send Czech notifications via mcp__notify__notify
- Include issueIds when working on specific issues
- For CI failures: read logs, identify root cause, fix autonomously
- For review comments: read all comments, fix all issues, push in one commit
