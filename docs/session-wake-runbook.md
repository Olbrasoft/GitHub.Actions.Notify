# Session Wake Runbook — What To Do When a Wake Event Arrives

**Read this file when you are a Claude Code session and you received a wake event (ci-complete, code-review-complete, deploy-complete, verify-complete) via the asyncRewake hook.**

This runbook exists because sessions repeatedly got stuck in one of these loops:

1. Waiting for CI that already arrived
2. Waiting for a second Copilot review that will never arrive
3. Waiting for a deploy event on a repo that has no deploy workflow
4. Receiving a wake event but not acting on it

## What changed (2026-04-16)

### Prescriptive wake instructions (PR #53)

The wake event instructions injected by `wake-on-event.sh` have been rewritten to be **prescriptive, not advisory.** Previously, the ci-complete instructions said "check if comments already addressed" — sessions debated endlessly instead of merging. Now the instructions are a decision procedure:

1. Run ONE command (`gh pr view` with specific jq)
2. Match the FIRST applicable rule (no deliberation)
3. Act (MERGE / WAIT / SKIP)

### Startup drain + loop drain (PR #54)

**The recurring deadlock was:** two events arrive close together (e.g., CI complete at 14:53, Copilot review at 14:54). The first event is delivered via FIFO. The second event arrives while the session is processing the first one (no FIFO reader available) → DEFER'd to disk. Previously, the disk file was only drained on `UserPromptSubmit` (user types something), which **never fires in autonomous mode** → session waits forever.

**Fix:** `wake-on-event.sh` now has THREE delivery paths:
1. **Startup drain** — on every hook spawn, check disk for pending events BEFORE blocking on FIFO
2. **FIFO delivery** — instant wake via named pipe (primary path, unchanged)
3. **Loop drain** — every 120s FIFO timeout, check disk for DEFER'd events

The `check-deploy-status.sh` on UserPromptSubmit is now a tertiary fallback.

### Reference

The `ci-workflow-monitor` skill in `skills/ci-workflow-monitor/SKILL.md` has the full state machine (Phase A/B/C) and Critical Rule #7 about Copilot reviewing once. **Re-read the skill file** (`cat ~/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor/SKILL.md`) if you're unsure about the lifecycle.

The hook files in `~/.claude/hooks/` are the installed versions — they may be outdated if the user hasn't run `./hooks/install.sh --force` recently. If instructions seem wrong, run install first.

---

## Decision flowchart

When you receive a wake event, follow this EXACTLY:

```
WAKE EVENT RECEIVED
       │
       ▼
  What type?
       │
       ├── ci-complete
       │     │
       │     ▼
       │   status=success?
       │     ├── YES → Check Copilot review (see MERGE DECISION below)
       │     └── NO  → Read CI logs, fix, push. DO NOT WAIT — fix now.
       │
       ├── code-review-complete
       │     │
       │     ▼
       │   comments=0?
       │     ├── YES → Go to MERGE DECISION
       │     └── NO  → Read comments, fix relevant ones, push, go to MERGE DECISION
       │
       ├── deploy-complete
       │     │
       │     ▼
       │   status=success?
       │     ├── YES → Verify production, notify user, close issue
       │     └── NO  → Read deploy logs, fix, push
       │
       └── verify-complete
             │
             ▼
           status=success?
             ├── YES → Notify user, close issue
             └── NO  → Investigate, fix
```

---

## MERGE DECISION — the critical step where sessions get stuck

Run this command ONCE. It gives you everything you need:

```bash
gh pr view <PR_NUM> --repo <REPO> --json state,mergeable,statusCheckRollup,reviews \
  --jq '{
    state,
    mergeable,
    checks_pass: ([.statusCheckRollup[] | select(.conclusion != "SUCCESS" and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL")] | length == 0),
    copilot: ([.reviews[] | select(.author.login | startswith("copilot-pull-request-reviewer"))] | last | {state, submittedAt})
  }'
```

Then apply these rules:

| state | mergeable | checks_pass | copilot.state | Action |
|---|---|---|---|---|
| MERGED | any | any | any | **SKIP — nothing to do** |
| CLOSED | any | any | any | **SKIP — abandoned** |
| OPEN | CONFLICTING | any | any | Rebase or resolve conflicts, push, wait for next ci-complete |
| OPEN | UNKNOWN | any | any | Wait a few seconds and re-check (GitHub is computing) |
| OPEN | MERGEABLE | false | any | WAIT for ci-complete wake (or fix if failure) |
| OPEN | MERGEABLE | true | null (not reviewed yet) | WAIT for code-review-complete wake |
| OPEN | MERGEABLE | true | COMMENTED/APPROVED/CHANGES_REQUESTED | **MERGE NOW** — Copilot does NOT re-review |

