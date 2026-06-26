#!/usr/bin/env bash
# Shared preflight: ensure the sbx CLI is installed.
#
# Source this file after colors and log() are defined, then call:
#   ensure_sbx "<script-name>"
#
# If sbx is missing the user is shown an OS-specific install plan and asked
# to approve it interactively (no override flag — the prompt is mandatory).
# Non-interactive contexts (no TTY) print instructions and exit.

# Safety-net fallbacks in case the caller didn't define every color.
: "${C_DIM:=}"; : "${C_CYAN:=}"; : "${C_GREEN:=}"; : "${C_YELLOW:=}"
: "${C_RED:=}"; : "${C_BOLD:=}"; : "${C_RST:=}"
if ! command -v log >/dev/null 2>&1; then
  log() { printf '%s\n' "$*" >&2; }
fi

ensure_sbx() {
  local script_name="${1:-omp-sbx}"

  if command -v sbx >/dev/null 2>&1; then
    return 0
  fi

  log "${C_RED}${script_name}: sbx CLI not found.${C_RST}"

  # Non-interactive: can't offer a guided install.
  if [ ! -t 0 ]; then
    log "${C_DIM}Install sbx and re-run. See: https://github.com/docker/sbx${C_RST}"
    exit 1
  fi

  # ── Detect OS and show the install plan ──────────────────────────────────
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin)
      log ""
      log "${C_BOLD}Detected macOS. Install plan:${C_RST}"
      log "  1) ${C_CYAN}brew install docker/tap/sbx${C_RST}"
      log "  2) ${C_CYAN}sbx login${C_RST}"
      log "  3) ${C_CYAN}sbx policy set-default balanced${C_RST}"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      log ""
      log "${C_BOLD}Detected Windows. Install plan:${C_RST}"
      log "  1) ${C_CYAN}winget install -h Docker.sbx${C_RST}"
      log "  2) ${C_CYAN}sbx login${C_RST}"
      ;;
    Linux)
      log ""
      log "${C_BOLD}Detected Linux. Install plan:${C_RST}"
      log "  1) ${C_CYAN}curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh${C_RST}"
      log "  2) ${C_CYAN}sudo apt-get install -y docker-sbx${C_RST}"
      log "  3) ${C_CYAN}sudo usermod -aG kvm \$USER${C_RST}"
      log "  4) ${C_CYAN}newgrp kvm${C_RST}"
      log "  5) ${C_CYAN}sbx login${C_RST}"
      ;;
    *)
      log "${C_YELLOW}Unsupported OS: $os${C_RST}"
      log "${C_DIM}See: https://github.com/docker/sbx${C_RST}"
      exit 1
      ;;
  esac

  # ── Ask for approval (always required — no override flag) ─────────────────
  log ""
  printf '%sRun these steps now? [y/N] %s' "$C_GREEN" "$C_RST" >&2
  local reply
  read -r reply < /dev/tty
  case "$reply" in
    y|Y|yes|YES) ;;
    *) log "${C_DIM}aborted${C_RST}"; exit 1 ;;
  esac

  # ── Execute the install plan ─────────────────────────────────────────────
  case "$os" in
    Darwin)
      brew install docker/tap/sbx || { log "${C_RED}brew install failed${C_RST}"; exit 1; }
      sbx login                   || { log "${C_RED}sbx login failed${C_RST}"; exit 1; }
      sbx policy set-default balanced || { log "${C_RED}sbx policy set-default failed${C_RST}"; exit 1; }
      ;;
    MINGW*|MSYS*|CYGWIN*)
      winget install -h Docker.sbx || { log "${C_RED}winget install failed${C_RST}"; exit 1; }
      sbx login                    || { log "${C_RED}sbx login failed${C_RST}"; exit 1; }
      ;;
    Linux)
      curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh || {
        log "${C_RED}docker repo setup failed${C_RST}"; exit 1; }
      sudo apt-get install -y docker-sbx || {
        log "${C_RED}apt-get install docker-sbx failed${C_RST}"; exit 1; }
      sudo usermod -aG kvm "$USER" || { log "${C_RED}usermod kvm failed${C_RST}"; exit 1; }
      # newgrp can't apply inside a script (it spawns a subshell).  The kvm
      # group membership takes effect on the next login / new terminal.
      log "${C_YELLOW}Note: run 'newgrp kvm' (or log out/in) for kvm access.${C_RST}"
      sbx login || { log "${C_RED}sbx login failed${C_RST}"; exit 1; }
      ;;
  esac

  # ── Verify sbx is now reachable ──────────────────────────────────────────
  if ! command -v sbx >/dev/null 2>&1; then
    log "${C_YELLOW}sbx installed but not on PATH.${C_RST}"
    log "${C_DIM}Open a new terminal and re-run ${script_name}.${C_RST}"
    exit 1
  fi

  log "${C_GREEN}✓ sbx installed and ready${C_RST}"
  log "${C_DIM}Re-run ${script_name} to start.${C_RST}"
  exit 0
}
