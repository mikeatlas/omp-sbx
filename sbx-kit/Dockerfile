# syntax=docker/dockerfile:1.7
###############################################################################
# omp-sbx-template - sandbox template for the omp coding agent.
#
# The base image (docker/sandbox-templates:shell-nightly) supplies Ubuntu, the
# non-root `agent` user, Node, Python, Go, Java, git and the sbx microVM
# security model. This adds the omp binary, bun, uv, LSP servers,
# agent-browser and the dev tools the shell template leaves out.
#
# Build and load with ./build.sh.
###############################################################################

FROM docker/sandbox-templates:shell-nightly

USER root

# ── Dev tools and Chromium's shared libraries ────────────────────────────────
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
RUN npm install -g pyright typescript-language-server typescript bash-language-server
RUN go install golang.org/x/tools/gopls@latest
ENV PATH="/home/agent/go/bin:${PATH}"

# ── agent-browser + Chromium (Playwright build) ──────────────────────────────
# The omp `browser` tool cannot spawn its bundled Chromium in the microVM
# (ENOEXEC), and Ubuntu's chromium-browser package is a snap stub that also
# fails in containers. Playwright's Chromium is a real ARM64 build, and
# agent-browser drives it through AGENT_BROWSER_EXECUTABLE_PATH.
RUN npm install -g agent-browser
RUN npx playwright@1.61.1 install chromium
# The glob resolves once the download above completes.
USER root
RUN ln -sf /home/agent/.cache/ms-playwright/chromium-*/chrome-linux/chrome \
           /usr/local/bin/chromium
USER agent
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/chromium

# ── omp prebuilt binary ──────────────────────────────────────────────────────
# The `omp --version` smoke test creates /home/agent/.omp on the way out, so
# delete it: omp-init.sh replaces that path with a symlink to the host mount,
# and a real directory there gets the symlink nested inside it instead.
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

# Not /home/agent/workspace: the startup hook swaps that path for a symlink,
# and OCI execs against a moving WORKDIR fail.
WORKDIR /home/agent

# Tells sbx this template is built for the "omp" agent, not the base shell one.
LABEL com.docker.sandboxes.flavor="omp"
