#!/usr/bin/env bash
# Check the things that cannot be fixed on demo morning.
#
# Every item here corresponds to something that is either invisible until it
# fails, or slow to provision. Run it the day before, not an hour before.

. "$(dirname "$0")/_lib.sh"

fails=0
check()  { printf "  %-46s" "$1"; }
pass()   { printf "%s✓%s %s\n" "$c_green" "$c_reset" "${1:-}"; }
fail()   { printf "%s✗%s %s\n" "$c_red" "$c_reset" "$1"; fails=$((fails+1)); }
softish(){ printf "%s?%s %s\n" "$c_yellow" "$c_reset" "$1"; }

echo "=== tooling ==="
for t in rpai jq curl psql python3; do
  check "$t on PATH"
  command -v "$t" >/dev/null && pass "$(command -v "$t")" || fail "not found"
done

# The manifests and commands here need rpai 0.2.x or newer. Older versions have a
# different command surface and fail in confusing ways.
check "rpai is 0.2.x or newer"
RPAI_VER="$(rpai version 2>/dev/null | awk '{print $2}')"
case "$RPAI_VER" in
  0.2*|0.[3-9]*|[1-9]*) pass "$RPAI_VER" ;;
  "")                   fail "could not read version" ;;
  *)                    fail "$RPAI_VER is too old — brew upgrade rpai" ;;
esac

echo
echo "=== auth ==="
check "rpai token"
if TOKEN="$(rpai $(rpai_cfg) auth token 2>/dev/null)" && [ -n "$TOKEN" ]; then
  pass; export TOKEN
else
  fail "run: rpai auth login"
fi

echo
echo "=== postgres ==="
check "PG_ADMIN_DSN reachable"
if [ -n "${PG_ADMIN_DSN:-}" ] && psql "$PG_ADMIN_DSN" -tAc 'SELECT 1' >/dev/null 2>&1; then
  pass "$(psql "$PG_ADMIN_DSN" -tAc 'SHOW server_version' 2>/dev/null | head -1)"
else
  fail "cannot connect with PG_ADMIN_DSN"
fi

check "PG_HOST is publicly reachable (not private)"
case "${PG_HOST:-}" in
  ""|localhost|127.0.0.1|10.*|192.168.*|172.1[6-9].*|172.2*.*|172.3[01].*)
    fail "PG_HOST='${PG_HOST:-unset}' — aigw safedial refuses private addresses" ;;
  *) pass "$PG_HOST" ;;
esac

echo
echo "=== cluster capabilities ==="
if [ -n "${TOKEN:-}" ]; then
  check "LLM provider '$LLM_PROVIDER' exists"
  PROVIDERS="$(rpai $(rpai_cfg) llm-provider list -o json 2>/dev/null || echo '[]')"
  if echo "$PROVIDERS" | jq -e --arg n "$LLM_PROVIDER" 'if type=="array" then any(.[]; (.name // "") == $n) else false end' >/dev/null 2>&1; then
    pass
  else
    softish "could not confirm via rpai — check '$LLM_PROVIDER' in the UI, and that it allows '$LLM_MODEL'"
  fi

  check "SQL managed MCP type available"
  TYPES="$(adp_rpc redpanda.api.adp.v1alpha1.MCPServerService/ListManagedMCPTypes '{}' 2>/dev/null || echo '{}')"
  if echo "$TYPES" | grep -qi 'SQLMCPConfig'; then
    pass "ungated, as expected"
  else
    softish "not found in ListManagedMCPTypes — check the response by hand"
  fi
fi

echo
echo "=== two identities (slowest to arrange — do this first) ==="
for who in "COORDINATOR_EMAIL:$COORDINATOR_EMAIL" "CONTRACTOR_EMAIL:$CONTRACTOR_EMAIL"; do
  check "${who%%:*} set"
  [ -n "${who#*:}" ] && pass "${who#*:}" || fail "unset"
done
cat <<'EOF'
  ! Both users must exist in the org and have access to the agent. This script
    cannot check that — sign in as each of them to confirm. Showing two people
    side by side needs two signed-in profiles.
EOF

echo
echo "=== policy check ==="
check "no Group: principals in config/policies"
if grep -rq '"Group:' "$ROOT/config/policies" 2>/dev/null; then
  fail "a Group: principal exists — fails CLOSED for the whole MCP server"
else
  pass
fi

echo
if [ "$fails" -gt 0 ]; then
  die "$fails preflight check(s) failed"
fi
ok "preflight clean"
