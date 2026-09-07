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

# Read the host path, not /home/agent/workspace: the symlink to it belongs to
# the startup hook, which has not necessarily run yet.
WORKSPACE_ENV="${WORKSPACE_DIR:-/home/agent/workspace}/.env"
SSO_PROFILE=""
if [ -f "$WORKSPACE_ENV" ]; then
  SSO_PROFILE="$(env_value OMP_SBX_AWS_PROFILE "$WORKSPACE_ENV")"
fi

if [ -n "$SSO_PROFILE" ]; then
  AWS_CONFIG_SRC="$HOME/.omp/aws-config"
  if [ ! -f "$AWS_CONFIG_SRC" ]; then
    echo "omp-sbx: OMP_SBX_AWS_PROFILE=$SSO_PROFILE needs a profile definition in ~/.omp/aws-config" >&2
  else
    SSO_REGION="$(env_value OMP_SBX_AWS_REGION "$WORKSPACE_ENV")"
    SSO_REGION="${SSO_REGION:-us-east-1}"

    mkdir -p "$HOME/.aws"
    {
      cat "$AWS_CONFIG_SRC"
      printf '\n[profile omp-bedrock]\n'
      printf 'credential_process = aws configure export-credentials --profile %s --format process\n' "$SSO_PROFILE"
      printf 'region = %s\n' "$SSO_REGION"
    } > "$HOME/.aws/config"

    export AWS_PROFILE="omp-bedrock"
    export AWS_REGION="$SSO_REGION"

    # A failed login leaves omp running without Bedrock rather than blocking the
    # session: the rest of the agent still works, and `aws sso login` can be
    # re-run from a shell inside the sandbox.
    if ! aws sts get-caller-identity --profile omp-bedrock >/dev/null 2>&1; then
      echo "omp-sbx: the AWS SSO session for $SSO_PROFILE has expired. Open the URL below to renew it." >&2
      aws sso login --no-browser --profile "$SSO_PROFILE" \
        || echo "omp-sbx: aws sso login failed - Bedrock models stay unavailable this session" >&2
    fi
  fi
fi

# The startup hook turns this path into a symlink to the host workspace, so
# enter it here rather than declaring it as the image WORKDIR - sbx's own
# setup execs run before the hook and would fail on a moving path.
cd /home/agent/workspace
exec omp "$@"
