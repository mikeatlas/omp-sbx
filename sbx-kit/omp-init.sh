#!/usr/bin/env bash
# omp-init.sh — synchronous pre-start init, then exec omp.
#
# The spec.yaml startup command races with omp startup and can lose. This
# script is the image entrypoint, so anything omp reads at load time is
# wired up here instead.
set -euo pipefail

# ── Host config mount symlink ────────────────────────────────────────────────
# omp reads PI_CONFIG_DIR=.omp (i.e. ~/.omp) for config.yml, agent.db,
# models.db, etc. The host mount lands at the host's absolute path (e.g.
# /Users/ww/.omp), not at ~/.omp, so it must be symlinked. If omp starts
# before this runs (the startup-hook race above), it creates its
# own ~/.omp/ on the container's local filesystem (e.g. a fresh `logs/`
# dir) — then `ln -sf` onto an existing real directory nests the symlink
# inside it (~/.omp/.omp) instead of replacing it, and every subsequent
# start reads an empty local config instead of the host's, prompting a
# from-scratch model setup.
OMP_HOST="$(awk '/virtiofs/{print $2}' /proc/mounts | grep '/\.omp$' | head -1 || true)"
if [ -n "$OMP_HOST" ] && [ "$OMP_HOST" != "$HOME/.omp" ]; then
  if [ -e "$HOME/.omp" ] && [ ! -L "$HOME/.omp" ]; then
    rm -rf "$HOME/.omp"
  fi
  ln -sf "$OMP_HOST" "$HOME/.omp"
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
