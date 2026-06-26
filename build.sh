#!/usr/bin/env bash
# Build and load the omp-sbx template image into the sbx runtime.
# OMP_VERSION resolution: $OMP_VERSION env → latest GitHub release tag.
#
# Release cooldown: when fetching the latest release automatically, the script
# warns if the release is newer than RELEASE_COOLDOWN_DAYS (default: 3) and
# asks for confirmation. This protects against 0-day/compromised upstreams.
# Override with: RELEASE_COOLDOWN_DAYS=0 ./build.sh  (skip the check)
# Or pin explicitly: OMP_VERSION=16.1.17 ./build.sh  (no check needed)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_COOLDOWN_DAYS="${RELEASE_COOLDOWN_DAYS:-3}"

# Colors (only when stderr is a tty)
if [ -t 2 ]; then
  C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_DIM=''; C_CYAN=''; C_YELLOW=''; C_RED=''; C_GREEN=''; C_BOLD=''; C_RST=''
fi

# ── Preflight: ensure sbx CLI is installed ──────────────────────────────────
# shellcheck source=sbx-preflight.sh
source "$DIR/sbx-preflight.sh"
ensure_sbx "build.sh"

if [ -z "${OMP_VERSION:-}" ]; then
  echo ">> fetching latest omp release tag" >&2

  # Fetch release info: tag name and published date in one call.
  RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/can1357/oh-my-pi/releases/latest)"
  OMP_VERSION="$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
  PUBLISHED_AT="$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"published_at": *"\([^"]*\)".*/\1/p' | head -1)"

  OMP_VERSION="${OMP_VERSION:?could not determine OMP_VERSION}"

  # Release cooldown check: warn if the release is newer than the cooldown period.
  # Skip if RELEASE_COOLDOWN_DAYS=0 or if we can't parse the date.
  if [ "${RELEASE_COOLDOWN_DAYS}" -gt 0 ] && [ -n "$PUBLISHED_AT" ]; then
    # Convert published_at to epoch seconds (portable: works on macOS and Linux).
    # GitHub returns ISO 8601 like "2026-06-22T15:30:00Z".
    RELEASE_TS="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$PUBLISHED_AT" +%s 2>/dev/null || \
                  date -u -d "$PUBLISHED_AT" +%s 2>/dev/null || echo "")"
    NOW_TS="$(date -u +%s)"

    if [ -n "$RELEASE_TS" ]; then
      AGE_DAYS=$(( (NOW_TS - RELEASE_TS) / 86400 ))
      AGE_HOURS=$(( (NOW_TS - RELEASE_TS) / 3600 ))

      if [ "$AGE_DAYS" -lt "$RELEASE_COOLDOWN_DAYS" ]; then
        echo "" >&2
        echo "${C_YELLOW}⚠ WARNING: omp v${OMP_VERSION} was published ${AGE_HOURS}h ago${C_RST}" >&2
        echo "${C_YELLOW}  (released: ${PUBLISHED_AT}, cooldown: ${RELEASE_COOLDOWN_DAYS} days)${C_RST}" >&2
        echo "${C_DIM}  This release is very new and may not have been vetted by the community yet.${C_RST}" >&2
        echo "${C_DIM}  If this is a compromised upstream, running it could execute malicious code.${C_RST}" >&2
        echo "" >&2

        if [ -t 0 ]; then
          printf '%sProceed anyway? [y/N] %s' "${C_YELLOW}" "${C_RST}" >&2
          read -r answer < /dev/tty
          case "$answer" in
            y|Y|yes|YES)
              echo "${C_DIM}proceeding with v${OMP_VERSION}${C_RST}" >&2
              ;;
            *)
              echo "${C_RED}aborted. Pin a specific version with: OMP_VERSION=16.1.17 $0${C_RST}" >&2
              exit 1
              ;;
          esac
        else
          echo "${C_RED}non-interactive shell; aborting. Set RELEASE_COOLDOWN_DAYS=0 to skip this check${C_RST}" >&2
          exit 1
        fi
      else
        echo "${C_DIM}>> omp v${OMP_VERSION} released ${AGE_DAYS}d ago (within cooldown)${C_RST}" >&2
      fi
    fi
  fi
fi

OMP_VERSION="${OMP_VERSION:?could not determine OMP_VERSION}"
IMAGE="${OMP_SBX_IMAGE:-omp-sbx:latest}"

echo ">> building ${IMAGE} (omp v${OMP_VERSION})"
docker build \
  --build-arg "OMP_VERSION=${OMP_VERSION}" \
  -t "${IMAGE}" \
  -f "${DIR}/sbx-kit/Dockerfile" \
  "${DIR}"

echo ">> saving + loading into sbx runtime"
docker image save "${IMAGE}" -o /tmp/omp-sbx.tar
if ! sbx template load /tmp/omp-sbx.tar; then
  if [ -t 2 ]; then C_BRED=$'\033[1;31m'; C_RST=$'\033[0m'; else C_BRED=''; C_RST=''; fi
  echo "" >&2
  echo "${C_BRED}ERROR: sbx template load failed.${C_RST}" >&2
  echo "${C_BRED}If the error mentions '401 Unauthorized' or 'no valid user session',${C_RST}" >&2
  echo "${C_BRED}you are not authenticated to Docker/sbx. Run:${C_RST}" >&2
  echo "" >&2
  echo "  sbx login" >&2
  echo "" >&2
  echo "${C_BRED}then re-run ./build.sh${C_RST}" >&2
  rm -f /tmp/omp-sbx.tar
  exit 1
fi

echo ">> verifying"
sbx create -q --kit "${DIR}/sbx-kit" --template "${IMAGE}" --name omp-verify omp /tmp 2>/dev/null || true
sleep 2
sbx exec omp-verify omp --version 2>&1 || true
sbx rm -f omp-verify 2>/dev/null || true
echo "✓ done"
