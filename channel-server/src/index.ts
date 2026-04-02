#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import * as http from "node:http";

const DEFAULT_PORT = 9878;
const MAX_BODY_SIZE = 1024 * 1024; // 1 MB

function parseArgs(): { port: number } {
  const args = process.argv.slice(2);
  let port = DEFAULT_PORT;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--port" && args[i + 1]) {
      port = parseInt(args[i + 1], 10);
      if (isNaN(port) || port < 1024 || port > 65535) {
        console.error(`Invalid port: ${args[i + 1]}. Using default ${DEFAULT_PORT}.`);
        port = DEFAULT_PORT;
      }
      i++;
    }
  }

  return { port };
}

interface CiEvent {
  event: string;
  status: string;
  repository: string;
  commit?: string;
  commitMessage?: string;
  runUrl?: string;
  issueIds?: number[];
  environment?: string;
}

const STATUS_LABELS: Record<string, string> = {
  success: "succeeded",
  failure: "FAILED",
  cancelled: "cancelled",
};

function formatChannelContent(data: CiEvent): string {
  const lines: string[] = [];

  const statusText = STATUS_LABELS[data.status] ?? data.status;
  lines.push(`${data.event}: ${statusText}`);

  if (data.commitMessage) {
    lines.push(`Commit: ${data.commitMessage} (${data.commit || "unknown"})`);
  }

  if (data.runUrl) {
    lines.push(`Run: ${data.runUrl}`);
  }

  if (data.issueIds && data.issueIds.length > 0) {
    lines.push(`Issues: ${data.issueIds.join(", ")}`);
  }

  return lines.join("\n");
}

async function main() {
  const { port } = parseArgs();

  const server = new Server(
    { name: "ci-channel", version: "1.0.0" },
    {
      capabilities: {
        experimental: { "claude/channel": {} },
      },
      instructions:
        "CI/CD deployment events arrive as <channel> messages. " +
        "When you receive a deploy-complete event with status success, " +
        "verify the deployment (check service status, logs) and notify the user via mcp__notify__notify. " +
        "When status is failure, notify the user about the failed deployment with the run URL.",
    }
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // HTTP webhook listener
  const httpServer = http.createServer(async (req, res) => {
    if (req.method !== "POST") {
      res.writeHead(405, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return;
    }

    let body = "";
    let bodySize = 0;

    req.on("data", (chunk: Buffer) => {
      bodySize += chunk.length;
      if (bodySize > MAX_BODY_SIZE) {
        res.writeHead(413, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Request body too large" }));
        req.destroy();
        return;
      }
      body += chunk.toString();
    });

    req.on("end", async () => {
      if (bodySize > MAX_BODY_SIZE) return;

      let data: CiEvent;
      try {
        data = JSON.parse(body);
      } catch {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Invalid JSON" }));
        return;
      }

      try {
        if (!data.event || !data.status || !data.repository) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(
            JSON.stringify({
              error: "Missing required fields: event, status, repository",
            })
          );
          return;
        }

        const content = formatChannelContent(data);
        const meta: Record<string, string> = {
          event: data.event,
          status: data.status,
          repository: data.repository,
        };

        if (data.commit) meta.commit = data.commit;
        if (data.commitMessage) meta.commitMessage = data.commitMessage;
        if (data.environment) meta.environment = data.environment;
        if (data.runUrl) meta.runUrl = data.runUrl;
        if (data.issueIds && data.issueIds.length > 0) {
          meta.issueIds = data.issueIds.join(",");
        }

        try {
          await server.notification({
            method: "notifications/claude/channel",
            params: { content, meta },
          });
        } catch {
          console.error(
            "[ci-channel] Warning: could not push to Claude Code (not connected?)"
          );
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, event: data.event }));
      } catch (err) {
        console.error("[ci-channel] Unexpected error:", err);
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Internal server error" }));
      }
    });
  });

  httpServer.listen(port, "127.0.0.1", () => {
    console.error(`[ci-channel] Webhook listening on http://127.0.0.1:${port}`);
  });

  httpServer.on("error", (err: NodeJS.ErrnoException) => {
    if (err.code === "EADDRINUSE") {
      // Port already in use — another session's server is running.
      // Continue without HTTP listener (MCP stdio still works for health checks).
      console.error(
        `[ci-channel] Port ${port} already in use — running in MCP-only mode (no webhook listener).`
      );
    }
    console.error(`[ci-channel] Server error: ${err.message}`);
  });
}

main().catch((err) => {
  console.error(`[ci-channel] Fatal error: ${err}`);
  process.exit(1);
});
