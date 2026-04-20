#!/usr/bin/env bash
# Claude Code WorktreeRemove hook. Logs removal for visibility; failures are
# swallowed by Claude Code so this never blocks cleanup.
set -euo pipefail

LOG="${HOME}/.claude/logs/worktree-create.log"
mkdir -p "$(dirname "$LOG")"

input=$(cat)
printf '[%s] REMOVE %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(printf '%s' "$input" | jq -r '.worktree_path // "?"')" >> "$LOG"
exit 0
