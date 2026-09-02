#!/usr/bin/env bash
# omp-init.sh - the image entrypoint: finish setup, then exec omp.
#
# Anything omp reads at load time is wired up here. The spec.yaml startup
# hook runs in parallel with omp itself and can lose that race.
set -euo pipefail

# ── Host config mount symlink ────────────────────────────────────────────────
# The host ~/.omp lands at its own absolute path (e.g. /Users/ww/.omp), so
# ~/.omp has to point at it. Replace a real directory rather than symlinking
# into it: `ln -sf` onto an existing directory nests the link (~/.omp/.omp)
# and omp then reads an empty local config, re-running first-time setup.
OMP_HOST="$(awk '/virtiofs/{print $2}' /proc/mounts | grep '/\.omp$' | head -1 || true)"
if [ -n "$OMP_HOST" ] && [ "$OMP_HOST" != "$HOME/.omp" ]; then
  if [ -e "$HOME/.omp" ] && [ ! -L "$HOME/.omp" ]; then
    rm -rf "$HOME/.omp"
  fi
  ln -sf "$OMP_HOST" "$HOME/.omp"
fi

# ── Unsubstituted GH_TOKEN placeholder ──────────────────────────────────────
# sbx injects a GH_TOKEN placeholder and substitutes a real token only when a
# `github` secret is registered (`sbx secret set github`). gh prefers env vars
# over the mounted ~/.config/gh session, so an unsubstituted placeholder fails
# every call with "invalid token" instead of falling back. A real token has a
# different prefix and survives.
case "${GH_TOKEN:-}" in
  gho_sbxproxymanaged*) unset GH_TOKEN ;;
esac

# The startup hook turns this path into a symlink to the host workspace, so
# enter it here rather than declaring it as the image WORKDIR - sbx's own
# setup execs run before the hook and would fail on a moving path.
cd /home/agent/workspace
exec omp "$@"
