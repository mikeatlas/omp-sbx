#!/usr/bin/env bash
# verify-tls-trust.sh — confirm the sbx proxy CA is properly trusted and
# that the sandbox is NOT running with blanket cert-error bypass.
#
# Run from inside an omp-sbx sandbox after rebuilding with the hardened spec:
#   bash sbx-kit/verify-tls-trust.sh
#
# Each check prints PASS or FAIL with a short explanation.
# Exit code is 0 only if every check passes.

set -euo pipefail

PROXY="gateway.docker.internal:3128"
CA_CERT="/usr/local/share/ca-certificates/proxy-ca.crt"
CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
TEST_HOST="example.com"
TEST_HOST_PORT="${TEST_HOST}:443"

PASS=0
FAIL=0

_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }
_head() { echo; echo "── $1 ──"; }

# ── 1. Env: cert-error bypass must be off ─────────────────────────────────────
_head "1. AGENT_BROWSER_IGNORE_HTTPS_ERRORS"
val="${AGENT_BROWSER_IGNORE_HTTPS_ERRORS:-}"
if [ "$val" = "false" ] || [ -z "$val" ]; then
  _pass "AGENT_BROWSER_IGNORE_HTTPS_ERRORS=${val:-<unset>}  (cert validation is enabled)"
else
  _fail "AGENT_BROWSER_IGNORE_HTTPS_ERRORS=${val}  (blanket bypass is ON — this is the bug)"
fi

# ── 2. Proxy CA cert exists ───────────────────────────────────────────────────
_head "2. Proxy CA cert present at ${CA_CERT}"
if [ -f "$CA_CERT" ]; then
  subject=$(openssl x509 -noout -subject -in "$CA_CERT" 2>/dev/null | sed 's/subject=//')
  dates=$(openssl x509 -noout -dates -in "$CA_CERT" 2>/dev/null | tr '\n' '  ')
  _pass "Found: ${subject}  |  ${dates}"
else
  _fail "File not found: ${CA_CERT}  (sbx did not inject the proxy CA)"
fi

# ── 3. Proxy CA is trusted by the OS bundle ───────────────────────────────────
_head "3. Proxy CA trusted in OS bundle (${CA_BUNDLE})"
if [ -f "$CA_CERT" ]; then
  if openssl verify -CAfile "$CA_BUNDLE" "$CA_CERT" >/dev/null 2>&1; then
    _pass "openssl verify OK  (proxy CA is in the trusted bundle)"
  else
    _fail "openssl verify FAILED  (proxy CA not in bundle — update-ca-certificates may not have run)"
  fi
else
  _fail "Skipped — CA cert not present (see check 2)"
fi

# ── 4. Proxy env vars are set ─────────────────────────────────────────────────
_head "4. Proxy env vars (HTTP_PROXY / HTTPS_PROXY)"
http_proxy_val="${HTTP_PROXY:-${http_proxy:-}}"
https_proxy_val="${HTTPS_PROXY:-${https_proxy:-}}"
if [ -n "$http_proxy_val" ] && [ -n "$https_proxy_val" ]; then
  _pass "HTTP_PROXY=${http_proxy_val}  HTTPS_PROXY=${https_proxy_val}"
else
  _fail "Proxy env vars missing  (HTTP_PROXY='${http_proxy_val}'  HTTPS_PROXY='${https_proxy_val}')"
fi

# ── 5. HTTPS via proxy: cert chain signed by proxy CA ─────────────────────────
_head "5. TLS chain through proxy to ${TEST_HOST}"
chain=$(echo | openssl s_client \
  -connect "$TEST_HOST_PORT" \
  -proxy "$PROXY" \
  -CAfile "$CA_BUNDLE" \
  -showcerts \
  2>&1) || true

# Check the chain depth-1 issuer is the proxy CA
issuer_d0=$(echo "$chain" | grep "^issuer=" | head -1 | sed 's/^issuer=//') || true
verify_ok=$(echo "$chain" | grep -c "Verify return code: 0 (ok)") || true

if [ "$verify_ok" -ge 1 ]; then
  _pass "Chain verified OK  |  leaf issuer: ${issuer_d0}"
else
  rc_line=$(echo "$chain" | grep "Verify return code:" | tail -1)
  _fail "Chain did NOT verify  |  ${rc_line:-no verify line found}"
fi

# Confirm the proxy actually intercepted (leaf cert issuer is proxy CA, not origin CA)
if echo "$issuer_d0" | grep -qi "Docker Sandboxes"; then
  _pass "Leaf cert issued by Docker Sandboxes Proxy CA  (interception confirmed)"
else
  _fail "Leaf cert NOT issued by proxy CA  (issuer: '${issuer_d0}') — proxy may not be intercepting"
fi

# ── 6. Direct egress is blocked ───────────────────────────────────────────────
_head "6. Direct egress blocked (no proxy)"
# Unset proxy env for this call so curl goes direct
direct_out=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  curl -sv --max-time 5 "https://${TEST_HOST}" 2>&1) || true

if echo "$direct_out" | grep -qi "blocked by network policy"; then
  _pass "Direct HTTPS to ${TEST_HOST} blocked by sbx network policy"
elif echo "$direct_out" | grep -qi "Could not resolve\|Connection refused\|Network is unreachable\|timed out"; then
  _pass "Direct HTTPS to ${TEST_HOST} unreachable (no direct internet path)"
else
  http_status=$(echo "$direct_out" | grep -oP "< HTTP/\S+ \K[0-9]+" | head -1) || true
  if [ -n "$http_status" ]; then
    _fail "Direct HTTPS to ${TEST_HOST} succeeded with HTTP ${http_status} — sandbox may have unproxied egress"
  else
    _pass "Direct HTTPS to ${TEST_HOST} did not succeed (${direct_out##*$'\n':-no connection})"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────────"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "────────────────────────────────────────────"
echo

if [ "$FAIL" -gt 0 ]; then
  echo "  One or more checks failed."
  echo "  If AGENT_BROWSER_IGNORE_HTTPS_ERRORS is not 'false', rebuild from the"
  echo "  hardened spec.yaml and recreate the sandbox."
  echo "  If the proxy CA is missing, check sbx startup logs — it should inject"
  echo "  /usr/local/share/ca-certificates/proxy-ca.crt before the agent starts."
  echo
  exit 1
else
  echo "  All checks passed. The sandbox is using proper TLS trust, not a blanket bypass."
  echo
  exit 0
fi
