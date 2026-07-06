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

exec omp "$@"
