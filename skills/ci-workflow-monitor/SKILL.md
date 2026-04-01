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
        └── CronCreate (every 2 min)
              ├── CI pending → silent wait
              ├── CI failed → analyze logs → fix → push
              ├── CI passed → check review
              │   ├── review pending → silent wait
              │   ├── review has comments → fix → push
              │   └── review done → MERGE
              ├── After merge → monitor deploy
              │   ├── deploy running → silent wait
              │   ├── deploy failed → notify error
              │   └── deploy succeeded → verify production
              └── Verify production
                    ├── Health + homepage check
                    ├── Analyze issue → what changed?
                    ├── Playwright: verify specific changes visible
                    ├── Notify result
                    └── CronDelete
```

### Parent Issue with Sub-Issues (Pipeline Processing)

Follows [Continuous PR Processing Workflow](~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/continuous-pr-processing-workflow.md):

```
Parent issue
  ├── List sub-issues: gh api graphql (query subIssues)
  ├── Group into logical parts (1-N issues per PR)
  ├── Identify dependencies between parts
  │
  ├── Part 1: Implement sub-issues → PR1
  │     └── CronCreate monitors PR1
  │     └── IMMEDIATELY start Part 2 (don't wait!)
  │
  ├── Part 2: Implement sub-issues → PR2
  │     └── Check PR1 status → merge if ready
  │     └── CronCreate monitors PR2
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

## CronCreate Prompt Template — Single Issue

Replace `{ISSUE_NUM}`, `{PR_NUMBER}`, `{OWNER}/{REPO}`, `{PRODUCTION_URL}`, `{BRANCH}`, `{ISSUE_IDS}`.

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

   Branch protection requires all checks to pass before merge (including Copilot code review "Agent" check).
   Simply attempt to merge — GitHub will reject if checks haven't passed yet.

   gh pr merge {PR_NUMBER} --repo {OWNER}/{REPO} --merge 2>&1
   - If merge SUCCEEDS → Notify: "PR #{PR_NUMBER} mergnut (issue #{ISSUE_NUM}). Sleduji deploy."
   - If merge FAILS with "required status checks" → checks still running → say "Merge blocked by pending checks, waiting" → STOP, wait for next tick
   - If merge FAILS with other error → report the error

   If merge is blocked, also check for review comments to address:
   gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/comments --jq '.[].body'
   - Has actionable review comments → fix all, commit, push. Notify: "Review opraveny."
   - No comments → just wait for checks to complete

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

6. Issue-specific verification:
   Read the issue to understand what changed:
   gh issue view {ISSUE_NUM} --repo {OWNER}/{REPO} --json title,body

   Based on the issue description, verify the specific changes on production:
   - New page/route → navigate to it, verify it loads (curl or Playwright)
   - UI change → take screenshot, verify change is visible
   - Bug fix → reproduce original scenario, verify it's fixed
   - Data/content change → verify content is correct
   - SEO change → check meta tags, URLs, redirects

   Report what was verified for this issue.
   Notify: "Issue #{ISSUE_NUM} ověřena na produkci: {verification_summary}"

   Then: "PIPELINE COMPLETE — run CronDelete."

Issue IDs for notifications: {ISSUE_IDS}
```

## CronCreate Prompt Template — Parent Issue (Pipeline)

For parent issues, the CronCreate manages the entire pipeline:

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

## State Machine

| State | Trigger | Autonomous Action |
|---|---|---|
| ISSUE_ASSIGNED | start | Implement, create branch, commit, push, create PR |
| CI_PENDING | poll | Silent wait |
| CI_FAILED | poll | Analyze logs → fix → push |
| CI_PASSED | poll | Check review |
| REVIEW_PENDING | poll | Silent wait |
| REVIEW_DONE | poll | Fix comments if any → merge |
| PR_MERGED | poll | Monitor deploy |
| DEPLOY_RUNNING | poll | Silent wait |
| DEPLOY_FAILED | poll | Notify error |
| DEPLOY_DONE | poll | Health check + issue-specific verification |
| VERIFIED | poll | Notify per-issue results → CronDelete |

## Anti-Patterns

| Wrong | Right |
|---|---|
| "Chceš mergovat?" | Just merge it |
| "CI prošlo" (every poll) | Only notify on state change |
| Waiting for review | Continue with next sub-issue |
| Generic health check only | Verify issue-specific changes on production |
| Closing issue before verification | First verify on production, then close |
| One PR for entire parent issue | Split into logical parts, one PR per group |

## Integration

This skill works with:
- [Continuous PR Processing](~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/continuous-pr-processing-workflow.md) — pipeline pattern for parent issues
- [GitHub Issues](github-issues skill) — issue creation with proper GraphQL sub-issue linking
- [Git Workflow](~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/git-workflow-workflow.md) — branch naming, commits
