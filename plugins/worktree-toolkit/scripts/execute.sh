#!/usr/bin/env bash
# execute.sh — actually create the worktree (or switch checkouts).
# Usage:
#   execute.sh worktree       <branch> <orig_root> <is_graphite>
#   execute.sh switch         <branch> <orig_root> <is_graphite>
#   execute.sh switch-stashed <branch> <orig_root> <is_graphite>
#
# Exit codes:
#   0  ok (human-readable hint block printed to stdout)
#   10 dirty working tree (switch only; model should prompt stash/commit/cancel)
#   11 path collision (worktree only; path exists but is not a registered worktree)
#   12 branch not found locally or on remote
#   20 other git/setup failure (details on stderr)
#
# Copy list for gitignored dev files is configurable.
# Default: `.env .env.local .env.*.local .envrc`
# Override per-repo by creating <repo>/.claude/worktree.conf with a line:
#   WORKTREE_COPY_GLOBS=".env .env.local .env.test .envrc direnv/envrc"

set -uo pipefail

MODE="${1:-}"
BRANCH="${2:-}"
ORIG_ROOT="${3:-}"
IS_GRAPHITE="${4:-0}"

if [ -z "$MODE" ] || [ -z "$BRANCH" ] || [ -z "$ORIG_ROOT" ]; then
  printf 'usage: execute.sh <mode> <branch> <orig_root> <is_graphite>\n' >&2
  exit 20
fi

DEFAULT_COPY_GLOBS=".env .env.local .env.*.local .envrc"
COPY_CONF="$ORIG_ROOT/.claude/worktree.conf"
if [ -f "$COPY_CONF" ]; then
  # shellcheck source=/dev/null
  . "$COPY_CONF"
fi
COPY_GLOBS="${WORKTREE_COPY_GLOBS:-$DEFAULT_COPY_GLOBS}"

# --- helper: switch in-place, Graphite-aware ---
do_switch() {
  local branch="$1"
  if [ "$IS_GRAPHITE" = "1" ]; then
    if gt checkout "$branch" 2>/tmp/gt-checkout.err; then
      return 0
    fi
    local err
    err="$(cat /tmp/gt-checkout.err 2>/dev/null || true)"
    rm -f /tmp/gt-checkout.err
    if printf '%s' "$err" | grep -q 'diverged'; then
      printf '%s\n' "$err" >&2
      printf 'Graphite reports divergence. Fix with: gt track %s -f\n' "$branch" >&2
      return 20
    fi
    # Fall through to plain git (untracked-by-graphite case).
  fi
  if git -C "$ORIG_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$ORIG_ROOT" checkout "$branch"
  elif git -C "$ORIG_ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$ORIG_ROOT" checkout -t "origin/$branch"
  else
    printf 'branch not found: %s\n' "$branch" >&2
    return 12
  fi
}

