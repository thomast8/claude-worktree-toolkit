---
name: worktree
description: "Create a git worktree or switch checkout for a PR number, branch name, or an interactively picked 'live' branch (your open PRs + PRs needing your review, Graphite-aware). Worktree mode pulls latest from remote and copies gitignored dev files so the new tree is immediately runnable. Use when the user says '/worktree', '/worktree 123', '/worktree feature/my-branch', or wants to hop onto an existing PR without losing their current checkout."
---

# Create Git Worktree / Switch Checkout

This skill is a thin coordinator around a few shell scripts plus the native `EnterWorktree` tool. **Do not re-implement their logic in inline bash** — call them and react to their output/exit codes. Scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/`.

- `gather.sh [arg]` — one call. Fetches, detects Graphite, either resolves `arg` to a branch or gathers picker data. Returns JSON.
- `EnterWorktree(name=<branch>)` — native tool. Creates the worktree via the `WorktreeCreate` hook at `${CLAUDE_PLUGIN_ROOT}/hooks/worktree-create.sh` AND switches the session's project directory into it. **This is how the desktop app's bottom bar follows the worktree.** The hook handles existing-branch checkout, new-branch creation, and reuse of existing worktrees.
- `post-enter.sh <main_root>` — runs INSIDE the new worktree after `EnterWorktree`. Pulls latest from the remote and copies gitignored dev files from main so the worktree is immediately runnable.
- `execute.sh switch <branch> <main_root> <is_graphite>` — used ONLY for "switch checkout" mode, not for worktree creation.

## Workflow

### 1. Gather

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/gather.sh "${ARG:-}"
```

Parse the JSON. Fields you care about:

- `orig_root` — absolute path to the repo toplevel (needed for `execute.sh`)
- `is_graphite` — 0 or 1
- `resolved_branch` — set if the user passed an arg; null otherwise
- `fetch_warn` — surface to the user if non-null ("fetch failed, continuing with stale local data")
- `auth_hint` — surface to the user if non-null (possible `gh` auth account mismatch)
- `picker.needs_review` — array of PR rows (only when `resolved_branch` is null)
- `picker.mine` — array of PR rows (only when `resolved_branch` is null)

If `gather.sh` exits non-zero or the JSON contains `error`, stop and report the error to the user.

### 2. Resolve target branch

**Case A — `resolved_branch` is non-null**: use it directly. Jump to step 3.

**Case B — `resolved_branch` is null**: build an `AskUserQuestion` payload from the picker rows:

- Up to **2 rows** from `needs_review` (already sorted oldest-first — aging review requests are most urgent).
- Up to **2 rows** from `mine` (already sorted stack-first, then newest-first within tiers).
- If one bucket is short, pad with the other bucket up to 4 options total.
- Each option label: `"#<number> <truncated title>"`.
- Each option description: bucket + review/CI glyphs + `updated_rel` + author (needs-review only) + `· stack` if `in_stack`.
- `AskUserQuestion` auto-appends "Other…" — treat a user "Other" answer as free-text. Strip leading `#`. If it parses as an integer, re-run `gather.sh <num>` to resolve. Otherwise use it as a branch name.

Render a short pre-prompt summary line above the question so the user sees context, e.g.:
`"Pulled N live PRs (X needs-review, Y mine). Pick one:"`

**Zero rows across both buckets**: fall back to a Minimal Picker with options `[current branch, main, Other…]`.

### 3. Mode question

Ask once, **before** any mutation:

- question: `"How do you want to work on <branch>?"`
- header: `"Mode"`
- options:
  - `"Open as worktree"` — isolated path under `.claude/worktrees/`, parallel with current checkout. **Default for reviewing teammate PRs.**
  - `"Switch checkout"` — `gt checkout` / `git checkout` in the current tree. Fast but replaces current branch.
  - `"Cancel"` — back out.

Treat user "Other" here as Cancel (no useful semantics).

### 4. Execute — worktree mode

**This is the happy path.** The `WorktreeCreate` hook + `EnterWorktree` together handle path derivation, existing-branch checkout, and session switching. You only have to do three steps:

1. **Call `EnterWorktree` with the branch name as the `name` parameter.** The hook interprets `name` as `<type>/<slug>` (must match `feat|feature|fix|chore|docs|refactor|test|ci|build|perf|hotfix|release|revert|codex` and a kebab-case slug) and:
   - If the worktree already exists at the derived path → reuses it
   - Else if a local branch of that name exists → checks it out into the new worktree
   - Else if a remote branch of that name exists → creates a tracking worktree
   - Else → creates a new branch off `origin/<default>` (almost never what you want for `/worktree`, so if this happens with a user-named branch something is wrong)

   ```
   EnterWorktree(name="fix/db-recreate")
   ```

   After this call returns success, **the session is now anchored in the worktree**. `pwd` in the next bash call will report the worktree path. The desktop app's bottom bar will follow. No manual `cd`, no file-tool path rewriting — the session moved.

