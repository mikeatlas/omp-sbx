#!/usr/bin/env bash
# gen-proxy-ca.sh — generate a fresh self-signed CA for the sbx TLS proxy.
#
# Usage: ./sbx-kit/gen-proxy-ca.sh
#
# Outputs:
#   sbx-kit/sbx-proxy-ca.crt  — public certificate (baked into the browser container)
#   sbx-kit/sbx-ca.key         — private key (for the proxy — keep secret, do NOT commit)
#
# After running this script:
#   1. Rebuild the Docker image so the new cert is installed:
#        docker build -t omp-sbx:latest -f sbx-kit/Dockerfile .
#   2. Mount sbx-ca.key into your proxy container.
#   3. The public cert is trusted by the browser container via update-ca-certificates.
#
# sbx-ca.key is gitignored. Never commit it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

KEY_FILE="$SCRIPT_DIR/sbx-ca.key"
CERT_FILE="$SCRIPT_DIR/sbx-proxy-ca.crt"

if [ -f "$KEY_FILE" ]; then
  echo "Key already exists at $KEY_FILE — remove it first to regenerate." >&2
  exit 1
fi

openssl req -x509 -newkey rsa:4096 \
  -keyout "$KEY_FILE" \
  -out "$CERT_FILE" \
  -days 3650 \
  -nodes \
  -subj "/CN=sbx-proxy-ca/O=omp-sbx"

chmod 600 "$KEY_FILE"

echo ""
echo "Generated:"
echo "  Certificate: $CERT_FILE"
echo "  Private key: $KEY_FILE  (keep secret — do NOT commit)"
echo ""
echo "Next steps:"
echo "  1. Rebuild the image:  docker build -t omp-sbx:latest -f sbx-kit/Dockerfile ."
echo "  2. Mount $KEY_FILE into your proxy container (not the browser container)."
echo "  3. The public cert is trusted by the browser container via update-ca-certificates."
