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
#   • agent-browser + Playwright Chromium (browser automation — replaces Puppeteer, which can't spawn in sbx)
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
      libglib2.0-0t64 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
      libxcb1 libxkbcommon0 libasound2t64 libgbm1 libx11-6 libxext6 \
      libcairo2 libpango-1.0-0 libxcomposite1 libxdamage1 libxfixes3 \
      libxrandr2 libatspi2.0-0t64 libnss3 libnspr4 libdrm2 \
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

# ── agent-browser + Chromium (Playwright build) ──────────────────────────────
# agent-browser is a native Rust CLI for AI browser automation. The omp
# `browser` tool (Puppeteer/Chromium) cannot spawn inside the sbx microVM
# (ENOEXEC on the bundled chrome-linux64 binary). Ubuntu's chromium-browser
# apt package is a snap stub that also fails in containers. Playwright ships a
# real Chromium with Linux ARM64 builds — install it and symlink to a stable
# path so agent-browser can find it via AGENT_BROWSER_EXECUTABLE_PATH.
RUN npm install -g agent-browser
RUN npx playwright@1.61.1 install chromium
# Symlink Playwright Chromium into /usr/local/bin (requires root).
# The glob resolves at build time after the download completes.
USER root
RUN ln -sf /home/agent/.cache/ms-playwright/chromium-*/chrome-linux/chrome \
           /usr/local/bin/chromium
USER agent
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/chromium

# ── omp prebuilt binary ──────────────────────────────────────────────────────
# Self-extracts pi_natives.linux-<arch>.node into ~/.omp/natives/<version>/
# on first run. sbx workspace mounts handle ~/.omp persistence.
# The `omp --version` smoke test creates /home/agent/.omp as a side effect; it
# must not survive into the image, or the startup hook cannot replace that path
# with the symlink to the host ~/.omp mount (see sbx-kit/spec.yaml).
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
    omp --version && \
    rm -rf /home/agent/.omp

# ── Entrypoint ───────────────────────────────────────────────────────────────
USER root
COPY sbx-kit/omp-init.sh /usr/local/bin/omp-init.sh
RUN chmod +x /usr/local/bin/omp-init.sh
USER agent

# ── Environment ──────────────────────────────────────────────────────────────
ENV PI_CONFIG_DIR=.omp \
    HOME=/home/agent

# Keep the image working directory stable while sbx runs its startup hooks.
# spec.yaml replaces /home/agent/workspace with a symlink to the host mount;
# using that mutable path as WORKDIR makes later OCI execs fail under sbx 0.39.
WORKDIR /home/agent

# Override the base image's flavor label so sbx recognizes this template as
# built for the "omp" agent (suppresses the "built for shell agent" warning).
LABEL com.docker.sandboxes.flavor="omp"
