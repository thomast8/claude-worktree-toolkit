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
/plugin marketplace add https://github.com/<YOUR-ORG>/claude-worktree-toolkit.git
/plugin install worktree-toolkit@claude-worktree-toolkit
```

Or, if Claude Code supports local paths:

```text
/plugin marketplace add ~/path/to/claude-worktree-toolkit
/plugin install worktree-toolkit@claude-worktree-toolkit
```

The plugin bundles its hooks, so there's nothing to paste into `settings.json`.

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

None specified. Internal sharing only.
