#!/bin/bash
# Register a new self-hosted GitHub Actions runner for an Olbrasoft repository.
# Usage: ./setup-runner.sh <owner/repo>
#
# Example: ./setup-runner.sh Olbrasoft/cr
#
# Prerequisites:
#   - gh CLI authenticated
#   - sudo access (for systemd service installation)

set -euo pipefail

REPO="${1:?Usage: $0 <owner/repo> (e.g., Olbrasoft/cr)}"
REPO_SHORT="${REPO##*/}"
RUNNER_DIR="$HOME/actions-runner-${REPO_SHORT}"

echo "=== Setting up self-hosted runner for ${REPO} ==="
echo "Runner directory: ${RUNNER_DIR}"
echo ""

# Check prerequisites
if ! command -v gh &> /dev/null; then
  echo "ERROR: gh CLI is required. Install: https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status &> /dev/null; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

# Check if runner directory already exists
if [ -d "$RUNNER_DIR" ]; then
  echo "WARNING: Directory ${RUNNER_DIR} already exists."
  read -rp "Continue? (y/N) " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# Create runner directory
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# Download latest runner
echo "Downloading latest GitHub Actions runner..."
RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
RUNNER_ARCH="linux-x64"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

curl -sL "$RUNNER_URL" | tar xz

# Get registration token
echo "Getting registration token..."
TOKEN=$(gh api "repos/${REPO}/actions/runners/registration-token" --jq '.token')

# Configure runner
echo "Configuring runner..."
./config.sh --url "https://github.com/${REPO}" --token "$TOKEN" --name "$(hostname)-${REPO_SHORT}" --work "_work" --unattended

# Install as systemd service
echo ""
echo "Installing as systemd service..."
sudo ./svc.sh install "$(whoami)"
sudo systemctl enable "actions.runner.${REPO/\//-}.$(hostname)-${REPO_SHORT}.service"
sudo systemctl start "actions.runner.${REPO/\//-}.$(hostname)-${REPO_SHORT}.service"

echo ""
echo "=== Runner setup complete ==="
echo "Directory: ${RUNNER_DIR}"
echo "Service:   actions.runner.${REPO/\//-}.$(hostname)-${REPO_SHORT}.service"
echo ""
echo "Verify: sudo systemctl status actions.runner.${REPO/\//-}.$(hostname)-${REPO_SHORT}.service"
echo "Also check: https://github.com/${REPO}/settings/actions/runners"
