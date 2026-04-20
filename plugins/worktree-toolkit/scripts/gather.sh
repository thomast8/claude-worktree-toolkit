#!/usr/bin/env bash
# gather.sh — fetch state, resolve arg, or build picker data for /worktree.
# Usage: gather.sh [arg]
#   arg is optional; numeric = PR number, non-numeric = branch name.
# Writes a single JSON object to stdout. Human warnings go to stderr.
# Schema:
#   {
#     orig_root:       "/abs/path",
#     is_graphite:     0|1,
#     resolved_branch: "branch-name" | null,
#     fetch_warn:      "message" | null,
#     picker: {
#       needs_review: [ {number,title,branch,updated_rel,author,review,ci,in_stack}, ... ],
#       mine:         [ {number,title,branch,updated_rel,review,ci,in_stack,draft},  ... ]
#     } | null
#   }

set -uo pipefail

ARG="${1:-}"

ORIG_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf '{"error":"not in a git repo"}\n'
  exit 1
}

# ---------- fetch ----------
FETCH_STDERR="$(git fetch --all 2>&1 >/dev/null)"
FETCH_RC=$?
FETCH_WARN=""
if [ "$FETCH_RC" -ne 0 ] || printf '%s\n' "$FETCH_STDERR" | grep -qE '^(fatal|error):'; then
  FETCH_WARN="fetch failed, continuing with stale local data"
fi

# ---------- graphite detection ----------
IS_GRAPHITE=0
if [ -f "$ORIG_ROOT/.graphite_repo_config" ] || gt log short --stack --no-interactive >/dev/null 2>&1; then
  IS_GRAPHITE=1
fi

# ---------- direct arg resolution ----------
RESOLVED_BRANCH=""
if [ -n "$ARG" ]; then
  ARG="${ARG#\#}"
  if [[ "$ARG" =~ ^[0-9]+$ ]]; then
    RESOLVED_BRANCH="$(gh pr view "$ARG" --json headRefName -q .headRefName 2>/dev/null || true)"
    if [ -z "$RESOLVED_BRANCH" ]; then
      printf '{"error":"could not resolve PR #%s"}\n' "$ARG"
      exit 2
    fi
  else
    RESOLVED_BRANCH="$ARG"
  fi
fi

# If we resolved directly, emit minimal JSON and stop.
if [ -n "$RESOLVED_BRANCH" ]; then
  jq -n \
    --arg orig_root "$ORIG_ROOT" \
    --argjson is_graphite "$IS_GRAPHITE" \
    --arg resolved_branch "$RESOLVED_BRANCH" \
    --arg fetch_warn "$FETCH_WARN" \
    '{
      orig_root: $orig_root,
      is_graphite: $is_graphite,
      resolved_branch: $resolved_branch,
      fetch_warn: (if $fetch_warn == "" then null else $fetch_warn end),
      picker: null
    }'
  exit 0
fi

# ---------- picker data ----------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Run both gh queries in parallel.
gh pr list \
  --search "review-requested:@me -review:approved" \
  --json number,title,headRefName,updatedAt,author,reviewDecision,statusCheckRollup \
  --limit 30 >"$TMPDIR/needs.json" 2>"$TMPDIR/needs.err" &
PID1=$!

gh pr list \
  --author @me --state open \
  --json number,title,headRefName,updatedAt,reviewDecision,statusCheckRollup,isDraft \
  --limit 30 >"$TMPDIR/mine.json" 2>"$TMPDIR/mine.err" &
PID2=$!

# Graphite stack enrichment in parallel too. Skip when on trunk or untracked.
STACK_FILE="$TMPDIR/stack.txt"
: >"$STACK_FILE"
if [ "$IS_GRAPHITE" = "1" ]; then
  (
    CURRENT="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    TRUNK="$(gt trunk 2>/dev/null || echo main)"
    if [ -n "$CURRENT" ] && [ "$CURRENT" != "$TRUNK" ]; then
      gt log short --stack --no-interactive 2>/dev/null \
        | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^[A-Za-z0-9._\/-]+$/) print $i }' \
        | sort -u >"$STACK_FILE"
    fi
  ) &
  PID3=$!
