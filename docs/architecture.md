# Architecture

## Overview

GitHub.Actions.Notify provides CI/CD event feedback through two complementary channels:

```
┌─────────────────────────────────────────────────────────────────┐
│                    GitHub Actions Pipeline                       │
│                                                                  │
│  Cloud Runner (ubuntu-latest)     Self-Hosted Runner             │
│  ┌──────────────────────┐        ┌────────────────────────────┐  │
│  │ check, fmt, test     │        │ deploy, verify             │  │
│  │ (build & test only)  │───────▶│ + notification steps       │  │
│  └──────────────────────┘ needs  └──────────┬─────────────────┘  │
│                                              │                    │
└──────────────────────────────────────────────┼────────────────────┘
                                               │ curl POST
                                               ▼
                        ┌──────────────────────────────────────┐
                        │    VirtualAssistant (localhost:5055)   │
                        │                                        │
                        │  POST /api/notifications               │
                        │  ├── Save to PostgreSQL                │
                        │  ├── Route to TTS pipeline             │
                        │  └── Voice output (Azure/EdgeTTS/...)  │
                        └──────────────────────────────────────┘
                                               │
                              ┌────────────────┴────────────────┐
                              ▼                                  ▼
                     Channel 1: TTS                    Channel 2: Polling
                     (Passive)                         (Active)
                     ┌──────────────┐           ┌─────────────────────┐
                     │ User hears   │           │ Claude Code         │
                     │ "Build prošel│           │ CronCreate (*/3 min)│
                     │  deploy OK"  │           │ gh pr checks <PR>   │
                     │              │           │ → react to status   │
                     └──────────────┘           └─────────────────────┘
```

## Composite Actions

All actions are shell-based (no Node.js, no Docker). They use `curl` to POST to VirtualAssistant.

### Dependency Chain

```
actions/ci-status      ──┐
actions/deploy-status  ──┼──▶ actions/notify (core)
actions/playwright-verify┘       │
                                 ▼
                          curl POST → VirtualAssistant
```

## Data Flow

1. **GitHub event** (push, PR) triggers workflow
2. **Cloud runner** executes build/test jobs
3. **Self-hosted runner** executes deploy + notification jobs
4. **Notification action** sends curl POST to `localhost:5055/api/notifications`
5. **VirtualAssistant** stores notification, routes to TTS
6. **TTS pipeline** speaks the notification (Czech language)
7. **Claude Code** (if running) detects status change via CronCreate polling

## VirtualAssistant API Contract

```
POST /api/notifications
Content-Type: application/json

{
  "text": "Deploy cr na production uspesne dokoncen.",
  "source": "ci-pipeline",
  "issueIds": [166]
}

Response 200:
{
  "success": true,
  "id": 456,
  "text": "Deploy cr na production uspesne dokoncen.",
  "source": "ci-pipeline"
}
```

## Agent Type

The `ci-pipeline` source maps to AgentType.CiPipeline (ID 30) in VirtualAssistant. This agent has its own voice profile for TTS output, distinguishing CI notifications from Claude Code or other agent notifications.
