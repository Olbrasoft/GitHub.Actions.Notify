# GitHub Webhook Channel for Claude Code

MCP channel server that delivers GitHub CI/CD events to Claude Code sessions via native Channels API.

## Setup

```bash
bun install
```

## Usage

Registered as MCP server in `~/.claude.json`. Claude Code spawns it automatically.

Start Claude Code with the channel enabled:

```bash
claude --dangerously-load-development-channels server:github-webhook
```

## How it works

Watches `~/.config/claude-channels/deploy-events/` for event files matching the current repo. When a file appears, reads it, pushes the content to Claude Code via MCP channel notification, then deletes the file.

## Architecture

```
GitHub → gh webhook forward → webhook-receiver.py (port 9877) → event file
→ webhook.ts (fs.watch) → MCP channel notification → Claude Code session
```
