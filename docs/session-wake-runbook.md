# Session Wake Runbook — What To Do When a Wake Event Arrives

**Read this file when you are a Claude Code session and you just received a
wake event (ci-complete, code-review-complete, deploy-complete,
verify-complete) typed into your prompt by ghnotify.**

This runbook exists because sessions repeatedly got stuck in one of these loops:

1. Waiting for CI that already arrived.
2. Waiting for a second Copilot review that will never arrive.
3. Waiting for a deploy event on a repo that has no deploy workflow.
4. Receiving a wake event but not acting on it.

## How wake events arrive

[ghnotify](https://github.com/Olbrasoft/ghnotify) runs as a systemd user
service. For each Olbrasoft repo with an active `claude` session it spawns one
`gh webhook forward` subprocess and dispatches incoming events to the matching
`claude-<repo>` tmux session via `tmux send-keys`. The event shows up in your
input the next time the assistant returns to the prompt.

There is no FIFO, no per-session port allocation, and no on-disk DEFER queue
anymore — if you weren't at the prompt when the event arrived, the buffered
text is still in your input box waiting for you. If your session wasn't running
at all, the event is discarded (the `discarded:true` reply is logged in
`journalctl --user -u ghnotify-watch`). GitHub keeps the missed delivery in
its 30-day delivery history; manual replay via the REST API is the only way
to get it back.

The `ci-workflow-monitor` skill in
`skills/ci-workflow-monitor/SKILL.md` has the full state machine and the
Copilot-reviews-once rule. **Re-read the skill file**
(`cat ~/Olbrasoft/GitHub.Actions.Notify/skills/ci-workflow-monitor/SKILL.md`)
if you're unsure about the lifecycle.

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

Notify the user:

```
mcp__notify__notify(text: "<Czech summary of what happened>")
```

---

## Diagnostic: "I received a wake but I'm not sure what to do"

If you're confused about the current state, run:

```bash
# Full PR state in one command
gh pr view <NUM> --repo <REPO> --json state,mergeable,statusCheckRollup,reviews,title,headRefName

# Recent ghnotify dispatches (what did the forwarder route lately?)
journalctl --user -u ghnotify-watch -n 80 --no-pager
```

**Do NOT passively wait if you're unsure.** Run the diagnostic, decide, act.
A wrong action is better than an indefinite wait that blocks the user.

---

## Common mistakes this runbook prevents

| Mistake | What happens | Prevention |
|---|---|---|
| Wait for 2nd Copilot review | Session hangs forever | Rule 1: merge after fixing comments + CI green |
| Wait for deploy on Olbrasoft/cr | Session hangs forever | Rule 2: cr has no deploy workflow |
| Wait for post-merge CI | Session hangs forever | Rule 3: main CI doesn't trigger wake |
| Receive CI success but don't merge | Session sits idle | MERGE DECISION table: checks_pass + copilot reviewed → MERGE |
| Receive CI failure but wait | Session sits idle | Fix immediately, don't wait for another wake |
| Two events arrive close together | Both arrive in the input buffer; second appears after first prompt cycle | Process them in order; don't claim the second was lost |
| ghnotify-watch service down | Wake events never arrive, GitHub records `discarded:true` (no — silently 30-day history) | `systemctl --user status ghnotify-watch`; restart if needed |

---

## Where this file lives

- Canonical: `docs/session-wake-runbook.md` in
  [Olbrasoft/GitHub.Actions.Notify](https://github.com/Olbrasoft/GitHub.Actions.Notify).
- The forwarder source: [Olbrasoft/ghnotify](https://github.com/Olbrasoft/ghnotify).

## Testing the wake system

To verify end-to-end: open a PR, let it go idle in the assistant, watch
`journalctl --user -u ghnotify-watch -f`. When CI completes you should see
`prompt delivered session=claude-<repo> event_type=workflow_run` (or
`check_suite`), and the prompt text appears in the assistant's input box on
its next idle cycle.

**Update this file when you discover a new "session got stuck" pattern.**
Add it to the common mistakes table with the prevention rule.
