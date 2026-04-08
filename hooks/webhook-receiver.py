#!/usr/bin/env python3
"""Webhook receiver for gh webhook forward.
Listens on port 9877, receives GitHub webhook payloads,
and writes event files + wakes Claude Code via FIFO."""

import json
import os
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9877
EVENTS_DIR = os.path.expanduser("~/.config/claude-channels/deploy-events")
os.makedirs(EVENTS_DIR, exist_ok=True)


# In-memory dedup cache for emitted CI events. Key:
#   (repo_name, pr_number, head_sha, status)
# Value: epoch seconds when this tuple was last emitted.
#
# Why we need this on top of the file-existence check:
#   1. webhook-receiver writes the event JSON file to deploy-events
#   2. webhook-receiver calls wake-claude.sh
#   3. wake-claude.sh reads the file, delivers via FIFO, **deletes** it
#   4. Another check_suite event arrives for the SAME (PR, commit, status)
#      a few seconds later (e.g. one workflow finishes after another for
#      the same head SHA — happens frequently with multi-job workflows)
#   5. webhook-receiver checks os.path.exists(event_file) → False
#      (because wake-claude.sh deleted it in step 3)
#   6. webhook-receiver writes a NEW file → new wake event for the
#      same logical CI completion
#
# The in-memory cache survives wake-claude.sh's file deletion, so step 5
# becomes "in-memory cache hit → skip" instead of "file missing → re-emit".
#
# Entries expire after CI_DEDUP_TTL_SECONDS to bound memory use and to
# allow re-emission of the same (repo, PR, commit, status) tuple after
# a while if some downstream consumer never picked it up. New commits
# on the same PR are NOT blocked by the cache regardless of TTL,
# because the head SHA is part of the key.
_ci_dedup_cache = {}
_ci_dedup_lock = threading.Lock()
CI_DEDUP_TTL_SECONDS = 600  # 10 minutes


def _ci_dedup_expire_locked(now):
    """Garbage-collect expired dedup entries.

    Caller must hold _ci_dedup_lock.
    """
    expired = [k for k, ts in _ci_dedup_cache.items()
               if now - ts > CI_DEDUP_TTL_SECONDS]
    for k in expired:
        del _ci_dedup_cache[k]


def _ci_dedup_check(repo_name, pr_number, head_sha, status):
    """Return True if this (repo, pr, commit, status) was already emitted
    recently, otherwise return False.

    This helper does NOT mutate the dedup cache. The caller must invoke
    _ci_dedup_mark_emitted() only AFTER the event has been successfully
    persisted to disk, so that an exception during file I/O doesn't
    cause the cache to silently suppress a legitimate retry for up to
    CI_DEDUP_TTL_SECONDS.

    Access to the cache is protected by a lock so this remains safe if
    the receiver is ever run in a multi-threaded context.
    """
    key = (repo_name, pr_number, head_sha, status)
    now = time.time()
    with _ci_dedup_lock:
        _ci_dedup_expire_locked(now)
        return key in _ci_dedup_cache


def _ci_dedup_mark_emitted(repo_name, pr_number, head_sha, status):
    """Record a successfully persisted CI event as emitted.

    Call this only AFTER the event file has been written and renamed
    into place — never before, otherwise a failure during file I/O
    would suppress legitimate retries.
    """
    key = (repo_name, pr_number, head_sha, status)
    now = time.time()
    with _ci_dedup_lock:
        _ci_dedup_expire_locked(now)
        _ci_dedup_cache[key] = now