case "$MODE" in
  # ------------------------------------------------------------------ worktree
  worktree)
    SAFE_NAME="${BRANCH//\//-}"
    WT_PATH="$ORIG_ROOT/.claude/worktrees/$SAFE_NAME"

    # Is it already a live worktree? Reuse.
    REUSED=0
    if git -C "$ORIG_ROOT" worktree list --porcelain \
         | awk '/^worktree / {print $2}' \
         | grep -qxF "$WT_PATH"; then
      REUSED=1
    elif [ -e "$WT_PATH" ]; then
      printf 'collision: %s exists but is not a registered worktree\n' "$WT_PATH" >&2
      exit 11
    else
      # Verify branch exists locally or on remote.
      HAS_LOCAL=0; HAS_REMOTE=0
      git -C "$ORIG_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"         && HAS_LOCAL=1
      git -C "$ORIG_ROOT" show-ref --verify --quiet "refs/remotes/origin/$BRANCH" && HAS_REMOTE=1

      if [ $HAS_LOCAL -eq 0 ] && [ $HAS_REMOTE -eq 0 ]; then
        printf 'branch not found locally or on remote: %s\n' "$BRANCH" >&2
        exit 12
      fi

      ADD_ERR_FILE="$(mktemp)"
      if [ $HAS_LOCAL -eq 1 ]; then
        git -C "$ORIG_ROOT" worktree add "$WT_PATH" "$BRANCH" 2>"$ADD_ERR_FILE"
      else
        git -C "$ORIG_ROOT" worktree add -b "$BRANCH" --track "$WT_PATH" "origin/$BRANCH" 2>"$ADD_ERR_FILE"
      fi
      ADD_RC=$?

      if [ $ADD_RC -ne 0 ]; then
        ADD_ERR="$(cat "$ADD_ERR_FILE")"
        rm -f "$ADD_ERR_FILE"
        if printf '%s' "$ADD_ERR" | grep -q 'already checked out'; then
          # Fall back to detached worktree with a warning.
          if ! git -C "$ORIG_ROOT" worktree add --detach "$WT_PATH" "$BRANCH" 2>/dev/null; then
            printf 'worktree add --detach failed for %s\n' "$BRANCH" >&2
            exit 20
          fi
          DETACHED_WARN="branch is already checked out elsewhere; this worktree is DETACHED — do not commit directly"
        else
          printf '%s\n' "$ADD_ERR" >&2
          exit 20
        fi
      else
        rm -f "$ADD_ERR_FILE"
      fi
    fi

    # Pull latest from remote if the branch is tracking one. Fast-forward only.
    PULL_MSG="not tracking a remote"
    if git -C "$WT_PATH" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      PULL_OUT="$(git -C "$WT_PATH" pull --ff-only 2>&1 || echo '__PULL_FAILED__')"
      if printf '%s' "$PULL_OUT" | grep -q '__PULL_FAILED__'; then
        PULL_MSG="pull failed (non-ff?) — check manually"
      elif printf '%s' "$PULL_OUT" | grep -q 'Already up to date'; then
        PULL_MSG="already at remote tip"
      else
        PULL_MSG="pulled latest from remote"
      fi
    fi

    # Copy gitignored dev files from ORIG_ROOT into the worktree.
    COPIED=""
    SKIPPED=""
    shopt -s nullglob
    # Word-split COPY_GLOBS on whitespace into an array.
    # shellcheck disable=SC2206
    COPY_ARR=( $COPY_GLOBS )
    for pattern in "${COPY_ARR[@]}"; do
      # Intentionally unquoted so shell expands the glob.
      for src in "$ORIG_ROOT"/$pattern; do
        [ -f "$src" ] || continue
        rel="${src#"$ORIG_ROOT"/}"
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

    # --- emit hint block ---
    printf 'mode:   worktree%s\n' "$( [ $REUSED -eq 1 ] && printf ' (reused existing)' )"
    printf 'branch: %s\n' "$BRANCH"
    printf 'path:   %s\n' "$WT_PATH"
    printf 'pull:   %s\n' "$PULL_MSG"
    printf 'copied: %s\n' "${COPIED:-none}"
    [ -n "$SKIPPED" ] && printf 'skipped (already present): %s\n' "$SKIPPED"
    [ -n "${DETACHED_WARN:-}" ] && printf 'WARNING: %s\n' "$DETACHED_WARN"
    printf '\n'
    printf 'Next:\n'
    printf '  cd %q\n' "$WT_PATH"
    printf '\nReturn to main repo:\n'
    printf '  cd %q\n' "$ORIG_ROOT"
    printf '\nClean up when done:\n'
    printf '  git worktree remove %q\n' "$WT_PATH"
    ;;

  # ------------------------------------------------------------------ switch
  switch)
    cd "$ORIG_ROOT" || { printf 'cannot cd to %s\n' "$ORIG_ROOT" >&2; exit 20; }

    if [ -n "$(git status --porcelain)" ]; then
      printf 'dirty working tree\n' >&2
      exit 10
    fi

    PREV_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
    if [ "$PREV_BRANCH" = "$BRANCH" ]; then
      printf 'already on %s — nothing to do\n' "$BRANCH"
      exit 0
    fi

    if ! do_switch "$BRANCH"; then
      exit $?
    fi

    NEW_SHA="$(git rev-parse --short HEAD)"
    printf 'mode:    switch\n'
    printf 'from:    %s\n' "$PREV_BRANCH"
    printf 'to:      %s at %s\n' "$BRANCH" "$NEW_SHA"
    printf '\nHop back with:\n'
    if [ "$IS_GRAPHITE" = "1" ]; then
      printf '  gt checkout %s\n' "$PREV_BRANCH"
    else
      printf '  git checkout -\n'
    fi
    ;;

  # --------------------------------------------------- switch after stashing
  switch-stashed)
    cd "$ORIG_ROOT" || { printf 'cannot cd to %s\n' "$ORIG_ROOT" >&2; exit 20; }

    if ! git stash push -u -m "worktree-skill: auto stash before switch" >/dev/null 2>&1; then
      printf 'stash push failed\n' >&2
      exit 20
    fi
    STASHED=1

    PREV_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"

    if ! do_switch "$BRANCH"; then
      RC=$?
      printf 'switch failed after stash — your work is preserved in the stash\n' >&2
      exit $RC
    fi

    NEW_SHA="$(git rev-parse --short HEAD)"
    printf 'mode:    switch (stashed prior changes)\n'
    printf 'from:    %s\n' "$PREV_BRANCH"
    printf 'to:      %s at %s\n' "$BRANCH" "$NEW_SHA"
    printf '\nHop back with:\n'
    if [ "$IS_GRAPHITE" = "1" ]; then
      printf '  gt checkout %s\n' "$PREV_BRANCH"
    else
      printf '  git checkout -\n'
    fi
    printf '\nRestore stashed work with:\n'
    printf '  git stash pop\n'
    ;;

  *)
    printf 'unknown mode: %s\n' "$MODE" >&2
    exit 20
    ;;
esac
