# GitHub.Actions.Notify

Reusable GitHub Actions composite actions that send CI/CD event notifications to [VirtualAssistant](https://github.com/Olbrasoft/VirtualAssistant). Provides TTS voice feedback for build results, deploy status, and post-deploy Playwright verification.

## Actions

| Action | Purpose |
|--------|---------|
| `actions/notify` | Core: POST notification to VirtualAssistant |
| `actions/ci-status` | Report CI job pass/fail with context |
| `actions/deploy-status` | Report deploy success/failure |
| `actions/playwright-verify` | Run Playwright against production URL and report result |

## Quick Start

Add to your GitHub Actions workflow (requires self-hosted runner with access to `localhost:5055`):

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cargo test
      # ... your test steps ...

  deploy:
    runs-on: self-hosted
    needs: [test]
    if: github.ref == 'refs/heads/main'
    steps:
      # ... your deploy steps ...
      - name: Notify deploy result
        if: always()
        uses: Olbrasoft/GitHub.Actions.Notify/actions/deploy-status@main
        with:
          job-status: ${{ job.status }}
          repository: ${{ github.repository }}

  verify:
    runs-on: self-hosted
    needs: [deploy]
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: Olbrasoft/GitHub.Actions.Notify/actions/playwright-verify@main
        with:
          url: https://your-production-url.com
```

## Prerequisites

- **VirtualAssistant** running on `localhost:5055` with `ci-pipeline` agent type configured
- **Self-hosted GitHub Actions runner** registered for the repository
- **Playwright** installed via npm (`npx playwright`)

## Integration Guide

See [docs/integration-guide.md](docs/integration-guide.md) for step-by-step setup instructions.

## Claude Code Skill

The `skills/ci-workflow-monitor/` skill enables Claude Code to autonomously monitor CI/CD pipeline status using CronCreate polling and react to state changes.

## License

MIT
