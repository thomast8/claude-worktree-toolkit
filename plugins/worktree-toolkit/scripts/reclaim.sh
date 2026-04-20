#!/usr/bin/env bash
# reclaim.sh — move a worktree's branch into the main checkout so the user
# can test it there.
#
# Flow:
#   1. Guard: caller must not be standing inside the target worktree.
#   2. Guard: target worktree must be clean, OR --stash-wt was passed.
#   3. Stash worktree (from inside it) if --stash-wt and dirty. Stashes live
#      in the shared refs/stash ref, so they survive worktree removal.
#   4. Guard: main checkout must be clean, OR --stash-main was passed.
#   5. Stash main if needed.
#   6. git worktree remove <wt_path>          (frees the branch)
#   7. git checkout <branch>                  (in main)
#   8. git stash pop                          (worktree-stash, then main-stash)
#
# Usage:
#   reclaim.sh <wt_path> <branch> <main_root> [--stash-main] [--stash-wt] [--force-wt-dirty]
#
# Exit codes:
#   0   success (human-readable hint block on stdout)
#   10  main is dirty — caller should prompt user, re-run with --stash-main
#   11  worktree is dirty and --stash-wt was not passed — caller should commit,
#       stash, or re-run with --stash-wt to auto-migrate the changes
#   12  caller is currently inside the worktree — cd out first
#   20  other failure (stderr has details)

set -uo pipefail

if [ $# -lt 3 ]; then
  printf 'usage: reclaim.sh <wt_path> <branch> <main_root> [--stash-main] [--stash-wt] [--force-wt-dirty]\n' >&2
  exit 20
fi

WT_PATH="$1"
BRANCH="$2"
MAIN_ROOT="$3"
shift 3

STASH_MAIN=0
STASH_WT=0
FORCE_WT_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stash-main)    STASH_MAIN=1 ;;
    --stash-wt)      STASH_WT=1 ;;
    --force-wt-dirty) FORCE_WT_DIRTY=1 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 20 ;;
  esac
  shift
done

CUR_CWD="$(cd "$(pwd)" && pwd -P 2>/dev/null)" || CUR_CWD="$(pwd)"
WT_RESOLVED="$(cd "$WT_PATH" 2>/dev/null && pwd -P || printf '%s' "$WT_PATH")"
MAIN_RESOLVED="$(cd "$MAIN_ROOT" 2>/dev/null && pwd -P || printf '%s' "$MAIN_ROOT")"

# --- guard 1: caller inside target worktree? ---
case "$CUR_CWD/" in
  "$WT_RESOLVED/"*)
    printf 'current shell is inside the target worktree — cd out first, e.g.:\n' >&2
    printf '  cd %q\n' "$MAIN_RESOLVED" >&2
    exit 12
    ;;
esac

# --- guard 2 (read-only): target worktree clean, or --stash-wt acceptable? ---
# Check but do NOT mutate yet — we want to exit cleanly if guard 3 will also
# fail, otherwise a stashed worktree is left behind with no recovery path.
WT_DIRTY=0
WT_TD=0
WT_UT=0
if [ -d "$WT_RESOLVED" ]; then
  WT_TD="$(git -C "$WT_RESOLVED" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
  WT_UT="$(git -C "$WT_RESOLVED" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
  WT_TD="${WT_TD:-0}"
  WT_UT="${WT_UT:-0}"
  if [ "$WT_TD" -gt 0 ] || [ "$WT_UT" -gt 0 ]; then
    WT_DIRTY=1
    if [ "$STASH_WT" -ne 1 ] && [ "$FORCE_WT_DIRTY" -eq 0 ]; then
      printf 'worktree has uncommitted changes: %s tracked, %s untracked\n' "$WT_TD" "$WT_UT" >&2
      printf 'commit/stash inside the worktree, or re-run with --stash-wt to auto-migrate the changes\n' >&2
      exit 11
    fi
  fi
fi

cd "$MAIN_RESOLVED" || {
  printf 'cannot cd to main root: %s\n' "$MAIN_RESOLVED" >&2
  exit 20
}

# --- guard 3 (read-only): main checkout clean, or --stash-main acceptable? ---
MAIN_DIRTY=0
if [ -n "$(git status --porcelain)" ]; then
  MAIN_DIRTY=1
  if [ "$STASH_MAIN" -ne 1 ]; then
    printf 'main checkout is dirty — re-run with --stash-main to auto-stash\n' >&2
    exit 10
  fi
