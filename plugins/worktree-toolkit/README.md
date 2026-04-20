# worktree-toolkit

`/worktree` and `/unworktree` for Claude Code, with the hooks that make `EnterWorktree` actually move the session.

## Commands

### `/worktree [arg]`

- `/worktree` — interactive picker built from your open PRs + PRs needing your review (oldest review requests first, then your own branches stack-first).
- `/worktree 123` — resolve PR #123's head branch.
- `/worktree feature/my-branch` — use that branch directly.

Asks once whether to open as a worktree (isolated path under `<repo>/.claude/worktrees/`) or switch checkout in the current tree. Worktree mode is the default when reviewing teammate PRs.

### `/unworktree [arg]`

- `/unworktree` — when run from inside a worktree, defaults to that one; otherwise offers a picker.
- `/unworktree 123` — pick by PR number.
- `/unworktree feature/foo` — pick by branch.
- `/unworktree /absolute/path` — pick by worktree path.

Stashes any work in the worktree, removes the worktree, checks out the branch in main, pops the stash. The backing branch always survives — this skill never runs `git branch -D`.

## How it works

Each skill is a coordinator around bundled shell scripts in `scripts/`. The scripts own all the `git` / `gh` / `gt` logic and return JSON; the skill body parses the JSON and decides what to do next.

- `scripts/gather.sh` — fetch, detect Graphite, resolve arg, build picker data
- `scripts/execute.sh` — create worktree or switch checkout (fallback path)
- `scripts/post-enter.sh` — run inside new worktree: pull, copy gitignored dev files
- `scripts/list.sh` — enumerate worktrees with dirty/merged state
- `scripts/reclaim.sh` — stash + remove worktree + checkout branch in main + pop stash

## Hooks

Registered via `hooks/hooks.json`, loaded automatically when the plugin is enabled:

- `WorktreeCreate` → `hooks/worktree-create.sh` — enforces branch naming, reuses existing branches, cuts new branches from `origin/<default>`
- `WorktreeRemove` → `hooks/worktree-remove.sh` — info-only logger

## Configuring copied dev files

`execute.sh` copies gitignored files matching a whitelist into the new worktree. Default globs: `.env .env.local .env.*.local .envrc`.

Per-repo override: create `<repo>/.claude/worktree.conf` with a single line:

```sh
WORKTREE_COPY_GLOBS=".env .env.local .env.test .envrc direnv/envrc"
```

Don't add `node_modules`, `.venv`, or similar — those break because they bake in absolute paths at install time.

## Logs

`~/.claude/logs/worktree-create.log` — every hook invocation gets a timestamped line.
