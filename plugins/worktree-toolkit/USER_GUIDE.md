# worktree-toolkit — user guide

Five real scenarios, shown end-to-end. Every example assumes you're running Claude Code with this plugin installed and enabled.

---

## Scenario 1 — Review a teammate's PR without blowing up your current work

You're mid-feature. A teammate asks you to review PR #412. You don't want to stash, lose your undo stack, or re-set up your env.

```text
you: /worktree 412
```

What happens:

1. `gather.sh` fetches, detects Graphite, resolves `#412` to the head branch (say `feature/rate-limit-fallback`).
2. Claude asks "How do you want to work on `feature/rate-limit-fallback`? [Open as worktree] [Switch checkout] [Cancel]". Pick **Open as worktree** — this is the whole point.
3. `EnterWorktree(name="feature/rate-limit-fallback")` runs. The `WorktreeCreate` hook checks out the existing remote branch into `<repo>/.claude/worktrees/feature-rate-limit-fallback/`. **Your session's project directory follows the new worktree** — the Claude desktop app's bottom bar now shows the worktree path.
4. `post-enter.sh` pulls latest and copies your `.env` files into the worktree so the app is immediately runnable.

Your original feature branch is untouched in the main checkout. When you're done reviewing, either close the session (the worktree stays on disk for next time) or use `/unworktree` (Scenario 3).

---

## Scenario 2 — Open a specific branch by name

You already know the branch name — no PR lookup needed.

```text
you: /worktree feature/db-recreate
```

Same flow as Scenario 1, minus the PR resolution step. The `WorktreeCreate` hook's logic:

- Does a worktree already exist at the derived path? → **reuse it** (fast).
- Else does a local branch of that name exist? → **check it out** into the new worktree.
- Else does a remote branch of that name exist? → **create a tracking worktree**.
- Else → cut a new branch from `origin/main`. (Rare and usually wrong for `/worktree` — the hook will tell you this happened.)

Branch names must match `<type>/<slug>` where `type ∈ {feat, feature, fix, chore, docs, refactor, test, ci, build, perf, hotfix, release, revert, codex}` and `slug` is lowercase-kebab-case. The hook enforces this; an invalid name aborts with a clear error.

---

## Scenario 3 — Pull a branch back into main so you can test it end-to-end

Say you've been reviewing `/worktree 412` and now want to run the full test suite or a `docker compose up` in your main checkout. Main checkouts often have a `venv`, cached artifacts, or running services that the worktree doesn't.

From inside the worktree session:

```text
you: /unworktree
```

What happens:

1. `list.sh` enumerates all worktrees, notices your session is inside one, and defaults to it.
2. Claude says `"About to reclaim feature/rate-limit-fallback from <path> into main (<main_root>)."`
3. `ExitWorktree(action="keep")` releases the session's tracking of the worktree.
4. Claude `cd`s to main.
5. `reclaim.sh --stash-wt` stashes any uncommitted work from the worktree, removes the worktree, checks out the branch in main, pops the stash.
6. Your session's project directory is now main, with `feature/rate-limit-fallback` checked out.

**The branch itself is not deleted** — only the worktree working-tree directory is removed. You can recreate the worktree later with `/worktree feature/rate-limit-fallback` if you need.

---

## Scenario 4 — Pick a PR interactively when you don't remember the number

```text
you: /worktree
```

You get a picker with up to 4 options:
- The 2 oldest PRs waiting on your review (review-debt ages fast)
- Your 2 most recent open PRs (stack-first ordering when Graphite is in play)
- An **Other…** free-text option for typing a branch name or PR number

Pre-prompt summary line above the question: e.g. *"Pulled 9 live PRs (3 needs-review, 6 mine). Pick one:"*

Picking one flows into the same mode question as Scenario 1. If you type a branch name into "Other…", it's resolved as a direct branch. If you type a number, it's resolved as a PR.

---

## Scenario 5 — Switch checkout without a worktree (legacy behavior)

Sometimes you actually do want to switch branches in the current tree — e.g., you're hotfixing main and the context switch is quick.

```text
you: /worktree feature/quick-hotfix
```

Pick **Switch checkout** in the mode question. Claude runs `gt checkout feature/quick-hotfix` (Graphite) or `git checkout feature/quick-hotfix` (plain).

If your tree is dirty, you'll be asked: *"[Stash and continue] [Commit first] [Cancel]"*. "Stash and continue" runs `git stash push` first, then the checkout.

No worktree is created. No session-dir switch happens. Fast; appropriate when the current branch is in a clean state.

---

## Scenario 6 — Configure dev-file copying per repo

By default, `execute.sh` copies these gitignored files into every new worktree:

```
.env  .env.local  .env.*.local  .envrc
```

For a repo with a different setup, override per-repo by creating `<repo>/.claude/worktree.conf`:

```sh
WORKTREE_COPY_GLOBS=".env .env.local .env.test .envrc direnv/envrc my-local-setup.json"
```

**Do not** add `node_modules`, `.venv`, `build/`, or other install artifacts — they bake in absolute paths at install time and will break in a worktree. Run your normal setup commands (`uv pip install`, `npm install`, etc.) inside the new worktree once.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `branch name must match <type>/<slug>` | The `WorktreeCreate` hook rejects names like `rate-limit-fix` (no type prefix) | Rename: `feat/rate-limit-fix`. Or invoke by PR number and let the hook resolve the upstream branch, which already matches. |
| `collision: <path> exists but is not a registered worktree` | A previous `git worktree add` failed partway and left a directory | Remove the orphan dir manually: `rm -rf <repo>/.claude/worktrees/<safe-name>` |
| `fetch failed, continuing with stale local data` | `gh`/`git` couldn't reach the remote | Check `gh auth status` and your network. Worktree still creates from local refs. |
| `auth_hint: possible gh account mismatch` | Your active `gh` account doesn't have access to this repo's org | `gh auth switch --user <correct-account>` |
| Session doesn't follow into the new worktree | `EnterWorktree` fell back to `execute.sh worktree` (plain `git worktree add`) because the hook errored | Check `~/.claude/logs/worktree-create.log` for the hook error. Until fixed, manually `cd` and route file-tool calls through the new path. |
| `reclaim.sh` exits 12 | Your shell cwd is still inside the target worktree | `cd` to main first, then re-run |
| Parallel `/worktree` calls on the same branch | Race at `git worktree add` | The second call reuses the first (reuse check in `execute.sh`). Not a problem in practice. |

---

## What this toolkit intentionally does NOT do

- **Delete branches.** `/unworktree` reclaims but never runs `git branch -D`. Branches survive reclaim untouched.
- **Rebase or sync stacks.** That's `/reconcile`'s job (not in this plugin). `/worktree` and `/unworktree` just get you onto a branch.
- **Batch operations.** One worktree per invocation. Main can only hold one branch at a time; batching `/unworktree` makes no sense.
- **Auto-cleanup.** Stale worktrees accumulate under `<repo>/.claude/worktrees/`. Run `git worktree list` and `git worktree remove <path>` yourself when you want to tidy.
