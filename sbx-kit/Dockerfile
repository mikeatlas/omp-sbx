# syntax=docker/dockerfile:1.7
###############################################################################
# omp-sbx-template — custom sandbox template for the omp coding agent.
#
# Extends docker/sandbox-templates:shell-nightly, which already provides:
#   • Ubuntu 26.04, non-root `agent` user (UID 1000) with passwordless sudo
#   • tini as PID 1, /home/agent/workspace as working dir
#   • Node.js 22, Python 3.14, Go, Java, Git, Docker CLI, ripgrep, jq
#   • sbx microVM security (network policies, secret proxy, resource limits)
#
# This template adds:
#   • omp prebuilt binary (self-extracts pi_natives on first run)
#   • bun, uv (for the pi kernel + python skills)
#   • LSP servers (pyright, typescript-language-server, bash-language-server, gopls)
#   • agent-browser (browser automation for AI agents — replaces Puppeteer, which can't spawn in sbx)
#   • Missing dev tools (fd, fzf, sqlite3, build-essential)
#
# Build + load into sbx:
#   docker build -t omp-sbx:latest -f sbx-kit/Dockerfile .
#   docker image save omp-sbx:latest -o /tmp/omp-sbx.tar
#   sbx template load /tmp/omp-sbx.tar
#
# Run with the omp kit:
#   sbx run --kit ./sbx-kit --template omp-sbx:latest omp
###############################################################################

FROM docker/sandbox-templates:shell-nightly

USER root

# ── Missing dev tools from the shell template ────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      fd-find fzf sqlite3 build-essential pkg-config libssl-dev \
      unzip xz-utils file less procps \
      chromium-browser \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

USER agent

# ── Bun ──────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.14"
ENV BUN_INSTALL=/home/agent/.bun
ENV PATH="${BUN_INSTALL}/bin:${PATH}"

# ── uv (Python package manager for the pi kernel) ───────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/home/agent/.local/bin:${PATH}"

# ── LSP servers ──────────────────────────────────────────────────────────────
# npm-based servers
RUN npm install -g pyright typescript-language-server typescript bash-language-server
# gopls (Go language server) — base image has Go; binary lands in $GOPATH/bin
RUN go install golang.org/x/tools/gopls@latest
ENV PATH="/home/agent/go/bin:${PATH}"

# ── agent-browser (browser automation for AI agents) ────────────────────────
# Native Rust CLI — replaces the omp `browser` (Puppeteer) tool, which cannot
# spawn Chromium inside the sbx microVM. Chrome for Testing has no Linux ARM64
# builds, so we use the system chromium-browser (installed above via apt) and
# point agent-browser at it via AGENT_BROWSER_EXECUTABLE_PATH.
RUN npm install -g agent-browser
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium-browser

# ── omp prebuilt binary ──────────────────────────────────────────────────────
# Self-extracts pi_natives.linux-<arch>.node into ~/.omp/natives/<version>/
# on first run. sbx workspace mounts handle ~/.omp persistence.
ARG OMP_VERSION=16.1.15
RUN ARCH="$(uname -m)" && \
    case "$ARCH" in \
      aarch64|arm64) OMP_ARCH="arm64" ;; \
      x86_64|amd64)  OMP_ARCH="x64"   ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/can1357/oh-my-pi/releases/download/v${OMP_VERSION}/omp-linux-${OMP_ARCH}" \
      -o /home/agent/.local/bin/omp && \
    chmod +x /home/agent/.local/bin/omp && \
    omp --version

# ── Environment ──────────────────────────────────────────────────────────────
ENV PI_CONFIG_DIR=.omp \
    HOME=/home/agent

WORKDIR /home/agent/workspace

# Override the base image's flavor label so sbx recognizes this template as
# built for the "omp" agent (suppresses the "built for shell agent" warning).
LABEL com.docker.sandboxes.flavor="omp"
