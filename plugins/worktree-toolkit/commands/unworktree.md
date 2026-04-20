---
name: unworktree
description: "Move a worktree's branch into the main checkout so you can test it there. Removes the worktree as a side-effect (git needs the branch freed up before it can be checked out in main). Defaults to the current worktree when invoked from inside one. Takes an optional PR number, branch name, or worktree path to pick a specific worktree. Use when the user says '/unworktree', '/unworktree 123', '/unworktree feature/foo', or 'pull this branch into main so I can test it'."
---

# Reclaim Worktree Branch Into Main

Sibling to `/worktree`. Takes the branch currently checked out in a worktree and moves it into the **main repo checkout** so the user can test it there. The worktree gets removed as a side-effect — git refuses to have the same branch checked out in two places, so the worktree has to go before the branch can be checked out in main.

This skill is a thin coordinator around two shell scripts. **Do not re-implement their logic in inline bash** — call them and react to their exit codes. The scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/`.

- `list.sh [arg]` — one call. Enumerates every worktree except main, enriches each with dirty state + last-mod + merged flag, optionally resolves `arg` to a specific entry. Returns JSON.
- `reclaim.sh <wt_path> <branch> <main_root> [--stash-main] [--stash-wt]` — one call. Optionally stashes the worktree (from inside it) and/or main, removes the worktree, checks out the branch in main, pops the stash(es). Prints a hint block on success.

**This skill never deletes a branch** — the backing branch survives reclaim untouched, it just moves from the worktree checkout to the main checkout.

## Workflow

### 1. List + default resolution

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/list.sh "${ARG:-}"
```

Parse the JSON. Fields you care about:

- `main_root` — absolute path to the main checkout
- `cur_cwd` — where the shell currently is (symlink-resolved)
- `entries[]` — every non-main worktree with enrichment
- `resolved` — non-null only if `arg` was passed; array of matching entries
- `unresolved_tokens` — tokens from `arg` that didn't match any entry

**Pick a target worktree using this priority**:

1. **`resolved` is non-null and has exactly 1 entry** → use it.
2. **`resolved` has multiple entries** → stop and ask the user which one. This skill always targets a single worktree (main can only check out one branch).
3. **No arg, and `cur_cwd` is inside one of the `entries[].path`** → that's the default. Report it to the user, then jump to step 2 without asking.
4. **No arg, not inside a worktree** → interactive picker (step 1a).
5. **`entries` is empty** → print "no worktrees to reclaim" and stop.

If `list.sh` reported `unresolved_tokens`, surface them to the user before continuing.

#### 1a. Interactive picker (only when steps 1–3 fell through)

Build an `AskUserQuestion`:

- question: `"Which worktree's branch should I pull into main?"`
- header: `"Worktree"`
- **Not multi-select** — only one worktree can be reclaimed at a time because main can only check out one branch.
- Up to 4 options from `entries[]`, sorted as-is (`list.sh` already orders missing → merged → clean → dirty). Label each option with the branch name; descriptions carry path basename, `last_mod_rel`, dirty counts, and any merged/locked/missing flags.

If `entries` has fewer than 2 rows, still offer a picker (with "Other…") — don't auto-pick a single entry silently. The user deserves a confirmation even for the one-worktree case.

### 2. Confirm destination

Before mutating anything, print a short one-liner to the user so they see the plan:

```
About to reclaim <branch> from <wt_path> into main (<main_root>).
```

No confirmation question — the skill invocation IS the confirmation. If the user wants to back out, they interrupt.

### 3. Release EnterWorktree session tracking

If this session was started by `/worktree` or any other path that called `EnterWorktree` (which is now the default for `/worktree`), Claude Code is tracking the session's project directory as the worktree. Before removing the worktree, you **must release that tracking** or the session ends up pointing at a deleted directory:

```
ExitWorktree(action="keep")
```

`action="keep"` preserves the worktree on disk (since `reclaim.sh` will remove it itself). If the session isn't tracking any worktree, `ExitWorktree` is a no-op and reports so — safe to always call.

This is what returns the desktop app's bottom bar to showing the main checkout.

