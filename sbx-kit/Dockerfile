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
#   • pi-morphllm-plugin (optional, opt-in via INSTALL_MORPH_PLUGIN=1 build arg)
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

# ── pi-morphllm-plugin (optional, opt-in via build arg) ─────────────────────
# Morph runtime extension: adds morph_fastapply, warpgrep_codebase_search,
# warpgrep_github_search tools + Morph compaction. Opt out by building with
# INSTALL_MORPH_PLUGIN=0 (the default). When enabled, morph-install.sh
# installs the npm package, applies three compatibility patches, and bundles
# the Morph SDK so it loads correctly under omp's internal module loader.
# See README "Morph plugin" section and sbx-kit/morphllm/README.md for details.
ARG INSTALL_MORPH_PLUGIN=0

USER root
COPY sbx-kit/morphllm/morph.json.template /opt/morph-config/morph.json
COPY sbx-kit/morphllm/morph-withfilemutationqueue.shim.js /opt/morph-config/withFileMutationQueue.shim.js
COPY sbx-kit/morphllm/morph-install.sh /opt/morph-config/morph-install.sh
COPY sbx-kit/morphllm/morph-patch.py /opt/morph-config/morph-patch.py
COPY sbx-kit/omp-init.sh /usr/local/bin/omp-init.sh
RUN chmod +x /opt/morph-config/morph-install.sh /usr/local/bin/omp-init.sh

USER agent
RUN if [ "${INSTALL_MORPH_PLUGIN}" = "1" ]; then \
      /opt/morph-config/morph-install.sh; \
    else \
      echo ">> morph plugin install skipped (INSTALL_MORPH_PLUGIN=${INSTALL_MORPH_PLUGIN})"; \
    fi

# ── Environment ──────────────────────────────────────────────────────────────
ENV PI_CONFIG_DIR=.omp \
    HOME=/home/agent

WORKDIR /home/agent/workspace

# Override the base image's flavor label so sbx recognizes this template as
# built for the "omp" agent (suppresses the "built for shell agent" warning).
LABEL com.docker.sandboxes.flavor="omp"