---

## The 3 rules that prevent getting stuck

### Rule 1: Copilot reviews each PR EXACTLY ONCE

After you push fix commits for Copilot's comments, **MERGE IMMEDIATELY**. Do NOT wait for a second code-review-complete wake event. It will never arrive. Copilot posts one review per PR lifetime.

**Wrong:**
```
← Copilot review (3 comments)
→ Fix all 3, push
← (waiting for second review...)     ← STUCK FOREVER
```

**Right:**
```
← Copilot review (3 comments)
→ Fix all 3, push
→ Wait for CI on fix commit
← CI success
→ MERGE (Copilot already reviewed, won't come again)
```

### Rule 2: Not every repo has a deploy workflow

| Repo | Has deploy event? |
|---|---|
| Olbrasoft/VirtualAssistant | YES |
| Olbrasoft/cr | **NO** |
| Olbrasoft/HandbookSearch | Check workflow |
| Olbrasoft/GitHub.Actions.Notify | NO |
| Olbrasoft/Blog | Check workflow |

If the repo has NO deploy workflow, your job ends at MERGE. Do not wait for deploy-complete — it will never fire.

After merging on a repo WITHOUT deploy: notify the user that the PR is merged and your work is done.

### Rule 3: Post-merge CI on main does NOT trigger a wake

After you merge a PR, GitHub runs CI on the merge commit on main. This CI run has no associated PR (the branch is deleted), so the webhook handler skips it. You will NOT receive a ci-complete wake for it.

**Do not wait for it.** Your last action is the merge itself (or deploy verification if the repo has a deploy workflow).

---

## After acting on a wake event

Always log your classification:

```bash
~/.claude/hooks/log-wake-feedback.sh \
    event=<type> \
    repo=<repo> \
    classification=ok|late|stale \
    delay=<from event instructions> \
    note="<what you did>"
```

Then notify the user:

```
mcp__notify__notify(text: "<Czech summary of what happened>")
```

---

## Diagnostic: "I received a wake but I'm not sure what to do"

If you're confused about the current state, run:

```bash
# Full PR state in one command
gh pr view <NUM> --repo <REPO> --json state,mergeable,statusCheckRollup,reviews,title,headRefName

# Recent wake feedback from all sessions (what did others do?)
tail -40 ~/.config/claude-channels/wake-feedback.md

# What events are pending on disk (not yet delivered)?
ls -la ~/.config/claude-channels/deploy-events/
```

**Do NOT passively wait if you're unsure.** Run the diagnostic, decide, act, log. A wrong action that gets logged is better than an indefinite wait that blocks the user.

---

## Common mistakes this runbook prevents

| Mistake | What happens | Prevention |
|---|---|---|
| Wait for 2nd Copilot review | Session hangs forever | Rule 1: merge after fixing comments + CI green |
| Wait for deploy on Olbrasoft/cr | Session hangs forever | Rule 2: cr has no deploy workflow |
| Wait for post-merge CI | Session hangs forever | Rule 3: main CI doesn't trigger wake |
| Receive CI success but don't merge | Session sits idle | MERGE DECISION table: checks_pass + copilot reviewed → MERGE |
| Receive CI failure but wait | Session sits idle | Fix immediately, don't wait for another wake |
| Two events arrive close together | Second event DEFER'd, session waits forever | Startup drain + loop drain (PR #54): hook checks disk on spawn and every 120s |
| Hook dies, session goes deaf | No reader, all events DEFER to disk | Startup drain on next hook spawn; if hook never spawns, user must type to trigger UserPromptSubmit fallback |

---

## Where this file lives

- Canonical: `docs/session-wake-runbook.md` in [Olbrasoft/GitHub.Actions.Notify](https://github.com/Olbrasoft/GitHub.Actions.Notify)
- For system-level architecture and failure modes: see `docs/wake-notification-system.md`
- For the hook code itself: `hooks/` directory

## Testing the wake system

To verify the wake system works end-to-end, create a PR, go idle, and confirm the session is woken by the event — not by polling or user input. The session must be truly idle (at the prompt) when the event arrives.

**Update this file when you discover a new "session got stuck" pattern.** Add it to the common mistakes table with the prevention rule.
