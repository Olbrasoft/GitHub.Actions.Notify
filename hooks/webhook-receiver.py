#!/usr/bin/env python3
"""Webhook receiver for gh webhook forward.
Listens on port 9877, receives GitHub webhook payloads,
and writes event files + wakes Claude Code via FIFO."""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9877
EVENTS_DIR = os.path.expanduser("~/.config/claude-channels/deploy-events")
os.makedirs(EVENTS_DIR, exist_ok=True)


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
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

        event_file = os.path.join(EVENTS_DIR, f"{repo_file}-review-{pr_number}.json")
        with open(event_file, "w") as f:
            json.dump(event, f, indent=2)

        print(f"[webhook-receiver] Code review event written: {repo_name} PR #{pr_number} "
              f"(reviewer: {reviewer}, state: {state}, comments: {comment_count}, "
              f"branch: {pr_branch})",
              file=sys.stderr)

        _wake(repo_name, pr_branch)

    def _handle_check_suite(self, payload):
        """Handle check_suite completed event — CI passed, session can merge."""
        action = payload.get("action", "")
        if action != "completed":
            return

        check_suite = payload.get("check_suite", {})
        conclusion = check_suite.get("conclusion", "")
        repo = payload.get("repository", {})
        repo_name = repo.get("full_name", "unknown")
        repo_file = repo_name.replace("/", "-")
        head_sha = check_suite.get("head_sha", "unknown")[:7]
        head_branch = check_suite.get("head_branch", "")

        # Only wake on success or failure, not neutral/skipped
        if conclusion not in ("success", "failure"):
            return

        # Only for PRs — check if there are associated pull requests
        pull_requests = check_suite.get("pull_requests", [])
        if not pull_requests:
            return

        pr = pull_requests[0]
        pr_number = pr.get("number", 0)
        pr_branch = pr.get("head", {}).get("ref", head_branch)

        event = {
            "event": "ci-complete",
            "status": conclusion,
            "repository": repo_name,
            "prNumber": pr_number,
            "commit": head_sha,
            "branch": pr_branch,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

        event_file = os.path.join(EVENTS_DIR, f"{repo_file}-ci-{pr_number}.json")
        with open(event_file, "w") as f:
            json.dump(event, f, indent=2)

        print(f"[webhook-receiver] CI {conclusion} event written: {repo_name} PR #{pr_number} "
              f"(branch: {pr_branch}, commit: {head_sha})",
              file=sys.stderr)

        _wake(repo_name, pr_branch)

    def log_message(self, format, *args):
        pass  # Suppress default access logs


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), WebhookHandler)
    print(f"[webhook-receiver] Listening on 127.0.0.1:{PORT}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
