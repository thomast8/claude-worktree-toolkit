#!/usr/bin/env bash
# post-enter.sh — finishing touches after EnterWorktree has switched the
# session into a new worktree.
#
# Runs INSIDE the worktree (cwd is assumed to already be the worktree root).
#
# Does two things:
#   1. git pull --ff-only   (if the current branch tracks a remote)
#   2. Copies gitignored dev files (.env, .env.local, .env.*.local, .envrc by
#      default) from the main repo root, so the worktree is immediately
#      runnable without re-setup.
#
# Usage:
#   post-enter.sh <main_root>
#     <main_root> is the path to the main repo (where env files live).
#
# Output: human-readable hint block on stdout. Warnings to stderr.
# Exit code: 0 always (missing-remote / failed-pull / no-env-files are not
#   errors — the worktree is already usable).
#
# Copy-globs default is `.env .env.local .env.*.local .envrc`.
# Override per-repo by creating <main_root>/.claude/worktree.conf with:
#   WORKTREE_COPY_GLOBS=".env .env.local .env.test .envrc"

set -uo pipefail

MAIN_ROOT="${1:-}"
if [ -z "$MAIN_ROOT" ] || [ ! -d "$MAIN_ROOT" ]; then
  printf 'usage: post-enter.sh <main_root>\n' >&2
  exit 0
fi

WT_PATH="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"

# --- pull latest if tracking a remote ---
# Strategy:
#   1. If no remote tracking: skip.
#   2. Try --ff-only first (safe, preserves unpushed local commits).
#   3. If non-ff and working tree is clean: hard-reset to @{u}. PR branches
#      diverge from remote after Graphite restacks / force-pushes, and the
#      remote is authoritative. Clean tree = no uncommitted work to lose.
#   4. If non-ff and working tree is dirty: bail out with a message.
PULL_MSG="not tracking a remote"
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  PULL_OUT="$(git pull --ff-only 2>&1 || printf '__PULL_FAILED__')"
  if printf '%s' "$PULL_OUT" | grep -q '__PULL_FAILED__'; then
    # Non-ff. Check if tree is clean before attempting hard reset.
    if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
      UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
      git fetch --quiet 2>/dev/null || true
      LOCAL_AHEAD="$(git rev-list --count "${UPSTREAM}..HEAD" 2>/dev/null || echo 0)"
      REMOTE_AHEAD="$(git rev-list --count "HEAD..${UPSTREAM}" 2>/dev/null || echo 0)"
      if git reset --hard "@{u}" >/dev/null 2>&1; then
        PULL_MSG="reset to ${UPSTREAM} (was diverged: local +${LOCAL_AHEAD}, remote +${REMOTE_AHEAD}; tree was clean)"
      else
        PULL_MSG="pull failed (non-ff, reset also failed) — check manually"
      fi
    else
      PULL_MSG="pull failed (non-ff, tree dirty) — commit/stash then pull manually"
    fi
  elif printf '%s' "$PULL_OUT" | grep -q 'Already up to date'; then
    PULL_MSG="already at remote tip"
  else
    PULL_MSG="pulled latest from remote"
  fi
fi

# --- copy gitignored dev files from main ---
DEFAULT_COPY_GLOBS=".env .env.local .env.*.local .envrc"
COPY_CONF="$MAIN_ROOT/.claude/worktree.conf"
if [ -f "$COPY_CONF" ]; then
  # shellcheck source=/dev/null
  . "$COPY_CONF"
fi
COPY_GLOBS="${WORKTREE_COPY_GLOBS:-$DEFAULT_COPY_GLOBS}"

COPIED=""
SKIPPED=""
shopt -s nullglob
# shellcheck disable=SC2206
COPY_ARR=( $COPY_GLOBS )
for pattern in "${COPY_ARR[@]}"; do
  for src in "$MAIN_ROOT"/$pattern; do
    [ -f "$src" ] || continue
    rel="${src#"$MAIN_ROOT"/}"
    dst="$WT_PATH/$rel"
    if [ -e "$dst" ]; then
      SKIPPED="${SKIPPED}${rel} "
      continue
    fi
    mkdir -p "$(dirname "$dst")"
    if cp "$src" "$dst" 2>/dev/null; then
      COPIED="${COPIED}${rel} "
    fi
  done
done
shopt -u nullglob

# --- hint block ---
printf 'mode:   worktree (EnterWorktree + hook)\n'
printf 'branch: %s\n' "$BRANCH"
printf 'path:   %s\n' "$WT_PATH"
printf 'pull:   %s\n' "$PULL_MSG"
printf 'copied: %s\n' "${COPIED:-none}"
[ -n "$SKIPPED" ] && printf 'skipped (already present): %s\n' "$SKIPPED"
printf '\n'
printf 'Session is now anchored in the worktree. The desktop app bottom bar\n'
printf 'should reflect the new branch. All subsequent bash calls AND file\n'
printf 'tools should resolve against: %s\n' "$WT_PATH"
