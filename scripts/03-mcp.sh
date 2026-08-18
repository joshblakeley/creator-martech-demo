#!/usr/bin/env bash
# Reconcile the three SQL MCP servers from config/manifests/*.yaml.
#
# Three servers rather than one, because a single server cannot be narrowed per
# specialist. Each logs into Postgres as a different least-privilege role, so the
# boundary is a database permission rather than a filter.
#
# `rpai mcp apply` creates a server if absent, otherwise updates only the fields
# the manifest names that differ from live. It does not delete servers the
# manifests do not mention. `rpai mcp diff` shows what it would change.
#
# The data policies live in the manifests too, so there is no separate step for
# them — a policy is a field on the server it applies to, not its own resource.
#
# Response compression is off in the manifests: it packs rows into a positional
# grid and the agent misreads columns. See the note at the top of any manifest.

. "$(dirname "$0")/_lib.sh"
require_token

: "${CONTRACTOR_EMAIL:?set CONTRACTOR_EMAIL in env/<env>.env}"

if [ "$CONTRACTOR_EMAIL" != "${CONTRACTOR_EMAIL#Group:}" ] || \
   grep -rq 'Group:' "$ROOT/config/manifests" 2>/dev/null; then
  die "a manifest targets a group. That is unsupported, and it stops every call on the whole server — not just the group's. Target one person."
fi

RENDERED="$(mktemp -d)"
trap 'rm -rf "$RENDERED"' EXIT

for m in "$ROOT"/config/manifests/*-sql.yaml; do
  sed "s|__CONTRACTOR_EMAIL__|$CONTRACTOR_EMAIL|g" "$m" > "$RENDERED/$(basename "$m")"
done

log "diff against live"
rpai $(rpai_cfg) mcp diff -f "$RENDERED" || true

log "applying"
rpai $(rpai_cfg) mcp apply -f "$RENDERED"

# Confirm the setting a policy silently depends on actually stuck. A server that
# fell back to positional rows would make every per-column rule a no-op with no
# error anywhere.
#
# Note `get -o json` emits snake_case field names, so the path here is
# row_format, not rowFormat.
for name in "$MCP_CREATOR" "$MCP_FIT" "$MCP_CAMPAIGN"; do
  fmt="$(rpai $(rpai_cfg) mcp get "$name" -o json 2>/dev/null | jq -r '.managed.config.row_format // "<absent>"')"
  [ "$fmt" = "ROW_FORMAT_OBJECT" ] \
    || die "$name has row_format '$fmt', not ROW_FORMAT_OBJECT. Per-column data policies would silently do nothing."
done
ok "three servers reconciled, row format confirmed"

# Check the policy does what it claims, using the same engine the live gateway
# runs. The preview evaluates for whoever is calling, so the same rules are
# previewed with the audience left open against a captured response. Nothing is
# saved; the stored policy keeps targeting one person.
#
# The sample below is a real captured response: the SQL server sends every value
# as a string ("9", not 9). A sample written with numbers would pass this check
# while the real thing failed.
SAMPLE='{"columns":["handle","email","phone","brand_safety_score","safety_tier","lifetime_gmv_usd"],
  "records":[
    {"handle":"probe-keep","email":"keep@example.com","phone":"+1-415-555-0148","brand_safety_score":"9","safety_tier":"approved","lifetime_gmv_usd":"117120"},
    {"handle":"probe-ten","email":"ten@example.com","phone":"+1-415-555-0100","brand_safety_score":"10","safety_tier":"approved","lifetime_gmv_usd":"90000"},
    {"handle":"probe-drop","email":"drop@example.com","phone":"+1-702-555-0143","brand_safety_score":"4","safety_tier":"restricted","lifetime_gmv_usd":"18000"}
  ],"row_count":3,"rows":[],"truncated":false}'

DRAFT="$(sed "s|__CONTRACTOR_EMAIL__|$CONTRACTOR_EMAIL|g" "$ROOT/config/manifests/creator-sql.yaml" \
  | python3 -c 'import sys,yaml,json; print(json.dumps(yaml.safe_load(sys.stdin)["data_policies"][0] | {"principals": []}))')"

for server in "$MCP_CREATOR" "$MCP_FIT"; do
  SHAPED="$(adp_rpc redpanda.api.adp.v1alpha1.MCPServerService/PreviewToolResponse \
    "$(jq -nc --arg n "$server" --arg t query --arg s "$SAMPLE" --argjson d "$DRAFT" \
      '{name:$n, tool:$t, sampleResponse:$s, draftDataPolicies:[$d], hasDraft:true}')" \
    2>/dev/null | jq -r '.shapedResponse // empty')"

  [ -n "$SHAPED" ] || { warn "$server: preview returned nothing — check the policy by hand"; continue; }

  fails=""
  echo "$SHAPED" | jq -e '.records[0].email == "[redacted]"'           >/dev/null 2>&1 || fails="$fails email"
  echo "$SHAPED" | jq -e '.records[0].phone | endswith("0148")'        >/dev/null 2>&1 || fails="$fails phone-tail"
  echo "$SHAPED" | jq -e '.records[0].phone | startswith("*")'         >/dev/null 2>&1 || fails="$fails phone-mask"
  echo "$SHAPED" | jq -e '.records[0] | has("lifetime_gmv_usd") | not' >/dev/null 2>&1 || fails="$fails revenue"
  echo "$SHAPED" | jq -e '(.records | length) == 2'                    >/dev/null 2>&1 || fails="$fails row-filter"
  echo "$SHAPED" | jq -e '[.records[].handle] | index("probe-ten") != null' >/dev/null 2>&1 || fails="$fails two-digit"

  [ -z "$fails" ] || die "$server: the policy did not behave as configured —$fails"
  ok "$server: redact, mask, drop and row filter all confirmed"
done

log "$MCP_CAMPAIGN has no policy by design (rollups carry no personal details)"
warn "note: a row filter removes records but does not update the row count."
