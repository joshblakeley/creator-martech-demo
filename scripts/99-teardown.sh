#!/usr/bin/env bash
# Reverse the provisioning. Leaves the Postgres data alone — `make db-drop`
# handles that separately, because re-seeding is slow and usually not what
# you want when you are just recycling the agent.

. "$(dirname "$0")/_lib.sh"
require_token

# Budgets have no rpai command yet, so that one still goes through the API.
log "deleting budget '$BUDGET_NAME'"
adp_rpc redpanda.api.adp.v1alpha1.BudgetService/DeleteBudget \
  "$(jq -nc --arg n "$BUDGET_NAME" '{name:$n}')" >/dev/null 2>&1 || true

log "deleting agent '$AGENT_NAME'"
rpai $(rpai_cfg) agent delete "$AGENT_NAME" >/dev/null 2>&1 || true

for m in "$MCP_CREATOR" "$MCP_FIT" "$MCP_CAMPAIGN"; do
  log "deleting MCP '$m'"
  rpai $(rpai_cfg) mcp delete "$m" >/dev/null 2>&1 || true
done

for s in "$PG_CREATOR_SECRET" "$PG_FIT_SECRET" "$PG_CAMPAIGN_SECRET"; do
  log "deleting secret '$s'"
  dp_del "/v1/secrets/$s" >/dev/null 2>&1 || true
done

rm -rf "$STATE_DIR"
ok "torn down (Postgres data left intact — use 'make db-drop' for that)"
