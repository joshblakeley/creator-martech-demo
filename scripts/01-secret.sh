#!/usr/bin/env bash
# Idempotently create/update the three Postgres DSN cluster secrets — one
# per SQL MCP server, each carrying a different least-privilege role.
#
# The DSNs are assembled here from PG_HOST/PG_PORT/PG_DATABASE plus the
# per-role passwords in env/secrets.env, so the passwords appear in exactly
# one place and the secret values never land in a committed file.
#
# sslmode=require is not optional: prod aigw dials this over the public
# internet. `safedial` will also refuse a private address, so PG_HOST must
# be a publicly resolvable TLS endpoint.

. "$(dirname "$0")/_lib.sh"
require_token

: "${PG_HOST:?set PG_HOST in env/<env>.env}"
: "${PG_PORT:=5432}"
: "${PG_DATABASE:?set PG_DATABASE in env/<env>.env}"
: "${PG_CREATOR_PW:?set PG_CREATOR_PW in env/secrets.env}"
: "${PG_FIT_PW:?set PG_FIT_PW in env/secrets.env}"
: "${PG_CAMPAIGN_PW:?set PG_CAMPAIGN_PW in env/secrets.env}"

case "$PG_HOST" in
  localhost|127.0.0.1|10.*|192.168.*|172.1[6-9].*|172.2*.*|172.3[01].*)
    warn "PG_HOST=$PG_HOST looks private. aigw's safedial will refuse to dial it."
    warn "This needs a Postgres reachable over the public internet with TLS."
    ;;
esac

SCOPES='["SCOPE_MCP_SERVER","SCOPE_AI_AGENT","SCOPE_AI_GATEWAY"]'

put_dsn_secret() {
  local secret_name="$1" role="$2" password="$3"
  local dsn="postgres://${role}:${password}@${PG_HOST}:${PG_PORT}/${PG_DATABASE}?sslmode=require"
  local body
  body="$(jq -nc --arg id "$secret_name" --arg s "$(b64 "$dsn")" --argjson scopes "$SCOPES" \
    '{id:$id, secret_data:$s, scopes:$scopes, labels:{owner:"creator-martech-demo"}}')"

  if [ -n "$(dp_get "/v1/secrets/$secret_name" 2>/dev/null | jq -r '.secret.id // empty')" ]; then
    log "$secret_name exists — updating"
    dp_put "/v1/secrets/$secret_name" "$body" >/dev/null
  else
    log "$secret_name does not exist — creating"
    dp_post "/v1/secrets" "$body" >/dev/null
  fi
  ok "$secret_name -> role '$role'"
}

put_dsn_secret "$PG_CREATOR_SECRET"  creator_sql  "$PG_CREATOR_PW"
put_dsn_secret "$PG_FIT_SECRET"      fit_sql      "$PG_FIT_PW"
put_dsn_secret "$PG_CAMPAIGN_SECRET" campaign_sql "$PG_CAMPAIGN_PW"
