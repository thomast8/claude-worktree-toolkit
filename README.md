# claude-worktree-toolkit

A one-plugin Claude Code marketplace for `/worktree` and `/unworktree`.

## What's inside

- **`/worktree`** — create a git worktree (or switch checkout) for a PR number, branch name, or an interactively-picked PR from the "needs my review" + "mine" buckets. Graphite-aware. Pulls latest and copies gitignored dev files into the new worktree so it's immediately runnable.
- **`/unworktree`** — reclaim a worktree's branch back into the main checkout so you can test it there. Removes the worktree as a side-effect. Auto-stashes worktree work and pops it onto the branch in main.
- **`WorktreeCreate` hook** — enforces `<type>/<slug>` branch naming, checks out existing local/remote branches instead of silently making a new one, and cuts new branches from `origin/<default>`.
- **`WorktreeRemove` hook** — info-only logger.

Both commands use Claude Code's native `EnterWorktree` / `ExitWorktree` tools, so the session's project directory follows the worktree and the desktop app's bottom bar follows along. No manual `cd` gymnastics.

## Install

```text
/plugin marketplace add https://github.com/thomast8/claude-worktree-toolkit.git
/plugin install worktree-toolkit@claude-worktree-toolkit
```

The plugin bundles its hooks, so there's nothing to paste into `settings.json`.

---

## Examples

### 1. Review a teammate's PR without blowing up your current work

You're mid-feature. A teammate asks you to review PR #412. You don't want to stash or lose your env setup.

```text
you: /worktree 412
```

Claude resolves #412 to its head branch, asks *"Open as worktree or Switch checkout?"*, you pick **Open as worktree**, and the session lands in `<repo>/.claude/worktrees/<safe-branch>/` with your `.env` files already copied. The desktop app's bottom bar follows along. Your original feature branch in main is untouched.

### 2. Open a specific branch by name

Skip the PR lookup when you know the branch.

```text
you: /worktree feature/db-recreate
```

The `WorktreeCreate` hook:
- **Reuses** an existing worktree at the derived path if there is one.
- **Checks out** a local branch if one exists.
- **Creates a tracking worktree** if only the remote branch exists.
- Only cuts a new branch from `origin/main` as a last resort (and tells you it did).

### 3. Interactive picker when you don't remember the number

```text
you: /worktree
```

You get up to 4 options: the 2 oldest PRs waiting on your review + your 2 most recent open PRs. Plus an **Other…** free-text option for a branch name or PR number. Pre-prompt summary: *"Pulled 9 live PRs (3 needs-review, 6 mine). Pick one:"*

### 4. Pull a worktree's branch back into main so you can test it end-to-end

Main checkouts often have a `venv`, cached artifacts, or running services that the worktree doesn't. From inside the worktree session:

```text
you: /unworktree
```

Auto-detects the current worktree, stashes any work, removes the worktree dir, checks out the branch in main, pops the stash. **The branch itself is preserved** — only the worktree working-tree directory is removed. You can recreate it anytime with `/worktree <branch>`.

### 5. Switch checkout instead of creating a worktree

Fast path when the current branch is clean and you really do want to context-switch in place:

```text
you: /worktree feature/quick-hotfix
→ pick "Switch checkout"
```

Claude runs `gt checkout` (Graphite) or `git checkout` (plain). If your tree is dirty, it asks to stash first.

### 6. Per-repo dev-file copying

By default, worktrees get `.env .env.local .env.*.local .envrc` copied from main. Override per-repo:

```sh
# <repo>/.claude/worktree.conf
WORKTREE_COPY_GLOBS=".env .env.local .env.test .envrc direnv/envrc"
```

Don't add `node_modules`, `.venv`, build artifacts — run your setup commands inside the new worktree instead.

---

## More detail

Full walkthrough with troubleshooting table and explicit non-goals: [**plugins/worktree-toolkit/USER_GUIDE.md**](./plugins/worktree-toolkit/USER_GUIDE.md).

## Prerequisites on the machine

- `git` — obviously
- `gh` — GitHub CLI, authenticated (`gh auth status` should report logged in)
- `jq` — JSON parsing in the scripts
- `gt` (Graphite) — optional, auto-detected; without it the Graphite paths are skipped

Branch naming enforced by the `WorktreeCreate` hook: `<type>/<slug>` where `type` is one of `feat`, `feature`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`, `build`, `perf`, `hotfix`, `release`, `revert`, `codex`; `slug` is lowercase kebab-case.

## Uninstall

```text
/plugin uninstall worktree-toolkit@claude-worktree-toolkit
/plugin marketplace remove claude-worktree-toolkit
```

Uninstalling the plugin removes its hooks — nothing lingers in your `settings.json`.

## License

MIT. See [LICENSE](./LICENSE). Use it freely, modify it freely, no warranty.
