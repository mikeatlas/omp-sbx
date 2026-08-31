#!/usr/bin/env bash
# omp-init.sh — synchronous pre-start init, then exec omp.
#
# The spec.yaml startup command races with omp startup. The plugin's
# ensureMorphConfigFile() runs at omp load time and writes a keyless
# default morph.json to ~/.pi/morph/ before the startup script can create
# the correct symlinks to ~/.omp/morph/. This script runs as the entrypoint
# so the morph symlinks are always in place before omp (and the plugin) load.
set -euo pipefail

# ── Host config mount symlink ────────────────────────────────────────────────
# omp reads PI_CONFIG_DIR=.omp (i.e. ~/.omp) for config.yml, agent.db,
# models.db, etc. The host mount lands at the host's absolute path (e.g.
# /Users/ww/.omp), not at ~/.omp, so it must be symlinked. If omp starts
# before this runs (same startup-hook race as Morph above), it creates its
# own ~/.omp/ on the container's local filesystem (e.g. a fresh `logs/`
# dir) — then `ln -sf` onto an existing real directory nests the symlink
# inside it (~/.omp/.omp) instead of replacing it, and every subsequent
# start reads an empty local config instead of the host's, prompting a
# from-scratch model setup. Do this symlink synchronously, before omp
# starts, exactly like the Morph symlinks below.
OMP_HOST="$(awk '/virtiofs/{print $2}' /proc/mounts | grep '/\.omp$' | head -1 || true)"
if [ -n "$OMP_HOST" ] && [ "$OMP_HOST" != "$HOME/.omp" ]; then
  if [ -e "$HOME/.omp" ] && [ ! -L "$HOME/.omp" ]; then
    rm -rf "$HOME/.omp"
  fi
  ln -sf "$OMP_HOST" "$HOME/.omp"
fi

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

# The sbx startup hook replaces this path with a symlink to the host workspace.
# Enter it only after the hook has completed, rather than declaring it as the
# image WORKDIR where sbx's own setup execs would depend on it.
cd /home/agent/workspace
exec omp "$@"
