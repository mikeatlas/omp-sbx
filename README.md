# omp-sbx

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
omp --version          # passthrough flags to omp
omp "fix the bug"      # one-shot prompt
```

## How it works

| Component | File | Purpose |
|---|---|---|
| Template | `sbx-kit/Dockerfile` | Extends `docker/sandbox-templates:shell` with omp binary + dev tools |
| Kit | `sbx-kit/spec.yaml` | Defines omp entrypoint, network allow-list, env, agent context |
| Launcher | `omp-sbx` | Wrapper handling banner, sandbox lifecycle, resume vs new |

### Config sharing

sbx mounts additional workspaces at their **host path** inside the container (e.g. `/Users/<user>/.omp`). The kit's startup command symlinks this to `/home/agent/.omp` so omp's `PI_CONFIG_DIR=.omp` resolves correctly.

### Security

All security is handled by the sbx microVM — no manual `cap_drop`, `gosu`, `umask`, or read-only rootfs configuration needed:

| Control | sbx |
|---|---|
| Isolation | MicroVM with separate kernel |
| Non-root user | Built-in `agent` UID 1000 |
| Network | Policy-based allow-list |
| Secrets | Proxy injects keys (never enter sandbox) |
| Resource limits | `sbx run --memory --cpus` |

## Rebuild after omp upgrade

```bash
cd ~/src/github.com/mikeatlas/omp-sbx
./build.sh
```