2. **Call `post-enter.sh` with the main repo path as its arg.** The main repo path is `gather.sh`'s `orig_root` field. This runs inside the new worktree and does:
   - `git pull --ff-only` if the branch tracks a remote
   - Copy gitignored dev files (`.env*`, `.envrc`) from main so the worktree is immediately runnable
   - Print a hint block

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/post-enter.sh <orig_root>
   ```

3. **Relay the hint block to the user**, along with any warnings from gather (`fetch_warn`, `auth_hint`).

#### What if EnterWorktree fails?

If `EnterWorktree` errors (branch doesn't match the hook's regex, hook itself errors, branch is already checked out somewhere git refuses to share, etc.), fall back to the legacy path:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/execute.sh worktree <branch> <orig_root> <is_graphite>
```

This uses plain `git worktree add` without the session switch. The desktop bottom bar won't follow, and you'll have to manually `cd` + rewrite file-tool paths (see the "Legacy rebind discipline" section below). Only use this as a fallback — always try `EnterWorktree` first.

**Don't silently fall back.** If `EnterWorktree` fails, tell the user why (surface the error verbatim) and ask if they want the fallback, or if they'd rather debug the hook. The fallback loses the main feature (session switch).

### 5. Execute — switch mode

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/execute.sh switch <branch> <orig_root> <is_graphite>
```

Read the exit code:

| Exit | Meaning                              | What to do                                                                                                                                           |
| ---- | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | Success                              | Print stdout verbatim. No rebind needed — switch mode doesn't move between directories, just changes HEAD in place.                                  |
| 10   | Dirty working tree                   | `AskUserQuestion` → `["Stash and continue", "Commit first", "Cancel"]`. On "Stash and continue", re-run with mode `switch-stashed`.                 |
| 12   | Branch not found                     | Report and stop.                                                                                                                                     |
| 20   | Other failure                        | Surface stderr verbatim and stop.                                                                                                                    |

### 6. Legacy rebind discipline (fallback path only)

**Skip this section entirely if you used `EnterWorktree` successfully** — the session switch handled everything.

If you had to fall back to `execute.sh worktree`, the session was NOT switched. You need to manually keep Claude's attention on the worktree:

1. **Bash**: issue a single `cd <wt_path>` call. The Bash tool's cwd persists across calls in the same session.
2. **File tools (`Read`, `Edit`, `Write`, `Grep`, `Glob`, `NotebookEdit`, `LSP`)**: take absolute paths and don't respect bash's cwd. Route every subsequent file-tool call through `<wt_path>/...`.
3. **Absolute paths from memory or prior tool results**: any path that starts with the main repo root must be rewritten to start with `<wt_path>`.
4. **The main repo path is off-limits** unless the user explicitly asks about a different branch.

This is exactly the discipline the legacy manual-worktree flow required, and it's error-prone — that's why `EnterWorktree` + the hook is now the happy path. Use the fallback only when forced.

## Configuring copied dev files

`execute.sh` copies gitignored files matching a whitelist of globs into the new worktree so it's immediately runnable. Default globs: `.env .env.local .env.*.local .envrc`.

**Per-repo override**: create `<repo>/.claude/worktree.conf` with a single line:
```sh
WORKTREE_COPY_GLOBS=".env .env.local .env.test .envrc direnv/envrc"
```

The conf file is sourced at the top of `execute.sh`. Don't add `node_modules`, `.venv`, or similar — those can break because they contain absolute paths baked in at install time. The user should run their normal setup commands inside the new worktree.

## Notes

- **One bash call per phase.** Do not run `git fetch`, `git worktree list`, `gh pr view`, etc. from the skill directly — those live in the scripts. Your job is: gather → ask → execute → relay.
- **Never bypass the mode question.** Always ask before mutating, even when the arg was explicit.
- **Never delete files.** `execute.sh` never removes anything; its output suggests `git worktree remove` as user-initiated cleanup.
- **Account hygiene**: the skill doesn't touch git user config. If `auth_hint` fires, surface it but don't auto-fix.
- **`gt sync` is not this skill's job**: `/reconcile` handles fetching + rebasing. This skill just gets the user onto a branch; it does not cascade rebases.
- **Concurrency**: two parallel `/worktree` invocations on the same branch will race at `git worktree add`. The second will be caught by the reuse check in `execute.sh` and reuse the first. No locking needed.
