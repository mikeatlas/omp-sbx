<p align="center">
  <img width="250" alt="Image" src="https://github.com/user-attachments/assets/c91d67e4-c6a6-46c0-a7dd-4f682cc67193" />
</p>

# omp-sbx Oh My Pi Sandbox

Run the [omp coding agent](https://omp.sh) (oh-my-pi) inside a [Docker sbx](https://docs.docker.com/ai/sandboxes/) sandbox with host configs shared.

## What it does

- Launches omp inside a Docker sbx microVM — sbx handles all security (non-root user, network policies, secret proxy, resource limits)
- Bind-mounts your `~/.omp` (agent.db, managed-skills, memories, sessions) so state persists across sandbox restarts
- Sandboxes are per-directory: running from the same cwd reconnects to the same sandbox
- `--new` flag forces a fresh sandbox

## Prerequisites

```bash
brew install docker/tap/sbx
sbx login
sbx policy set-default balanced
```

## Install

```bash
git clone https://github.com/mikeatlas/omp-sbx.git ~/src/github.com/mikeatlas/omp-sbx
cd ~/src/github.com/mikeatlas/omp-sbx

# Build + load the template image into sbx
./build.sh

# Symlink the launcher onto your PATH
ln -sf "$PWD/omp-sbx" ~/.local/bin/omp-sbx

# Alias omp to always use the sandbox (in ~/.zshrc or ~/.bashrc)
echo "alias omp='omp-sbx'" >> ~/.zshrc
```

## Usage

```bash
omp                    # interactive TUI (cwd = workspace, ~/.omp shared)
omp --new              # destroy + create fresh sandbox
omp --yes              # skip the pre-launch "press any key" pause
omp --version          # passthrough flags to omp
omp "fix the bug"      # one-shot prompt
```

## How it works

| Component | File | Purpose |
|---|---|---|
| Template | `sbx-kit/Dockerfile` | Extends `docker/sandbox-templates:shell-nightly` with omp binary + dev tools |
| Kit | `sbx-kit/spec.yaml` | Defines omp entrypoint, network allow-list, env, agent context |
| Launcher | `omp-sbx` | Wrapper handling banner, sandbox lifecycle, resume vs new |
| Parallel | `omp-sbx-parallel` | Git worktree-based parallel sandbox launcher |
| Browser CLI | `sbx-kit/Dockerfile` | Installs `agent-browser` (replaces Puppeteer, which can't spawn in sbx) |

### Config sharing

sbx mounts additional workspaces at their **host path** inside the container (e.g. `/Users/<user>/.omp`). The kit's startup command symlinks this to `/home/agent/.omp` so omp's `PI_CONFIG_DIR=.omp` resolves correctly.

### GitHub auth forwarding

The sandbox forwards your host `gh` CLI session so that `gh` commands and `git push` over HTTPS work without a separate token or SSH setup. This is a **convenience**, not a security boundary — sbx's microVM isolation is the real security control (see [Security](#security)).

**What gets mounted.** If `~/.config/gh` exists on your host, `omp-sbx` bind-mounts it into the sandbox read-write. The kit's startup command symlinks it to `/home/agent/.config/gh` (via `GH_CONFIG_DIR`), then runs `gh auth setup-git` when `hosts.yml` is present — this configures `git`'s credential helper to call `gh auth git-credential`, which supplies the OAuth token for HTTPS remotes.

**Why the token is "insecure."** `~/.config/gh/hosts.yml` contains an OAuth token that can authenticate to GitHub as your user. The mount is read-write, so anything running inside the sandbox can read it. This is acceptable because the sandbox is a short-lived, isolated microVM with a network allow-list — it is not a multi-tenant or untrusted environment. If you need a hard boundary, do **not** mount `~/.config/gh`: remove the `MOUNTS+=("$HOME/.config/gh")` block in the `omp-sbx` launcher (around line 68) and use an HTTPS remote with a separate credential helper or SSH instead.

**Prerequisites.**

1. On the host: `gh auth login` (creates `~/.config/gh/hosts.yml`).
2. `github.com:443` must be in the network allow-list (it is by default — see `sbx-kit/spec.yaml`).

**Verifying.** Inside the sandbox:

```bash
gh auth status      # should show your logged-in account
gh status           # dashboard of assigned issues/PRs/mentions
git push            # uses gh credential helper, no separate token needed
```

If `gh auth status` fails, the host's `~/.config/gh` is not mounted — recreate the sandbox with `omp --new`. This happens when the directory was absent on the host at sandbox-creation time; mounting is decided once, at launch.

### LSP servers

The template ships with language servers for Python (`pyright`), TypeScript/JavaScript (`typescript-language-server`), Bash (`bash-language-server`), and Go (`gopls`).

**Two-part setup, split by concern:**

| Part | Location | Rebuild needed? |
|---|---|---|
| Binary install | `sbx-kit/Dockerfile` (the `LSP servers` section) | Yes — `./build.sh` |
| Server registration | `~/.omp/lsp.yml` on the host | No — live via `~/.omp` bind mount |

`lsp.yml` is bind-mounted into the sandbox, so editing it takes effect immediately on the next session. Adding or changing a *binary* requires a rebuild + `omp --new`.

#### Lazy loading

omp starts LSP servers **lazily**, keyed on `fileTypes` matching actual files in the open workspace. A server only activates for workspaces that contain a file whose extension matches one of its `fileTypes`. The message *“No language servers configured for this project”* (from `lsp status`) means **no file in the workspace matched** any server's `fileTypes` — not that the config is missing.

`rootMarkers` (`.git`, `go.mod`, `package.json`) set the project root but do **not** start a server by themselves; a matching file type is also required.

#### Adding a server

1. Install the binary in `sbx-kit/Dockerfile` — append to the global `npm install` line for npm packages, or add a separate `RUN` step for non-npm servers (`go install`, `cargo install`, etc.).
2. Register the server in `~/.omp/lsp.yml`:
   ```yaml
     gopls:
       command: gopls
       args: ["serve"]
       fileTypes: [".go"]
       rootMarkers:
         - "go.mod"
         - ".git"
   ```
3. Rebuild + load (`./build.sh`), then start a fresh sandbox (`omp --new`).

### Browser automation (agent-browser)

The omp `browser` tool (Puppeteer/Chromium) **cannot spawn inside the sbx microVM** — the bundled `chrome-linux64` binary fails with `ENOEXEC`. The template instead ships [`agent-browser`](https://github.com/vercel-labs/agent-browser), a native Rust CLI. Chrome for Testing has no Linux ARM64 builds, so the template installs `chromium-browser` via apt and points agent-browser at it via `AGENT_BROWSER_EXECUTABLE_PATH`.

```bash
agent-browser open https://example.com      # launch + navigate
agent-browser snapshot                       # accessibility tree with @eN refs
agent-browser click @e2                      # click by ref
agent-browser fill @e3 "text"                # fill input
agent-browser screenshot page.png            # capture
agent-browser close
```

For **static content** (articles, docs, GitHub issues/PRs, JSON, PDFs) no browser is needed — the omp `read` tool fetches clean text/markdown from a URL directly. Reach for `agent-browser` only when JS execution or interaction is required.

Changing the `agent-browser` version or system Chromium requires a rebuild (`./build.sh`) + `omp --new`.

### Security

All security is handled by the sbx microVM — no manual `cap_drop`, `gosu`, `umask`, or read-only rootfs configuration needed:

| Control | sbx |
|---|---|
| Isolation | MicroVM with separate kernel |
| Non-root user | Built-in `agent` UID 1000 |
| Network | Policy-based allow-list |
| Secrets | Proxy injects keys (never enter sandbox) |
| Resource limits | `sbx run --memory --cpus` |

## Parallel sessions (git worktrees)

`omp-sbx-parallel` creates a git worktree on a separate branch and launches a dedicated sandbox for it. Run it multiple times to work on multiple tasks in parallel — each gets its own worktree, branch, and sandbox.

```bash
omp-sbx-parallel                          # interactive: pick existing branch or create new
omp-sbx-parallel --new fix-auth-bug       # create new branch + worktree + sandbox
omp-sbx-parallel --branch feature-x       # use existing branch in a new worktree
```

On exit (interactive mode), you're offered cleanup:
1. Merge the branch into your current branch and remove the worktree
2. Remove the worktree only (keep the branch)
3. Keep the worktree as-is

Worktrees are created as siblings of the repo root: `~/src/myproject@fix-auth-bug`

### VS Code worktree integration

`omp-sbx-parallel` maintains a multi-root `.code-workspace` file at the repo root (`<repo-name>.code-workspace`) so VS Code can display all active worktrees as named roots in one window. The file is gitignored (`*.code-workspace`) — it's machine-local, never committed.

**What happens automatically:**

| Event | `.code-workspace` action |
|---|---|
| Worktree created/reused | Worktree added as a named root |
| Cleanup: merge + remove | Root removed |
| Cleanup: remove only | Root removed |
| Cleanup: keep as-is | Root left in file |

**Folder naming:** main checkout is `<repo-name>`; each worktree is `<repo-name> <branch>`. This lets VS Code tasks pin cwd via `${workspaceFolder:<name>}`:

```json
{
  "label": "agent: feature-x",
  "type": "shell",
  "command": "omp-sbx-parallel --branch feature-x",
  "options": { "cwd": "${workspaceFolder:myrepo feature-x}" }
}
```

Requires `jq` on the host (silently skips if unavailable). For full agent instructions, see [`INSTRUCTIONS.md`](INSTRUCTIONS.md).

**VS Code settings:** enable `git.detectWorktrees` to auto-list all worktrees in Source Control, even ones created outside VS Code.

## Rebuild after omp upgrade

```bash
cd ~/src/github.com/mikeatlas/omp-sbx
./build.sh
```