fi

# --- stash actions: both guards passed; now mutate ---
STASHED_WT=0
if [ "$WT_DIRTY" -eq 1 ] && [ "$STASH_WT" -eq 1 ]; then
  if ! git -C "$WT_RESOLVED" stash push -u -m "unworktree-skill: auto stash from worktree $WT_RESOLVED before reclaim of $BRANCH" >/dev/null 2>&1; then
    printf 'git stash push in worktree failed\n' >&2
    exit 20
  fi
  STASHED_WT=1
fi

STASHED=0
if [ "$MAIN_DIRTY" -eq 1 ]; then
  if ! git stash push -u -m "unworktree-skill: auto stash before reclaim of $BRANCH" >/dev/null 2>&1; then
    printf 'git stash push failed\n' >&2
    if [ "$STASHED_WT" -eq 1 ]; then
      printf 'worktree work is preserved in the stash (git stash list)\n' >&2
    fi
    exit 20
  fi
  STASHED=1
fi

PREV_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"

# --- remove worktree (frees the branch) ---
REMOVE_ERR="$(mktemp)"
if [ "$FORCE_WT_DIRTY" -eq 1 ]; then
  git worktree remove --force "$WT_RESOLVED" 2>"$REMOVE_ERR"
else
  git worktree remove "$WT_RESOLVED" 2>"$REMOVE_ERR"
fi
RC=$?
if [ $RC -ne 0 ]; then
  ERR="$(cat "$REMOVE_ERR")"
  rm -f "$REMOVE_ERR"
  printf 'git worktree remove failed: %s\n' "$ERR" >&2
  if [ "$STASHED" -eq 1 ]; then
    printf 'your main-checkout work is still preserved in the stash (git stash list)\n' >&2
  fi
  exit 20
fi
rm -f "$REMOVE_ERR"

# --- check out the branch in main ---
CHECKOUT_ERR="$(mktemp)"
if ! git checkout "$BRANCH" 2>"$CHECKOUT_ERR"; then
  ERR="$(cat "$CHECKOUT_ERR")"
  rm -f "$CHECKOUT_ERR"
  printf 'git checkout %s failed: %s\n' "$BRANCH" "$ERR" >&2
  if [ "$STASHED" -eq 1 ]; then
    printf 'your main-checkout work is still preserved in the stash (git stash list)\n' >&2
  fi
  exit 20
fi
rm -f "$CHECKOUT_ERR"

NEW_SHA="$(git rev-parse --short HEAD)"

# --- pop stash(es) if we stashed earlier ---
# Pop worktree-stash first: it was taken against this branch's HEAD, so it
# applies cleanly. Then pop main-stash (context for a different HEAD — may
# conflict, which is the user's problem to resolve).
POP_STATUS_WT=""
if [ "$STASHED_WT" -eq 1 ]; then
  if git stash pop >/dev/null 2>&1; then
    POP_STATUS_WT="restored stashed work from worktree"
  else
    POP_STATUS_WT="WARNING: worktree-stash pop had conflicts — resolve manually (git stash list, git stash show)"
  fi
fi
POP_STATUS=""
if [ "$STASHED" -eq 1 ]; then
  if git stash pop >/dev/null 2>&1; then
    POP_STATUS="restored stashed work from previous main checkout"
  else
    POP_STATUS="WARNING: stash pop had conflicts — resolve manually (git stash list, git stash show)"
  fi
fi

# --- emit hint block ---
printf 'mode:   reclaim\n'
printf 'branch: %s\n' "$BRANCH"
printf 'from:   worktree %s%s\n' "$WT_RESOLVED" "$( [ $STASHED_WT -eq 1 ] && printf ' (stashed)' )"
printf 'to:     main checkout %s\n' "$MAIN_RESOLVED"
printf 'HEAD:   %s at %s\n' "$BRANCH" "$NEW_SHA"
printf 'prev:   %s%s\n' "$PREV_BRANCH" "$( [ $STASHED -eq 1 ] && printf ' (stashed)' )"
[ -n "$POP_STATUS_WT" ] && printf 'stash:  %s\n' "$POP_STATUS_WT"
[ -n "$POP_STATUS" ] && printf 'stash:  %s\n' "$POP_STATUS"
printf '\n'
printf 'Worktree removed. You are now on %s in the main repo. Test freely.\n' "$BRANCH"
printf '\nGo back to where you were:\n'
printf '  git checkout %s\n' "$PREV_BRANCH"