else
  PID3=""
fi

wait $PID1 || true
wait $PID2 || true
[ -n "$PID3" ] && wait $PID3 || true

# Fall back to empty arrays if gh failed.
[ -s "$TMPDIR/needs.json" ] || echo '[]' >"$TMPDIR/needs.json"
[ -s "$TMPDIR/mine.json"  ] || echo '[]' >"$TMPDIR/mine.json"

STACK_LIST="$(tr '\n' ' ' <"$STACK_FILE")"

# Merge + classify with jq. Drops mine rows whose number appears in needs (dedup).
PICKER_JSON="$(jq -n \
  --slurpfile needs "$TMPDIR/needs.json" \
  --slurpfile mine  "$TMPDIR/mine.json" \
  --arg stack "$STACK_LIST" \
  '
  def ci_status:
    if (. // []) | length == 0 then null
    else
      ([.[] | (.conclusion // .status // "")]) as $xs
      | if any($xs[]; . == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED") then "fail"
        elif any($xs[]; . == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS" or . == "WAITING") then "pending"
        else "pass"
        end
    end;
  def rel_time($iso):
    (now - ($iso | fromdateiso8601)) as $s
    | if $s < 0 then "now"
      elif $s < 3600 then "\(($s/60)|floor)m"
      elif $s < 86400 then "\(($s/3600)|floor)h"
      elif $s < 604800 then "\(($s/86400)|floor)d"
      else "\(($s/604800)|floor)w"
      end;
  ($stack | split(" ") | map(select(length > 0))) as $stackset
  | ($needs[0] // []) as $n
  | ($mine[0]  // []) as $m
  | ($n | map(.number)) as $need_nums
  | ($m | map(select(.number as $x | ($need_nums | index($x)) | not))) as $m_dedup
  | {
      needs_review: (
        $n
        | sort_by(.updatedAt)
        | map({
            number: .number,
            title: .title,
            branch: .headRefName,
            updated_rel: rel_time(.updatedAt),
            author: (.author.login // null),
            review: (.reviewDecision // null),
            ci: (.statusCheckRollup | ci_status),
            in_stack: (([.headRefName] | inside($stackset)))
          })
      ),
      mine: (
        $m_dedup
        | map({
            number: .number,
            title: .title,
            branch: .headRefName,
            updated_rel: rel_time(.updatedAt),
            review: (.reviewDecision // null),
            draft: (.isDraft // false),
            ci: (.statusCheckRollup | ci_status),
            in_stack: (([.headRefName] | inside($stackset)))
          })
        | ( (map(select(.in_stack))      | sort_by(.updated_rel) | reverse)
          + (map(select(.in_stack | not))| sort_by(.updated_rel) | reverse) )
      )
    }
  ')"

# gh auth sanity hint: bucket 2 empty despite recent local commits.
GH_AUTH_HINT=""
if [ "$(jq '.mine | length' <<<"$PICKER_JSON")" = "0" ]; then
  if [ -n "$(git log --author="$(git config user.email)" --since='7 days ago' --oneline 2>/dev/null | head -1)" ]; then
    GH_AUTH_HINT="no PRs returned for @me but you have recent local commits — check 'gh auth status'"
  fi
fi

jq -n \
  --arg orig_root "$ORIG_ROOT" \
  --argjson is_graphite "$IS_GRAPHITE" \
  --arg fetch_warn "$FETCH_WARN" \
  --arg auth_hint  "$GH_AUTH_HINT" \
  --argjson picker "$PICKER_JSON" \
  '{
    orig_root: $orig_root,
    is_graphite: $is_graphite,
    resolved_branch: null,
    fetch_warn: (if $fetch_warn == "" then null else $fetch_warn end),
    auth_hint:  (if $auth_hint  == "" then null else $auth_hint  end),
    picker: $picker
  }'
