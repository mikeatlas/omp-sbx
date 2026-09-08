#!/usr/bin/env bash
# omp-init.sh - the image entrypoint: finish setup, then exec omp.
#
# Anything omp reads at load time is wired up here. The spec.yaml startup
# hook runs in parallel with omp itself and can lose that race.
set -euo pipefail

# ── Host config mount symlink ────────────────────────────────────────────────
# The host ~/.omp lands at its own absolute path (e.g. /Users/ww/.omp), so
# ~/.omp has to point at it.
#
# Both flags matter. Replace a real directory rather than symlinking into it:
# plain `ln -s` onto an existing directory nests the link (~/.omp/.omp) and omp
# then reads an empty local config, re-running first-time setup. -n covers the
# same hazard on a second launch, where ~/.omp is already the symlink: without
# it ln follows the link and writes the nested one into the host config dir.
OMP_HOST="$(awk '/virtiofs/{print $2}' /proc/mounts | grep '/\.omp$' | head -1 || true)"
if [ -n "$OMP_HOST" ] && [ "$OMP_HOST" != "$HOME/.omp" ]; then
  if [ -e "$HOME/.omp" ] && [ ! -L "$HOME/.omp" ]; then
    rm -rf "$HOME/.omp"
  fi
  ln -sfn "$OMP_HOST" "$HOME/.omp"
  # A .omp inside the config dir can only be that self-reference, and it makes
  # a config lookup ambiguous.
  if [ -L "$OMP_HOST/.omp" ]; then
    rm -f "$OMP_HOST/.omp"
  fi
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

