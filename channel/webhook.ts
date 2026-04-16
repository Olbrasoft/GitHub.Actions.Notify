#!/usr/bin/env bun
/**
 * GitHub Webhook Channel for Claude Code
 *
 * Watches ~/.config/claude-channels/deploy-events/ for event files matching
 * the current repo and pushes them into the Claude Code session via MCP
 * Channels. Each session spawns its own instance — no port conflicts.
 *
 * Architecture:
 *   GitHub → gh webhook forward → webhook-receiver.py (port 9877) → event file
 *   → THIS SERVER (fs.watch) → Claude Code session via MCP channel
 *
 * Replaces: wake-on-event.sh, wake-claude.sh, check-deploy-status.sh
 *
 * Migration note: During migration, both this channel and the legacy
 * wake-claude.sh path may run. wake-claude.sh deletes event files after
 * FIFO delivery, so this watcher may miss files consumed by the old path.
 * This is harmless (duplicate delivery is OK, the model checks PR state).
 * After migration is complete, remove wake-claude.sh calls from
 * webhook-receiver.py so this channel is the sole consumer.
 *
 * @see https://code.claude.com/docs/en/channels-reference
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { watch, readFileSync, unlinkSync, existsSync, mkdirSync, readdirSync } from "fs";
import { execSync } from "child_process";
import { join, basename } from "path";

// Derive repo prefix from git remote in cwd
function getRepoPrefix(): string {
  try {
    const remote = execSync("git remote get-url origin 2>/dev/null", {
      encoding: "utf-8",
    }).trim();
    return remote
      .replace(/.*github\.com[:/]/, "")
      .replace(/\.git$/, "")
      .replace("/", "-");
  } catch {
    return "";
  }
}

// Always use ~/.config/ — must match existing producers (webhook-receiver.py,
// wake-claude.sh, check-deploy-status.sh) which all hardcode this path.
const EVENTS_DIR = join(
  process.env.HOME ?? "/tmp",
  ".config/claude-channels/deploy-events"
);
const REPO_PREFIX = getRepoPrefix();

const mcp = new Server(
  { name: "github-webhook", version: "1.0.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
    },
    instructions: `You receive GitHub CI/CD events as <channel source="github-webhook"> tags.
Each event is a JSON object. Handle based on the "event" field:

## ci-complete (status: success)
CI PASSED — this is a COMPLETE UNIT OF WORK. Handle everything NOW:
1. Check PR state: gh pr view <prNumber> --repo <repository> --json state,mergeable,reviews
2. If Copilot reviewed → read comments, fix, push, poll CI, MERGE
3. If Copilot NOT reviewed → poll every 60s up to 10 min, then handle review
4. After merge: repos with deploy (VirtualAssistant) → wait. Others → done.

## ci-complete (status: failure)
CI FAILED. Read logs, fix, commit, push. Notify user.

## code-review-complete
Read ALL comments. Fix. Push. If Copilot → MERGE after CI (reviews once). If human → verify satisfied.

## deploy-complete / verify-complete
Success → verify production, close issue. Failure → fix.

RULES: Act IMMEDIATELY. Do NOT ask user. Poll, fix, merge. Notify via mcp__notify__notify (Czech).`,
  }
);

await mcp.connect(new StdioServerTransport());

if (!REPO_PREFIX) {
  console.error("[github-webhook] No git repo in cwd — channel idle");
} else {
  console.error(
    `[github-webhook] Watching ${EVENTS_DIR} for ${REPO_PREFIX}*.json`
  );

  // Ensure events directory exists
  if (!existsSync(EVENTS_DIR)) {
    mkdirSync(EVENTS_DIR, { recursive: true });
  }

  // Process any existing event files (startup drain)
  drainPending();

  // Watch for new event files (handles direct creates)
  watch(EVENTS_DIR, (eventType, filename) => {
    if (!filename || !filename.startsWith(REPO_PREFIX) || !filename.endsWith(".json")) return;
    if (filename.endsWith(".tmp")) return; // skip temp files from atomic writes
    // Small delay to ensure file is fully written
    setTimeout(() => processEventFile(join(EVENTS_DIR, filename)), 100);
  });

  // Fallback poll every 5s — catches files created via os.rename (atomic write)
  // that fs.watch may miss on some Linux/inotify configurations.
  setInterval(() => drainPending(), 5000);
}

function drainPending() {
  try {
    const files = readdirSync(EVENTS_DIR).filter(
      (f) => f.startsWith(REPO_PREFIX) && f.endsWith(".json")
    );
    for (const f of files) {
      processEventFile(join(EVENTS_DIR, f));
    }
  } catch {}
}

function processEventFile(filepath: string) {
  try {
    if (!existsSync(filepath)) return;
    const content = readFileSync(filepath, "utf-8");

    if (!content.trim()) {
      unlinkSync(filepath);
      return;
    }

    // Parse for meta attributes
    let meta: Record<string, string> = { file: basename(filepath) };
    try {
      const event = JSON.parse(content);
      if (event.event) meta.event_type = event.event;
      if (event.status) meta.status = event.status;
      if (event.repository) meta.repository = event.repository;
      if (event.prNumber) meta.pr = String(event.prNumber);
    } catch {}

    console.error(`[github-webhook] Pushing event: ${basename(filepath)}`);

    // Push event to Claude Code session, then delete file
    mcp.notification({
      method: "notifications/claude/channel",
      params: { content, meta },
    }).then(() => {
      // Delete only after successful send
      try { unlinkSync(filepath); } catch {}
    }).catch((err) => {
      console.error(`[github-webhook] Failed to push ${basename(filepath)}: ${err}`);
      // File stays on disk for retry on next watch trigger
    });
  } catch (err) {
    console.error(`[github-webhook] Error processing ${filepath}: ${err}`);
  }
}
