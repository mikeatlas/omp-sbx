#!/usr/bin/env bash
# omp-init.sh — synchronous pre-start init, then exec omp.
#
# The spec.yaml startup command races with omp startup. The plugin's
# ensureMorphConfigFile() runs at omp load time and writes a keyless
# default morph.json to ~/.pi/morph/ before the startup script can create
# the correct symlinks to ~/.omp/morph/. This script runs as the entrypoint
# so the morph symlinks are always in place before omp (and the plugin) load.
set -euo pipefail

# ── Morph config symlinks ────────────────────────────────────────────────────
# ~/.omp is bind-mounted from the host; ~/.pi/morph is local to the container
# and starts empty. Wire the symlinks before omp starts so the plugin reads
# the host-persisted config and key, not a freshly-written keyless default.
# 0.2.0 reads from ~/.pi/morph/ (was ~/.pi/agent/ in 0.1.x).
MORPH_CFG_DIR="$HOME/.omp/morph"
if [ -d "$MORPH_CFG_DIR" ]; then
  mkdir -p "$HOME/.pi/morph"
  # Force-replace: a stale regular file from a previous interrupted start
  # would make ln -sf a no-op, leaving the wrong file in place.
  rm -f "$HOME/.pi/morph/morph.json" "$HOME/.pi/morph/morph.env"
  ln -sf "$MORPH_CFG_DIR/morph.json" "$HOME/.pi/morph/morph.json"
  [ -f "$MORPH_CFG_DIR/morph.env" ] && \
    ln -sf "$MORPH_CFG_DIR/morph.env" "$HOME/.pi/morph/morph.env" || true
fi

# ── Unsubstituted GH_TOKEN placeholder ──────────────────────────────────────
# sbx always injects a GH_TOKEN placeholder (gho_sbxproxymanaged...) so its
# proxy can substitute a real token when a `github` secret is registered
# (`sbx secret set github`). Without one, the placeholder is left as-is —
# and gh CLI's env vars take precedence over any stored/mounted credentials
# (`gh help environment`), so it silently shadows the working, file-based
# `~/.config/gh` forwarding set up above and in spec.yaml, breaking `gh`
# and `git push` with an "invalid token" error instead of falling back.
# Strip only the recognizable placeholder — a real substituted token (once
# a `github` secret is registered) is left untouched.
case "${GH_TOKEN:-}" in
  gho_sbxproxymanaged*) unset GH_TOKEN ;;
esac

# The sbx startup hook replaces this path with a symlink to the host workspace.
# Enter it only after the hook has completed, rather than declaring it as the
# image WORKDIR where sbx's own setup execs would depend on it.
cd /home/agent/workspace
exec omp "$@"
