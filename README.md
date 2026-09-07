<p align="center">
  <img width="250" alt="Image" src="https://github.com/user-attachments/assets/c91d67e4-c6a6-46c0-a7dd-4f682cc67193" />
</p>

# omp-sbx Oh My Pi Sandbox

Run the [omp coding agent](https://omp.sh) (oh-my-pi) inside a [Docker sbx](https://docs.docker.com/ai/sandboxes/) sandbox with host configs shared.

## What it does

- Launches omp inside a Docker sbx microVM — sbx handles all security (non-root user, network policies, secret proxy, resource limits)
- Bind-mounts your `~/.omp` (agent.db, managed-skills, memories, sessions) so state persists across sandbox restarts
- Sandboxes are per-directory: running from the same cwd reconnects to the same sandbox
- Recovers automatically after a force-quit: if the sandbox is left stopped (or its agent wedged), the launcher re-attaches, then stops+restarts, and as a last resort recreates the sandbox — your omp session resumes from the shared `~/.omp` either way
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
| Env (experimental) | `sbx-kit/.sbxenv.yaml` + `omp-sbxenv` | Declarative alternative launcher for scripted/CI use — see [Scripted / CI use](#scripted--ci-use-experimental) |
| Launcher | `omp-sbx` | Wrapper handling banner, sandbox lifecycle, resume vs new |
| Parallel | `omp-sbx-parallel` | Git worktree-based parallel sandbox launcher |
| Browser CLI | `sbx-kit/Dockerfile` | Installs `agent-browser` (replaces Puppeteer, which can't spawn in sbx) |
| Bedrock auth | `sbx-kit/omp-init.sh` | Opt-in AWS SSO profile with browserless renewal - see [Amazon Bedrock](#amazon-bedrock-aws-sso) |
| SSO nudge | `sbx-kit/extensions/aws-sso-nudge.ts` | omp extension: warns before the SSO login lapses, adds `/aws-login` |

### Config sharing

sbx mounts additional workspaces at their **host path** inside the container (e.g. `/Users/<user>/.omp`). The kit's startup command symlinks this to `/home/agent/.omp` so omp's `PI_CONFIG_DIR=.omp` resolves correctly.

### GitHub auth forwarding

The sandbox forwards your host `gh` CLI session so that `gh` commands and `git push` over HTTPS work without a separate token or SSH setup. This is a **convenience**, not a security boundary — sbx's microVM isolation is the real security control (see [Security](#security)).

**What gets mounted.** If `~/.config/gh` exists on your host, `omp-sbx` bind-mounts it into the sandbox read-write. The kit's startup command symlinks it to `/home/agent/.config/gh` (via `GH_CONFIG_DIR`), then runs `gh auth setup-git` when `hosts.yml` is present — this configures `git`'s credential helper to call `gh auth git-credential`, which supplies the OAuth token for HTTPS remotes.

**Why the token is "insecure."** `~/.config/gh/hosts.yml` contains an OAuth token that can authenticate to GitHub as your user. The mount is read-write, so anything running inside the sandbox can read it. This is acceptable because the sandbox is a short-lived, isolated microVM with a network allow-list — it is not a multi-tenant or untrusted environment. If you need a hard boundary, do **not** mount `~/.config/gh`: remove the `MOUNTS+=("$HOME/.config/gh")` block in the `omp-sbx` launcher (around line 68) and use an HTTPS remote with a separate credential helper or SSH instead.

**Prerequisites.**

1. On the host: `gh auth login` (creates `~/.config/gh/hosts.yml`).
2. Store the GitHub secret so the sbx proxy can substitute a real token: `sbx secret set github --command 'gh auth token'`. Without it, `gh` and `git push` fail with `401 Unauthorized` (the proxy injects only a placeholder `GH_TOKEN`).
3. `github.com:443` must be in the network allow-list (it is by default — see `sbx-kit/spec.yaml`).
**Verifying.** Inside the sandbox:

```bash
gh auth status      # should show your logged-in account
gh status           # dashboard of assigned issues/PRs/mentions
git push            # uses gh credential helper, no separate token needed
```

If `gh auth status` fails with `401`, ensure the GitHub secret is stored (`sbx secret ls`). If it fails because the mount is missing, recreate the sandbox with `omp --new` — mounting is decided once, at launch. On macOS, `hosts.yml` contains no token (it lives in the keychain), so `sbx secret set github` is required.

### Amazon Bedrock (AWS SSO)

Off by default. A project turns it on with one line in its `.env`:

```bash
OMP_SBX_AWS_PROFILE=infra-dev-bedrock
OMP_SBX_AWS_REGION=us-east-1          # optional, defaults to us-east-1
```

Define that profile once in `~/.omp/aws-config` on the host. The file uses AWS
CLI config syntax and holds no secrets:

```ini
[sso-session my-sso]
sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile infra-dev-bedrock]
sso_session = my-sso
sso_account_id = 000000000000
sso_role_name = Bedrock-Invoke-Only
region = us-east-1
```

`~/.omp` is already bind-mounted, so editing `aws-config` takes effect on the
next session - no rebuild.

**The SSO token lives inside the sandbox, never on the host.** On first launch
`aws sso login --no-browser` prints a verification URL and code; open it on your
Mac and the token lands in the sandbox's own `~/.aws/sso/cache`. Nothing from
your host `~/.aws` is mounted.

**Renewal is browserless.** `omp-init.sh` generates an `omp-bedrock` profile
whose `credential_process` calls `aws configure export-credentials`. omp reads
the SSO access token but not the refresh token stored next to it, so on its own
it treats an expired token as fatal. The AWS CLI does read that refresh token,
so routing through it renews silently. This requires the `[sso-session]` profile
shape above - a legacy profile with an inline `sso_start_url` gets no refresh
token from the CLI.

Three lifetimes stack up, and only the longest one needs you at a browser:

| Layer | Typical lifetime | Renewal |
|---|---|---|
| Role credentials | 12 hours | Minted from the access token |
| SSO access token | 1 hour | Silent, `grantType: refresh_token` |
| Client registration | ~31 days | `aws sso login`, opening a URL |

Read your own values from `~/.aws/sso/cache/*.json`: `expiresAt` is the access
token and `registrationExpiresAt` on the same entry is the registration. The role
credentials carry their own `Expiration`, visible via
`aws configure export-credentials`.

The role credentials are what actually sign a Bedrock request, and omp caches
them for their full 12 hours. Only when they lapse does it re-read the SSO access
token - which is an hour old at most, and which omp cannot renew. So without
`credential_process` a session dies at the 12 hour mark, and a session started
more than an hour after the last refresh fails immediately. Sending it through
the CLI removes both cliffs, because the CLI renews the access token from the
refresh token with no browser.

One caveat worth knowing: `aws sso login` restarts authorization from scratch
every time, even when the cached token is still valid. Only the credential path
(`aws configure export-credentials`) refreshes silently, which is why the
generated profile uses it.

**The nudge extension** (`sbx-kit/extensions/aws-sso-nudge.ts`) covers the
30-day boundary, which nothing renews on its own. Loaded only when Bedrock is
on, it checks every 15 minutes, shows days remaining in the status line, and
warns in the chat once fewer than 2 days remain (`OMP_SBX_AWS_SSO_WARN_DAYS`
overrides the threshold). If credentials stop working mid-session, it runs the
device-code login itself and puts the URL in the chat - open it on your host and
the session recovers without a restart.

`AWS_CA_BUNDLE` is set in `spec.yaml` because botocore ignores the OS trust
store in favor of its own bundle, which the sbx TLS proxy would otherwise break.

Adding a region means adding its `bedrock-runtime`, `oidc`, `portal.sso`, and
`sts` hosts to the network allow-list in `sbx-kit/spec.yaml`.

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

The omp `browser` tool (Puppeteer/Chromium) **cannot spawn inside the sbx microVM** — the bundled `chrome-linux64` binary fails with `ENOEXEC`. The template instead ships [`agent-browser`](https://github.com/vercel-labs/agent-browser), a native Rust CLI, paired with a real Chromium installed via **Playwright** (which provides Linux ARM64 builds, unlike Chrome for Testing or Ubuntu's `chromium-browser` snap stub).

```bash
agent-browser open https://example.com      # launch + navigate
agent-browser snapshot                       # accessibility tree with @eN refs
agent-browser click @e2                      # click by ref
agent-browser fill @e3 "text"                # fill input
agent-browser screenshot page.png            # capture
agent-browser close
```

The sbx TLS proxy intercepts HTTPS, so `AGENT_BROWSER_IGNORE_HTTPS_ERRORS=true` is set in `spec.yaml` to avoid cert errors. For **static content** (articles, docs, GitHub issues/PRs, JSON, PDFs) no browser is needed — the omp `read` tool fetches clean text/markdown from a URL directly. Reach for `agent-browser` only when JS execution or interaction is required.

Changing the `agent-browser` or Playwright Chromium version requires a rebuild (`./build.sh`) + `omp --new`.

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

## Scripted / CI use (experimental)

`omp-sbxenv` is an alternative launcher built on Docker sbx's declarative
`.sbxenv.yaml` + `sbx env` commands (sbx v0.39+; Docker marks `sbx env`
experimental and subject to change). It fits headless automation better than
`omp-sbx`'s interactive create/pause/attach flow:

```bash
omp-sbxenv --version   # create (if needed) + run a one-shot command
omp-sbxenv --new        # remove + recreate the environment
```

Under the hood this templates `sbx-kit/.sbxenv.yaml` with `${VAR}` values the
script exports (workspace path, kit path, sandbox name) and calls
`sbx env create` / `sbx env exec` / `sbx env rm` directly — no host-mounted
secret files, since `.sbxenv.yaml` (unlike `spec.yaml`) expands `${VAR}`
placeholders for real.

**Known gaps vs `omp-sbx`:**
- No force-quit recovery cascade (re-attach → restart → recreate) — just
  create-or-reuse.
- No `~/.config/gh` forwarding. A static env file can't conditionally mount a
  path that may not exist on every host, and `sbx env create` prompts
  interactively — hanging in non-interactive/CI contexts — if
  `additionalWorkspaces` points at a missing directory.
- Re-running `sbx env run` on an existing environment only re-applies
  env/MCP changes; other `.sbxenv.yaml` edits need `--new`.

For day-to-day interactive use, stick with `omp-sbx`.

## Rebuild after omp upgrade

```bash
cd ~/src/github.com/mikeatlas/omp-sbx
./build.sh
```
