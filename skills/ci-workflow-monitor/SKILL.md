---
name: ci-workflow-monitor
description: Monitor CI/CD pipeline status using CronCreate polling. Autonomously react to CI pass/fail, code review completion, deploy status, and trigger Playwright verification. Use after creating a PR to avoid blocking on GitHub Actions.
---

# CI Workflow Monitor

Autonomous CI/CD pipeline monitoring for Claude Code. After creating a PR, use this skill to set up non-blocking monitoring that reacts to pipeline events.

## When to Use

After creating a Pull Request, instead of waiting and manually checking, set up a CronCreate monitor that polls the pipeline status every 3 minutes.

## Workflow

```
PR Created
  └── CronCreate (every 3 min)
        ├── Check CI status (gh pr checks)
        │   ├── pending → do nothing, wait for next poll
        │   ├── failure → analyze error, fix, push, continue monitoring
        │   └── all passed → check review status
        ├── Check review status (gh pr view --json reviewDecision)
        │   ├── pending → do nothing, wait for next poll
        │   ├── changes_requested → fix comments, push
        │   └── approved / no review required → merge PR
        ├── After merge → monitor deploy
        │   ├── gh run list --branch main → check deploy job
        │   ├── deploy success → notify + verify production
        │   └── deploy failure → notify user
        └── After deploy → verify production
              ├── Run Playwright or curl against production URL
              ├── Notify result via mcp__notify__notify
              └── CronDelete (monitoring complete)
```

## Setup — CronCreate Prompt Template

After creating a PR, use CronCreate with this prompt:

```
Check CI/CD pipeline status for PR #{PR_NUMBER} on {OWNER}/{REPO}.

1. Run: gh pr checks {PR_NUMBER} --repo {OWNER}/{REPO}
   - If any check is "pending" or "in_progress" → do nothing, say "CI still running"
   - If any check "fail" → run: gh run view {RUN_ID} --repo {OWNER}/{REPO} --log-failed
     Then analyze the error and report what failed.
   - If all checks "pass" → proceed to step 2

2. Run: gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json reviewDecision,reviews
   - If reviewDecision is "APPROVED" or reviews are empty → proceed to step 3
   - If reviewDecision is "CHANGES_REQUESTED" → read review comments with:
     gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/reviews
     Report the comments.
   - If review is pending → do nothing, say "Waiting for code review"

3. PR is ready to merge. Report:
   "PR #{PR_NUMBER} je připraven k merge. CI prošlo, review hotov."
   Send notification via mcp__notify__notify.

4. After merge detected (check if PR state is "MERGED"):
   Run: gh run list --repo {OWNER}/{REPO} --branch main --limit 1 --json status,conclusion
   - If deploy is running → "Deploy probíhá"
   - If deploy succeeded → "Deploy dokončen, spouštím verifikaci"
   - If deploy failed → "Deploy selhal!"

5. After deploy success, verify production:
   Run: curl -s -o /dev/null -w "%{{http_code}}" {PRODUCTION_URL}/health
   - If 200 → "Produkce ověřena, vše OK"
   - If not 200 → "Produkce neodpovídá správně!"
   Send final notification via mcp__notify__notify.
   Then say: "Pipeline monitoring complete. Delete this cron job."
```

## CronCreate Parameters

```javascript
CronCreate({
  cron: "*/3 * * * *",   // Every 3 minutes
  prompt: "...",          // Use template above with filled values
  recurring: true         // Keep polling until manually deleted
})
```

## Key Commands Reference

```bash
# Check all PR checks (CI status)
gh pr checks <PR_NUMBER> --repo <OWNER>/<REPO>

# View PR review status
gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json reviewDecision,reviews,state

# View failed CI logs
gh run view <RUN_ID> --repo <OWNER>/<REPO> --log-failed

# View review comments
gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews

# Check latest workflow run on main
gh run list --repo <OWNER>/<REPO> --branch main --limit 1 --json status,conclusion,name

# Merge PR
gh pr merge <PR_NUMBER> --repo <OWNER>/<REPO> --merge

# Health check
curl -s -o /dev/null -w "%{http_code}" <URL>/health
```

## State Transitions

| Current State | Event | Action |
|---|---|---|
| PR created | — | Start CronCreate polling |
| CI pending | poll | Do nothing |
| CI failed | poll | Report error, optionally fix |
| CI passed, review pending | poll | Do nothing |
| CI passed, review done | poll | Merge PR |
| PR merged, deploy running | poll | Do nothing |
| Deploy succeeded | poll | Verify production |
| Production verified | poll | Send final notification, stop polling |
| Deploy failed | poll | Alert user |

## Integration with Existing Workflow

This skill extends:
- [Continuous PR Processing](~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/continuous-pr-processing-workflow.md)
- [Git Workflow](~/GitHub/Olbrasoft/engineering-handbook/development-guidelines/workflow/git-workflow-workflow.md)

## Notes

- CronCreate jobs are session-only (max 7 days, lost on session end)
- Use haiku model for background polling agents when possible
- Always send Czech notifications via mcp__notify__notify
- Include issueIds in notifications when working on specific issues
- After CronCreate detects completion, explicitly delete it with CronDelete
