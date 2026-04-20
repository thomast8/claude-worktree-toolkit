#!/usr/bin/env bash
# Claude Code WorktreeCreate hook.
#
# Replaces the default `git worktree add` behavior so that:
#   1. Branch names conform to <type>/<slug> where
#      type in {feat,feature,fix,chore,docs,refactor,test,ci,build,perf,hotfix,release,revert,codex}
#      slug matches [a-z0-9._-]+
#   2. If a matching branch (local or remote) already exists, the existing
#      branch is checked out into the new worktree instead of creating one.
#   3. New branches are cut from origin/<default-branch>.
#
# Stdin JSON (from Claude Code):
#   { "worktree_path": "...", "isolation_source_path": "...", "cwd": "...", ... }
# Stdout: the final worktree path (single line).
# Exit non-zero aborts worktree creation.

set -euo pipefail

LOG="${HOME}/.claude/logs/worktree-create.log"
mkdir -p "$(dirname "$LOG")"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
die() { log "ERROR: $*"; printf 'worktree-create hook: %s\n' "$*" >&2; exit 1; }

input=$(cat)
log "STDIN: $input"

worktree_path=$(printf '%s' "$input" | jq -r '.worktree_path // empty')
source_path=$(printf '%s' "$input" | jq -r '.isolation_source_path // .cwd // empty')
name=$(printf '%s' "$input" | jq -r '.name // empty')

# Newer Claude Code builds send only {name, cwd}; the hook must derive the
# worktree path itself. Older builds sent {worktree_path, isolation_source_path}.
# Support both shapes so the hook survives protocol changes.
if [[ -z "$worktree_path" && -n "$name" && -n "$source_path" ]]; then
  worktree_path="${source_path}/.claude/worktrees/${name}"
  log "derived worktree_path from name: $worktree_path"
fi

[[ -n "$worktree_path" ]] || die "missing worktree_path (and no name to derive from)"
[[ -n "$source_path" && -d "$source_path" ]] || die "missing/invalid source_path: $source_path"

cd "$source_path"
git rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git repo: $source_path"

# Reuse short-circuit: if the proposed path is already a registered worktree,
# don't try to re-create it. Echo the existing path and exit 0 — the tool
# will cd into it and we skip the slug/regex logic entirely.
if git worktree list --porcelain | awk '/^worktree / {print $2}' | grep -qxF "$worktree_path"; then
  log "REUSE $worktree_path (already a registered worktree)"
  printf '%s\n' "$worktree_path"
  exit 0
fi

# Leaf name Claude proposed (everything after .claude/worktrees/)
relative="${worktree_path#*.claude/worktrees/}"
[[ -n "$relative" ]] || die "cannot parse worktree name from $worktree_path"

VALID_RE='^(feat|feature|fix|chore|docs|refactor|test|ci|build|perf|hotfix|release|revert|codex)/[a-z0-9._-]+$'

if [[ "$relative" =~ $VALID_RE ]]; then
  branch="$relative"
  final_path="$worktree_path"
else
  # Normalize to lowercase kebab-case slug, strip invalid chars, collapse dashes.
  slug=$(printf '%s' "$relative" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9./_-]#-#g; s#/+#-#g; s#-+#-#g; s#^-+##; s#-+$##')
  [[ -n "$slug" ]] || slug="session-$(date +%s)"
  branch="feat/${slug}"
  parent=$(dirname "$worktree_path")
  final_path="${parent}/${branch}"
fi

log "resolved: branch=$branch path=$final_path"

# Refresh remote refs so existing-branch detection is accurate.
git fetch --quiet origin 2>/dev/null || log "WARN: git fetch origin failed"

run_worktree_add() {
  if git worktree add "$@" >> "$LOG" 2>&1; then
    printf '%s\n' "$final_path"
    log "CREATED $final_path (branch=$branch)"
    exit 0
  fi
  die "git worktree add failed: $*"
}

if git show-ref --verify --quiet "refs/heads/${branch}"; then
  log "local branch exists; checking out"
  run_worktree_add "$final_path" "$branch"
fi

if git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
  log "remote branch exists; tracking"
  run_worktree_add --track -b "$branch" "$final_path" "origin/${branch}"
fi

default_ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
default_branch="${default_ref##*/}"
default_branch="${default_branch:-main}"
log "new branch from origin/${default_branch}"
run_worktree_add -b "$branch" "$final_path" "origin/${default_branch}"