# ── Amazon Bedrock via AWS SSO (opt-in) ─────────────────────────────────────
# A project opts in with OMP_SBX_AWS_PROFILE=<profile> in its .env. The profile
# is defined in ~/.omp/aws-config on the host, which holds no secrets - only a
# start URL, account id and role name - and is shared by every project.
#
# The generated profile reaches its credentials through the AWS CLI rather than
# naming the SSO profile directly. omp reads the SSO access token but not the
# refresh token stored beside it, so it treats an expired session as fatal; the
# CLI renews from that refresh token with no browser and no prompt.
env_value() {
  local key="$1" file="$2" val
  val="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -1)"
  val="${val%$'\r'}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

# Flags this script adds ahead of the caller's own, e.g. --extension.
OMP_ARGS=()

# Read the host path, not /home/agent/workspace: the symlink to it belongs to
# the startup hook, which has not necessarily run yet.
WORKSPACE_ENV="${WORKSPACE_DIR:-/home/agent/workspace}/.env"
AWS_SSO_PROFILE=""
if [ -f "$WORKSPACE_ENV" ]; then
  AWS_SSO_PROFILE="$(env_value OMP_SBX_AWS_PROFILE "$WORKSPACE_ENV")"
fi

if [ -n "$AWS_SSO_PROFILE" ]; then
  AWS_CONFIG_SRC="$HOME/.omp/aws-config"
  if [ ! -f "$AWS_CONFIG_SRC" ]; then
    echo "omp-sbx: OMP_SBX_AWS_PROFILE=$AWS_SSO_PROFILE needs a profile definition in ~/.omp/aws-config" >&2
  else
    AWS_SSO_REGION="$(env_value OMP_SBX_AWS_REGION "$WORKSPACE_ENV")"
    AWS_SSO_REGION="${AWS_SSO_REGION:-us-east-1}"

    mkdir -p "$HOME/.aws"
    {
      cat "$AWS_CONFIG_SRC"
      printf '\n[profile omp-bedrock]\n'
      printf 'credential_process = aws configure export-credentials --profile %s --format process\n' "$AWS_SSO_PROFILE"
      printf 'region = %s\n' "$AWS_SSO_REGION"
    } > "$HOME/.aws/config"

    # The SSO token cache, symlinked into the shared ~/.omp mount rather than
    # left in this sandbox's own ~/.aws. Its registration lives for about a
    # month (see aws-sso-nudge.ts), but a fresh sandbox otherwise starts with
    # an empty cache and demands a new device-code login regardless - sharing
    # it means a login done once, on the host or in any sandbox, covers every
    # sandbox until the registration itself actually lapses.
    #
    # Both flags matter, for the reason the ~/.omp symlink above does: replace
    # a real directory rather than nesting a link inside it, and -n covers a
    # second launch where ~/.aws/sso/cache is already the symlink.
    SSO_CACHE_SHARED="$HOME/.omp/aws-sso-cache"
    mkdir -p "$SSO_CACHE_SHARED" "$HOME/.aws/sso"
    if [ -e "$HOME/.aws/sso/cache" ] && [ ! -L "$HOME/.aws/sso/cache" ]; then
      rm -rf "$HOME/.aws/sso/cache"
    fi
    ln -sfn "$SSO_CACHE_SHARED" "$HOME/.aws/sso/cache"

    export AWS_PROFILE="omp-bedrock"
    export AWS_REGION="$AWS_SSO_REGION"
    # The nudge extension needs the SSO profile, not the generated one, to name
    # the login command. Exporting it here avoids depending on omp's own .env
    # load reaching the same file.
    export OMP_SBX_AWS_PROFILE="$AWS_SSO_PROFILE"

    # Watches the SSO login from inside the session and offers /aws-login. Only
    # loaded for a project that opted in, so a project without Bedrock runs omp
    # exactly as before.
    NUDGE_EXTENSION="/opt/omp-sbx/extensions/aws-sso-nudge.ts"
    if [ -f "$NUDGE_EXTENSION" ]; then
      OMP_ARGS+=(--extension "$NUDGE_EXTENSION")
    fi

    # Only checks and reports here - it does not run the login itself. A device-
    # code flow blocks on human approval, which starting this session is the
    # wrong place to wait on: it stalls -p/one-shot runs outright, and even
    # interactively it delays the TUI coming up for something the nudge
    # extension already handles once the session starts (session_start check,
    # /aws-login, and a relogin on a 401/403 mid-turn).
    if ! aws sts get-caller-identity --profile omp-bedrock >/dev/null 2>&1; then
      echo "omp-sbx: no AWS SSO session for $AWS_SSO_PROFILE yet." >&2
      echo "omp-sbx: run 'omp-sbx-aws-login' on the host - it opens a real browser and the" >&2
      echo "omp-sbx: session is shared with every sandbox from then on. Or once this session" >&2
      echo "omp-sbx: starts, run /aws-login here." >&2
    fi
  fi
fi

# ── MCP gateway (opt-in) ────────────────────────────────────────────────────
# sbx serves the host's MCP registry to this sandbox over a gateway and injects
# its URL. Register the servers on the host first, with omp-sbx-mcp-import.
#
# A project opts in with OMP_SBX_MCP_GATEWAY=1 in its .env. Off by default: a
# gateway with nothing attached still hands omp the meta-tools that register
# more servers, which is not a choice to make on every project's behalf.
#
# The server definition goes in a --plugin-dir root rather than an mcp.json.
# omp looks for mcp.json in its config dir and the workspace, and both are host
# mounts here, so writing one would leave a URL in the host config that only
# resolves inside a sandbox. A plugin root is read from wherever it points.
MCP_GATEWAY_OPT=""
if [ -f "$WORKSPACE_ENV" ]; then
  MCP_GATEWAY_OPT="$(env_value OMP_SBX_MCP_GATEWAY "$WORKSPACE_ENV")"
fi

case "$MCP_GATEWAY_OPT" in
  1|true|on|yes)
    if [ -z "${MCP_GATEWAY_URL:-}" ]; then
      echo "omp-sbx: OMP_SBX_MCP_GATEWAY is set but this sandbox has no MCP gateway" >&2
    else
      # Rewritten every launch, so a sandbox that comes back with a different
      # gateway URL picks it up.
      #
      # The manifest is a bare plugin.json for its name alone, which becomes the
      # tool prefix: mcp__sbx_gateway_<tool>. omp reads the name from here or the
      # directory basename, and nowhere else. It reads the servers from .mcp.json
      # once no manifest declares an mcpServers pointer, so the two stay apart.
      MCP_PLUGIN_DIR="$HOME/.cache/omp-sbx/plugins/sbx"
      mkdir -p "$MCP_PLUGIN_DIR"
      printf '{"name":"sbx","version":"local"}\n' >"$MCP_PLUGIN_DIR/plugin.json"
      printf '{"mcpServers":{"gateway":{"type":"http","url":"%s"}}}\n' "$MCP_GATEWAY_URL" \
        >"$MCP_PLUGIN_DIR/.mcp.json"
      OMP_ARGS+=(--plugin-dir "$MCP_PLUGIN_DIR")
    fi
    ;;
esac

# The startup hook turns this path into a symlink to the host workspace, so
# enter it here rather than declaring it as the image WORKDIR - sbx's own
# setup execs run before the hook and would fail on a moving path.
cd /home/agent/workspace
exec omp "${OMP_ARGS[@]}" "$@"
