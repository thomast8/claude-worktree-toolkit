#!/usr/bin/env bash
# list.sh — enumerate removable worktrees, enrich with state, optionally resolve arg.
# Usage: list.sh [arg]
#   arg is optional. If set: tokens separated by comma or whitespace. Each token
#   may be a PR number, a branch name, or an absolute/relative path that
#   resolves to an existing worktree.
# Output: single JSON object on stdout.
#   {
#     main_root: "/abs/path",           # main checkout, NEVER in entries
#     cur_cwd:   "/abs/path",           # symlink-resolved current shell dir
#     trunk:     "main",                # detected trunk branch name
#     entries: [
#       {
#         path, head, branch, detached, locked, lock_reason, bare,
#         missing, tracked_dirty, untracked, last_mod_rel, merged
#       }, ...
#     ],
#     resolved: [ <subset of entries matching arg> ] | null,
#     unresolved_tokens: [ "token", ... ]   # tokens that did not match any entry
#   }

set -uo pipefail

ARG="${1:-}"

CUR_CWD="$(cd "$(pwd)" && pwd -P 2>/dev/null)" || CUR_CWD="$(pwd)"

TRUNK="$(gt trunk 2>/dev/null \
         || git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' \
         || echo main)"
TRUNK_SHA="$(git rev-parse "$TRUNK" 2>/dev/null || true)"

WT_RAW="$(git worktree list --porcelain 2>/dev/null || true)"
if [ -z "$WT_RAW" ]; then
  printf '{"error":"not in a git repo or git worktree list failed"}\n'
  exit 1
fi

# --- parse porcelain blocks into JSON lines, one per worktree ---
parse_porcelain() {
  local path="" head="" branch="" detached="false" locked="false" lock_reason="" bare="false"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      if [ -n "$path" ]; then
        jq -cn \
          --arg path "$path" --arg head "$head" --arg branch "$branch" \
          --argjson detached "$detached" --argjson locked "$locked" \
          --arg lock_reason "$lock_reason" --argjson bare "$bare" \
          '{path:$path, head:$head, branch:$branch, detached:$detached, locked:$locked, lock_reason:$lock_reason, bare:$bare}'
      fi
      path=""; head=""; branch=""; detached="false"; locked="false"; lock_reason=""; bare="false"
      continue
    fi
    case "$line" in
      "worktree "*)           path="${line#worktree }" ;;
      "HEAD "*)               head="${line#HEAD }" ;;
      "branch refs/heads/"*)  branch="${line#branch refs/heads/}" ;;
      "detached")             detached="true" ;;
      "bare")                 bare="true" ;;
      "locked"|"locked "*)    locked="true"; lock_reason="${line#locked}"; lock_reason="${lock_reason# }" ;;
    esac
  done
  if [ -n "$path" ]; then
    jq -cn \
      --arg path "$path" --arg head "$head" --arg branch "$branch" \
      --argjson detached "$detached" --argjson locked "$locked" \
      --arg lock_reason "$lock_reason" --argjson bare "$bare" \
      '{path:$path, head:$head, branch:$branch, detached:$detached, locked:$locked, lock_reason:$lock_reason, bare:$bare}'
  fi
}

PARSED_LINES="$(printf '%s\n\n' "$WT_RAW" | parse_porcelain)"

# First block = main checkout (git always lists it first).
MAIN_ROOT="$(printf '%s' "$PARSED_LINES" | head -n1 | jq -r '.path')"

# --- enrich each non-main, non-bare entry ---
now_epoch="$(date +%s)"

rel_time() {
  local mtime="$1"
  [ -z "$mtime" ] && { printf '?'; return; }
  local age=$(( now_epoch - mtime ))
  if   [ $age -lt 60 ];     then printf 'just now'
  elif [ $age -lt 3600 ];   then printf '%dm' $(( age / 60 ))
  elif [ $age -lt 86400 ];  then printf '%dh' $(( age / 3600 ))
  elif [ $age -lt 604800 ]; then printf '%dd' $(( age / 86400 ))
  else printf '%dw' $(( age / 604800 ))
  fi
}