### 4. Call reclaim.sh

**Important**: after `ExitWorktree(keep)`, you also need to cd via Bash if bash's cwd is inside the target worktree (they're tracked separately). The script has a guard that bails with exit code 12 if you're still inside. Do this:

```bash
cd "$MAIN_ROOT"
```

(this persists across the next bash call, because the Bash tool's cwd is session-scoped).

Then invoke — **always pass `--stash-wt` by default**. Dirty worktrees are the common case (the user is mid-work and wants to test it in main), so auto-stashing the worktree into main is the expected behavior. The stash survives `git worktree remove` (refs/stash is shared) and the script pops it back onto the checked-out branch in main.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/reclaim.sh <wt_path> <branch> <main_root> --stash-wt
```

Read the exit code:

| Exit | Meaning                                          | What to do                                                                                                                                       |
| ---- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0    | Success                                          | Print stdout verbatim to the user. **Rebind working directory to `main_root`** — see step 4. If the hint block mentions a stash-pop conflict, highlight it loudly. |
| 10   | Main checkout is dirty                           | `AskUserQuestion` → `["Stash main and continue", "Commit main first (abort)", "Cancel"]`. On "Stash and continue", re-run with `--stash-main --stash-wt`. |
| 11   | Target worktree has uncommitted changes AND `--stash-wt` was somehow omitted | You forgot to pass `--stash-wt`. Retry with it. (If you already did and still see this, something is wrong — surface stderr to the user.)       |
| 12   | You are still inside the target worktree        | You didn't cd out before calling. Do it now and retry.                                                                                           |
| 20   | Other failure                                    | Surface stderr to the user. If the stderr mentions "work is still preserved in the stash", highlight that loudly.                                |

### 5. Rebind working directory (CRITICAL)

After `reclaim.sh` succeeds, the worktree path **no longer exists**. Any subsequent tool call that references it will fail. You MUST:

1. **Bash**: ensure cwd is `main_root`. If you cd'd there in step 3, you're already fine. If not, do it now.
2. **File tools** (`Read`, `Edit`, `Write`, `Grep`, `Glob`): rewrite any path from your prior context that pointed into the worktree so it now points under `main_root`. For every path shaped like `<wt_path>/...`, the new path is `<main_root>/<...>` (same suffix).
3. **Memory of the old worktree path is now invalid.** Treat it as deleted. If the user references it, remind them it's gone.

The model is the only thing that enforces (2) and (3) — tools won't warn you about stale absolute paths.

## Notes

- **One bash call per phase.** Do not run `git worktree list`, `git status`, `git worktree remove`, etc. from the skill directly. `list.sh` and `reclaim.sh` own all of that.
- **Branch is sacred**: this skill never runs `git branch -D`. The backing branch survives; only the worktree working-tree directory is removed.
- **Stash flow**: `reclaim.sh` pops any stash it created automatically after the checkout completes. The user doesn't have to manage the stash unless the pop had conflicts (in which case the hint block says so). When both `--stash-wt` and `--stash-main` are active, the worktree stash pops first (it applies cleanly since it was taken against the target branch's HEAD); the main stash pops second and may conflict since its context was a different HEAD.
- **No concurrency guarantee**: two parallel `/unworktree` calls on the same worktree will race. The second will fail at `git worktree remove` and exit 20 — acceptable, neither leaves the repo in a weird state.
- **Symlink caveat**: `list.sh` resolves `cur_cwd` through `pwd -P`. The "am I inside a worktree" check in step 1.3 uses that resolved path, so macOS firmlinks (`/Users` → `/System/Volumes/Data/Users`) don't cause false negatives.

## What this skill is NOT

- **Not a worktree cleanup tool.** If the user wants to delete old worktrees without checking anything out, that's a separate use case — run `git worktree remove <path>` directly. This skill always checks the branch out in main, which is a different operation.
- **Not a batch operation.** Only one worktree is reclaimed per invocation. Batching doesn't make sense because main can only hold one branch at a time.
- **Not a branch deletion tool.** If the user also wants the branch gone after they're done testing, they run `git branch -D <name>` themselves. Never do this from the skill.
