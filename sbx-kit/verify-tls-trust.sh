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
ALLOWED_HOST="registry.npmjs.org"        # in spec.yaml allowedDomains
BLOCKED_HOST="example.com"               # not in allowedDomains

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

# ── 5a. Allowed domain: TLS chain validates through proxy ────────────────────
_head "5a. TLS chain through proxy to ${ALLOWED_HOST} (allowed domain)"
chain=$(echo | openssl s_client \
  -connect "${ALLOWED_HOST}:443" \
  -proxy "$PROXY" \
  -CAfile "$CA_BUNDLE" \
  2>&1) || true

issuer_d0=$(echo "$chain" | grep "^issuer=" | head -1 | sed 's/^issuer=//') || true
verify_ok=$(echo "$chain" | grep -c "Verify return code: 0 (ok)") || true

if [ "$verify_ok" -ge 1 ]; then
  _pass "Chain verified OK  |  issuer: ${issuer_d0}"
else
  rc_line=$(echo "$chain" | grep "Verify return code:" | tail -1)
  _fail "Chain did NOT verify  |  ${rc_line:-no verify line found}"
fi

# ── 5b. Non-allowed domain: blocked by policy even through proxy ──────────────
_head "5b. Non-allowed domain blocked through proxy (${BLOCKED_HOST})"
blocked_proxy=$(curl -sv --max-time 5 "https://${BLOCKED_HOST}" 2>&1) || true

if echo "$blocked_proxy" | grep -qi "blocked by network policy"; then
  _pass "https://${BLOCKED_HOST} blocked by sbx network policy (allowedDomains enforced)"
else
  http_status=$(echo "$blocked_proxy" | grep -oE "HTTP/[0-9.]+ [0-9]+" | tail -1) || true
  if [ -n "$http_status" ]; then
    _fail "https://${BLOCKED_HOST} reached with ${http_status} — domain policy may not be enforced"
  else
    _pass "https://${BLOCKED_HOST} did not succeed (not in allowedDomains)"
  fi
fi

# ── 6a. Allowed domain reachable without proxy env ───────────────────────────
# sbx permits allowedDomains at the network level — stripping proxy env vars
# should not break access to permitted domains.
_head "6a. Allowed domain reachable without proxy env (${ALLOWED_HOST})"
allowed_direct=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  curl -sf --max-time 10 -o /dev/null -w "%{http_code}" "https://${ALLOWED_HOST}" 2>&1) || true

if echo "$allowed_direct" | grep -qE "^[23][0-9][0-9]$"; then
  _pass "https://${ALLOWED_HOST} reachable without proxy env (HTTP ${allowed_direct}) — network-level allow works"
else
  _fail "https://${ALLOWED_HOST} unreachable without proxy env (got: '${allowed_direct}') — expected allowed domain to be reachable"
fi

# ── 6b. Non-allowed domain blocked even without proxy env ─────────────────────
# Blocked domains should be rejected at the network level regardless of proxy config.
_head "6b. Non-allowed domain blocked without proxy env (${BLOCKED_HOST})"
blocked_direct=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  curl -sv --max-time 5 "https://${BLOCKED_HOST}" 2>&1) || true

if echo "$blocked_direct" | grep -qi "blocked by network policy"; then
  _pass "https://${BLOCKED_HOST} blocked at network level without proxy env (policy enforced by sbx, not proxy config)"
else
  http_status=$(echo "$blocked_direct" | grep -oE "HTTP/[0-9.]+ [0-9]+" | tail -1) || true
  if [ -n "$http_status" ]; then
    _fail "https://${BLOCKED_HOST} reached with ${http_status} without proxy env — network policy not enforced"
  else
    _pass "https://${BLOCKED_HOST} did not succeed without proxy env"
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
