#!/usr/bin/env bash
# Build and load the omp-sbx template image into the sbx runtime.
# OMP_VERSION resolution: $OMP_VERSION env → latest GitHub release tag.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${OMP_VERSION:-}" ]; then
  echo ">> fetching latest omp release tag" >&2
  OMP_VERSION="$(curl -fsSL https://api.github.com/repos/can1357/oh-my-pi/releases/latest \
    | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
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
sbx template load /tmp/omp-sbx.tar
rm -f /tmp/omp-sbx.tar

echo ">> verifying"
sbx create -q --kit "${DIR}/sbx-kit" --template "${IMAGE}" --name omp-verify omp /tmp 2>/dev/null || true
sleep 2
sbx exec omp-verify omp --version 2>&1 || true
sbx rm -f omp-verify 2>/dev/null || true
echo "✓ done"
