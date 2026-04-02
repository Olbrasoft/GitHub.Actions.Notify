#!/bin/bash
# Assigns a unique port for a project's Channel MCP server.
# Ports are persisted in ~/.config/claude-channels/ports.json
#
# Usage: ./assign-port.sh Olbrasoft/VirtualAssistant
# Output: 9878 (the assigned port)

set -euo pipefail

REGISTRY_DIR="$HOME/.config/claude-channels"
REGISTRY_FILE="$REGISTRY_DIR/ports.json"
BASE_PORT=9878
MAX_PORT=9999

if [ $# -lt 1 ]; then
  echo "Usage: $0 <owner/repo>" >&2
  exit 1
fi

# Check prerequisites
if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed. Install with: sudo apt install jq" >&2
  exit 1
fi

REPO="$1"

# Create registry if it doesn't exist
mkdir -p "$REGISTRY_DIR"
if [ ! -f "$REGISTRY_FILE" ]; then
  echo "{}" > "$REGISTRY_FILE"
fi

# Use flock for concurrency safety
exec 200>"${REGISTRY_FILE}.lock"
flock 200

# Check if project already has a port
EXISTING_PORT=$(jq -r --arg repo "$REPO" '.[$repo] // empty' "$REGISTRY_FILE")

if [ -n "$EXISTING_PORT" ]; then
  echo "$EXISTING_PORT"
  exit 0
fi

# Find next available port
NEXT_PORT=$(jq -r '[.[] | tonumber] | if length == 0 then '"$BASE_PORT"' else (max + 1) end' "$REGISTRY_FILE")

if [ "$NEXT_PORT" -gt "$MAX_PORT" ]; then
  echo "Error: No available ports (max $MAX_PORT reached)" >&2
  exit 1
fi

# Verify port is not already assigned to another project (collision check)
COLLISION=$(jq -r --argjson port "$NEXT_PORT" 'to_entries[] | select(.value == $port) | .key' "$REGISTRY_FILE")
if [ -n "$COLLISION" ]; then
  echo "Error: Port $NEXT_PORT already assigned to $COLLISION" >&2
  exit 1
fi

# Write new entry
jq --arg repo "$REPO" --argjson port "$NEXT_PORT" '. + {($repo): $port}' "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp"
mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"

echo "$NEXT_PORT"
