# Agent Instructions: VS Code Worktree Workspaces

This file tells agents (omp, Copilot, Cursor, etc.) working in this repo how to
manage the `.code-workspace` file that ties git worktrees into VS Code's
multi-root workspace feature.

## Why this exists

`omp-sbx-parallel` creates git worktrees as siblings of the repo root
(`myrepo@feature-x`). VS Code's multi-root `.code-workspace` file lets you open
all active worktrees in one window, each as a named root — so Source Control,
search, and terminal tasks can target the right checkout by name.

**"Wrong cwd" is one of the easiest ways to accidentally edit the wrong
checkout.** Named workspace roots make the branch/worktree cwd explicit and
repeatable.

## The `.code-workspace` file

- **Location:** `<repo-root>/<repo-name>.code-workspace` (e.g.
  `omp-sbx/omp-sbx.code-workspace`).
- **Gitignored:** `*.code-workspace` is in `.gitignore` — the file is
  machine-local, never committed.
- **Managed by:** `omp-sbx-parallel` (via `jq`). Created on first parallel
  session, updated on each create/cleanup.

### Structure

```json
{
  "folders": [
    { "path": ".",     "name": "myrepo" },
    { "path": "../myrepo@feature-x", "name": "myrepo feature-x" }
  ],
  "settings": {}
}
```

- The main checkout is always the first folder, named `<repo-name>`.
- Each worktree is a folder named `<repo-name> <branch>`.
- Paths are relative to the workspace file (worktrees are siblings: `../`).

## What `omp-sbx-parallel` does

| Event | Action |
|---|---|
| Worktree created/reused | Adds the worktree as a named root (idempotent) |
| Cleanup: merge + remove | Removes the worktree root from the file |
| Cleanup: remove only | Removes the worktree root from the file |
| Cleanup: keep as-is | Leaves the root in the file |

## Agent responsibilities

If you are an agent working in this repo and you create or remove a git worktree
(outside of `omp-sbx-parallel`), keep the `.code-workspace` file tidy:

1. **After creating a worktree** — add a folder entry:
   ```json
   { "path": "../<repo>@<branch>", "name": "<repo> <branch>" }
   ```
2. **After removing a worktree** — delete its folder entry from the `folders`
   array.
3. **Never commit the `.code-workspace` file** — it is gitignored and
   machine-local.

### Using named roots in tasks.json

VS Code tasks can pin `cwd` to a specific worktree root:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "agent: feature-x",
      "type": "shell",
      "command": "omp-sbx-parallel --branch feature-x",
      "options": {
        "cwd": "${workspaceFolder:myrepo feature-x}"
      },
      "problemMatcher": []
    }
  ]
}
```

`${workspaceFolder:<name>}` resolves to the absolute path of the folder whose
`name` matches in the `.code-workspace` file.

## VS Code settings for worktree detection

For the best experience, enable worktree auto-detection in VS Code settings
(`Cmd+,` → `git.detectWorktrees`):

```json
{
  "git.detectWorktrees": true
}
```

This makes VS Code list all worktrees in the Source Control Repositories view,
even ones created outside of VS Code.