ENRICHED_LINES=""
while IFS= read -r entry; do
  [ -z "$entry" ] && continue

  path="$(printf '%s' "$entry" | jq -r '.path')"
  head="$(printf '%s' "$entry" | jq -r '.head')"
  bare="$(printf '%s' "$entry" | jq -r '.bare')"

  # Skip main + bare
  [ "$path" = "$MAIN_ROOT" ] && continue
  [ "$bare" = "true" ] && continue

  if [ -d "$path" ]; then
    missing="false"
    tracked_dirty="$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
    untracked="$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
    mtime="$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo '')"
    last_mod_rel="$(rel_time "$mtime")"
  else
    missing="true"
    tracked_dirty=0
    untracked=0
    last_mod_rel="missing"
  fi

  merged="false"
  if [ -n "$TRUNK_SHA" ] && [ -n "$head" ] && [ "$head" = "$TRUNK_SHA" ]; then
    merged="true"
  fi

  ENRICHED_LINES+="$(printf '%s' "$entry" | jq -c \
    --argjson missing "$missing" \
    --argjson tracked_dirty "$tracked_dirty" \
    --argjson untracked "$untracked" \
    --arg     last_mod_rel "$last_mod_rel" \
    --argjson merged "$merged" \
    '. + {missing:$missing, tracked_dirty:$tracked_dirty, untracked:$untracked, last_mod_rel:$last_mod_rel, merged:$merged}')
"
done <<< "$PARSED_LINES"

ENRICHED_JSON="$(printf '%s' "$ENRICHED_LINES" | jq -s '
  sort_by(
    # Missing first, then merged, then dirty last, breaking ties by most recent.
    [ (if .missing then 0 elif .merged and .tracked_dirty == 0 and .untracked == 0 then 1
        elif (.tracked_dirty > 0 or .untracked > 0) then 3 else 2 end),
      .last_mod_rel ]
  )
')"

# --- optional arg resolution ---
RESOLVED_JSON="null"
UNRESOLVED_JSON="[]"

if [ -n "$ARG" ]; then
  # Split arg on commas and whitespace into tokens.
  # shellcheck disable=SC2206
  TOKENS=( ${ARG//,/ } )

  RESOLVED="[]"
  UNRESOLVED="[]"

  for tok in "${TOKENS[@]}"; do
    [ -z "$tok" ] && continue
    tok="${tok#\#}"

    match=""
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      branch_name="$(gh pr view "$tok" --json headRefName -q .headRefName 2>/dev/null || true)"
      if [ -n "$branch_name" ]; then
        match="$(printf '%s' "$ENRICHED_JSON" | jq -c --arg b "$branch_name" '.[] | select(.branch == $b)')"
      fi
    else
      # Try as exact branch name first.
      match="$(printf '%s' "$ENRICHED_JSON" | jq -c --arg b "$tok" '.[] | select(.branch == $b)')"
      if [ -z "$match" ]; then
        # Try as path (absolute or resolvable to an entry path).
        abs=""
        if [ -e "$tok" ]; then
          abs="$(cd "$tok" 2>/dev/null && pwd -P || true)"
        fi
        [ -z "$abs" ] && abs="$tok"
        match="$(printf '%s' "$ENRICHED_JSON" | jq -c --arg p "$abs" '.[] | select(.path == $p)')"
      fi
    fi

    if [ -n "$match" ]; then
      RESOLVED="$(printf '%s\n%s' "$RESOLVED" "$match" | jq -s 'add // .[0] + [.[-1]]' 2>/dev/null \
                   || printf '%s' "$RESOLVED" | jq --argjson m "$match" '. + [$m]')"
    else
      UNRESOLVED="$(printf '%s' "$UNRESOLVED" | jq --arg t "$tok" '. + [$t]')"
    fi
  done

  RESOLVED_JSON="$RESOLVED"
  UNRESOLVED_JSON="$UNRESOLVED"
fi

jq -n \
  --arg main_root "$MAIN_ROOT" \
  --arg cur_cwd   "$CUR_CWD" \
  --arg trunk     "$TRUNK" \
  --argjson entries  "$ENRICHED_JSON" \
  --argjson resolved "$RESOLVED_JSON" \
  --argjson unresolved_tokens "$UNRESOLVED_JSON" \
  '{
    main_root: $main_root,
    cur_cwd:   $cur_cwd,
    trunk:     $trunk,
    entries:   $entries,
    resolved:  $resolved,
    unresolved_tokens: $unresolved_tokens
  }'