def _reap_in_background(proc):
    """Wait for a fire-and-forget wake-claude.sh subprocess in a daemon thread.

    Without this, the Popen child stays as a <defunct> entry in the process
    table until the receiver itself exits. We can't use a SIGCHLD handler
    here because the receiver also calls subprocess.run() elsewhere (which
    relies on the default SIGCHLD behaviour). A daemon thread per spawn is
    cheap, never blocks the main loop, and unambiguously reaps only the
    children we own. See bug 37.

    Non-zero exit codes are logged to stderr so wake-claude.sh delivery
    failures are visible in the systemd journal of gh-webhook-forward.service.
    """
    def _wait():
        try:
            returncode = proc.wait()
            if returncode != 0:
                print(
                    f"[webhook-receiver] Wake subprocess exited with status "
                    f"{returncode}: {proc.args}",
                    file=sys.stderr,
                )
        except Exception as e:
            print(
                f"[webhook-receiver] Failed waiting for wake subprocess "
                f"{proc.args}: {e}",
                file=sys.stderr,
            )

    t = threading.Thread(target=_wait, daemon=True)
    t.start()


def _wake(repo_name, branch=None):
    """Wake Claude Code session(s) via FIFO."""
    wake_script = os.path.expanduser("~/.claude/hooks/wake-claude.sh")
    if not os.path.isfile(wake_script):
        return
    try:
        args = [wake_script, repo_name]
        if branch:
            args.append(branch)
        # Use DEVNULL for stderr — nothing reads the pipe in this process, so
        # PIPE would let the kernel buffer fill up and eventually block the
        # child or leak file descriptors over time. wake-claude.sh's own
        # stderr is preserved by the systemd journal of gh-webhook-forward.service
        # if we ever need to debug it; for that, run wake-claude.sh manually.
        proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Reap the child in a background thread so it does not become a
        # zombie. wake-claude.sh can take up to WAKE_CLAUDE_RETRY_SECS to
        # finish; we never want to block the receiver waiting for it.
        _reap_in_background(proc)
        branch_info = f" branch={branch}" if branch else ""
        print(f"[webhook-receiver] Wake signal sent for {repo_name}{branch_info}",
              file=sys.stderr)
    except Exception as e:
        print(f"[webhook-receiver] Wake failed: {e}", file=sys.stderr)


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            payload = json.loads(body)
            event_type = self.headers.get("X-GitHub-Event", "unknown")
            self._handle_event(event_type, payload)
        except json.JSONDecodeError:
            pass

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def _handle_event(self, event_type, payload):
        if event_type == "pull_request_review":
            self._handle_review(payload)
        elif event_type == "check_suite":
            self._handle_check_suite(payload)

    def _handle_review(self, payload):
        review = payload.get("review", {})
        pr = payload.get("pull_request", {})
        repo = payload.get("repository", {})
        pr_branch = pr.get("head", {}).get("ref", "")

        repo_name = repo.get("full_name", "unknown")
        repo_file = repo_name.replace("/", "-")
        pr_number = pr.get("number", 0)
        reviewer = review.get("user", {}).get("login", "unknown")
        state = review.get("state", "unknown")
        pr_title = pr.get("title", "unknown")
        pr_url = pr.get("html_url", "")
        head_sha = pr.get("head", {}).get("sha", "unknown")[:7]

        # Count review comments
        comment_count = 0
        review_id = review.get("id")
        if review_id:
            try:
                result = subprocess.run(
                    ["gh", "api", f"repos/{repo_name}/pulls/{pr_number}/reviews/{review_id}/comments",
                     "--jq", "length"],
                    capture_output=True, text=True, timeout=10
                )
                comment_count = int(result.stdout.strip()) if result.stdout.strip() else 0
            except Exception:
                pass

        event = {
            "event": "code-review-complete",
            "status": state,
            "repository": repo_name,
            "prNumber": pr_number,
            "prTitle": pr_title,
            "prUrl": pr_url,
            "commit": head_sha,
            "reviewer": reviewer,
            "reviewComments": comment_count,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

        # Atomic write: write to a tempfile in the same dir, then rename.
        # This prevents wake-claude.sh from reading a partially-written file.
        event_file = os.path.join(EVENTS_DIR, f"{repo_file}-review-{pr_number}.json")
        tmp_file = event_file + ".tmp"
        with open(tmp_file, "w") as f:
            json.dump(event, f, indent=2)
        os.rename(tmp_file, event_file)

        print(f"[webhook-receiver] Code review event written: {repo_name} PR #{pr_number} "
              f"(reviewer: {reviewer}, state: {state}, comments: {comment_count}, "
              f"branch: {pr_branch})",
              file=sys.stderr)

        _wake(repo_name, pr_branch)

    def _handle_check_suite(self, payload):
        """Handle check_suite completed event.

        GitHub fires one check_suite event per integrated app (GitHub Actions,
        GitGuardian, etc.). A single PR typically has 2+ check suites, so a
        naive "fire on every check_suite completed" approach causes premature
        success events: e.g. GitGuardian (success) finishes before GitHub
        Actions (failure), and the session is woken with success before the
        actual failure arrives.

        Fix: every check_suite event triggers a re-evaluation of the PR's
        FULL aggregated check status via `gh pr checks`. We only emit the
        ci-complete event when:
          - all checks are in a terminal state (no pending/in_progress)
          - AND we have not already emitted the same final status for the
            same (PR, head SHA) tuple (idempotency on a per-commit basis)

        The aggregate status is the worst conclusion: any failure → failure,
        otherwise success.
        """
        action = payload.get("action", "")
        if action != "completed":
            return

        check_suite = payload.get("check_suite", {})
        repo = payload.get("repository", {})
        repo_name = repo.get("full_name", "unknown")
        repo_file = repo_name.replace("/", "-")
        head_sha = check_suite.get("head_sha", "unknown")
        head_sha_short = head_sha[:7] if head_sha != "unknown" else head_sha
        head_branch = check_suite.get("head_branch", "")

        # Only for PRs — check if there are associated pull requests
        pull_requests = check_suite.get("pull_requests", [])
        if not pull_requests:
            return

        pr = pull_requests[0]
        pr_number = pr.get("number", 0)
        pr_branch = pr.get("head", {}).get("ref", head_branch)

        # Re-evaluate the PR's aggregated check status. The arrival of
        # this single check_suite event might be the LAST one we needed
        # to wait for, OR there may still be checks in progress.
        agg = self._aggregate_pr_checks(repo_name, pr_number)
        if agg is None:
            print(f"[webhook-receiver] PR #{pr_number}: gh pr view --json statusCheckRollup "
                  f"failed, skipping wake",
                  file=sys.stderr)
            return

        if not agg["all_terminal"]:
            print(f"[webhook-receiver] PR #{pr_number}: {agg['pending']} check(s) still pending, "
                  f"deferring wake until all complete",
                  file=sys.stderr)
            return

        # All checks are terminal. Determine the final status.
        final_status = "failure" if agg["any_failure"] else "success"

        # In-memory dedup cache check. This survives wake-claude.sh's
        # post-delivery deletion of the event file, so a second
        # check_suite event arriving for the same (PR, commit, status)
        # tuple a few seconds later — common when multiple GitHub
        # workflows fire for the same head SHA — gets deduped here
        # instead of generating a duplicate wake event. See top-of-file
        # _ci_dedup_cache definition for full rationale.
        #
        # IMPORTANT: this is a non-mutating CHECK only. The cache is
        # updated AFTER the event file has been successfully renamed
        # into place (via _ci_dedup_mark_emitted). If the file write
        # raises, the cache stays clean and a retry can still emit.
        if _ci_dedup_check(repo_name, pr_number, head_sha, final_status):
            print(f"[webhook-receiver] PR #{pr_number}: ci-complete with "
                  f"status={final_status} for {head_sha_short} already emitted "
                  f"(in-memory dedup), skipping",
                  file=sys.stderr)
            return

        # Idempotency: if we have already emitted an event for this exact
        # (PR, head SHA, status) tuple in a recent file, skip. We use the
        # event filename as the idempotency key — it includes the FULL head
        # SHA (40 chars). Truncated 7-char SHAs are not guaranteed unique
        # and could let one commit's event clobber another commit's event
        # for the same PR. This branch only fires when the receiver was
        # restarted between the first and second check_suite events
        # (in-memory cache cleared) but the file is still present
        # (wake-claude.sh has not yet processed it).
        event_file = os.path.join(EVENTS_DIR, f"{repo_file}-ci-{pr_number}-{head_sha}.json")
        if os.path.exists(event_file):
            try:
                with open(event_file, "r") as f:
                    existing = json.load(f)
                if existing.get("status") == final_status:
                    print(f"[webhook-receiver] PR #{pr_number}: ci-complete with "
                          f"status={final_status} for {head_sha_short} already emitted "
                          f"(file still present), skipping",
                          file=sys.stderr)
                    return
            except (json.JSONDecodeError, OSError):
                pass

        event = {
            "event": "ci-complete",
            "status": final_status,
            "repository": repo_name,
            "prNumber": pr_number,
            "commit": head_sha_short,
            "branch": pr_branch,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

        # Atomic write: write to a tempfile in the same dir, then rename.
        # This prevents wake-claude.sh from reading a partially-written file
        # and emitting "[wake-on-event] event payload is not valid JSON".
        tmp_file = event_file + ".tmp"
        with open(tmp_file, "w") as f:
            json.dump(event, f, indent=2)
        os.rename(tmp_file, event_file)

        # File is now safely on disk. Only NOW mark the dedup cache so
        # that any exception above (open, json.dump, rename) leaves the
        # cache untouched and a retry can still emit. See review on PR #45.
        _ci_dedup_mark_emitted(repo_name, pr_number, head_sha, final_status)

        print(f"[webhook-receiver] CI {final_status} event written: {repo_name} PR #{pr_number} "
              f"(branch: {pr_branch}, commit: {head_sha_short}, "
              f"checks: {agg['success']}s/{agg['failure']}f/{agg['skipped']}skip)",
              file=sys.stderr)

        _wake(repo_name, pr_branch)

    def _aggregate_pr_checks(self, repo_name, pr_number):
        """Query `gh pr view --json statusCheckRollup` for the aggregate status of all checks on a PR.

        Returns a dict with keys:
          all_terminal (bool): True if every check is in a terminal state
          any_failure  (bool): True if at least one terminal check is FAILURE
          pending  (int): count of checks still in progress / pending
          success  (int): count of SUCCESS checks
          failure  (int): count of FAILURE checks
          skipped  (int): count of SKIPPED checks
        Returns None on gh CLI error.
        """
        try:
            result = subprocess.run(
                ["gh", "pr", "view", str(pr_number), "--repo", repo_name,
                 "--json", "statusCheckRollup"],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                return None
            data = json.loads(result.stdout)
            checks = data.get("statusCheckRollup", []) or []
        except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
            return None

        pending = 0
        success = 0
        failure = 0
        skipped = 0
        for check in checks:
            status = (check.get("status") or "").upper()
            conclusion = (check.get("conclusion") or "").upper()
            # Terminal states: COMPLETED with any conclusion. Non-terminal:
            # IN_PROGRESS, QUEUED, PENDING, REQUESTED, WAITING.
            if status in ("IN_PROGRESS", "QUEUED", "PENDING", "REQUESTED", "WAITING"):
                pending += 1
                continue
            if conclusion == "SUCCESS":
                success += 1
            elif conclusion in ("FAILURE", "CANCELLED"):
                # CANCELLED checks are non-success and should block merging.
                # If a check was cancelled (manually or by infra), the
                # consumer must NOT treat the PR as cleanly green.
                failure += 1
            elif conclusion in ("SKIPPED", "NEUTRAL"):
                skipped += 1
            elif not conclusion:
                # Empty conclusion typically means still pending in some
                # GitHub APIs that distinguish status from conclusion.
                pending += 1
            else:
                # Unknown conclusion → treat as failure to be safe
                failure += 1

        return {
            "all_terminal": pending == 0,
            "any_failure": failure > 0,
            "pending": pending,
            "success": success,
            "failure": failure,
            "skipped": skipped,
        }

    def log_message(self, format, *args):
        pass  # Suppress default access logs


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), WebhookHandler)
    print(f"[webhook-receiver] Listening on 127.0.0.1:{PORT}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
