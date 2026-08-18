#!/usr/bin/env bash
# Create a per-agent budget so spend is visible and capped.
#
# Scope limit: the only filter available is by agent name. There is no per-user
# budget, so per-agent limits work and per-user limits are not possible.
#
# Amounts are microcents: 1 USD = 100 cents = 100_000_000 microcents.

. "$(dirname "$0")/_lib.sh"
require_token

: "${BUDGET_LIMIT_USD:=25}"
: "${BUDGET_WARN_USD:=20}"

LIMIT_MC=$(( BUDGET_LIMIT_USD * 100000000 ))
WARN_MC=$(( BUDGET_WARN_USD * 100000000 ))

# filter_agent_name stores the AIP-122 RESOURCE NAME ("agents/<slug>"), not a
# bare slug — it is matched at request time against the JWT `agent_name` claim
# (budget.proto). A bare name silently matches nothing: the budget is created,
# looks correct in a list, and never applies to any spend. At least one budget
# already on the shared cluster has exactly this bug.
#
# It is also immutable, so a wrong value cannot be patched — hence the
# delete-and-recreate below.
BODY="$(jq -nc \
  --arg name "$BUDGET_NAME" \
  --arg dn "Creator matchmaking demo — $AGENT_NAME" \
  --arg agent "agents/$AGENT_NAME" \
  --argjson limit "$LIMIT_MC" \
  --argjson warn "$WARN_MC" \
  '{
    budget: {
      name: $name,
      displayName: $dn,
      poolingMode: "POOLING_MODE_PER_AGENT",
      filterAgentName: $agent,
      period: "BUDGET_PERIOD_DAILY",
      limitMicrocents: $limit,
      warnAtMicrocents: $warn
    }
  }')"

if adp_rpc redpanda.api.adp.v1alpha1.BudgetService/GetBudget \
     "$(jq -nc --arg n "$BUDGET_NAME" '{name:$n}')" >/dev/null 2>&1; then
  log "budget '$BUDGET_NAME' exists — deleting then recreating"
  adp_rpc redpanda.api.adp.v1alpha1.BudgetService/DeleteBudget \
    "$(jq -nc --arg n "$BUDGET_NAME" '{name:$n}')" >/dev/null
fi

adp_rpc redpanda.api.adp.v1alpha1.BudgetService/CreateBudget "$BODY" >/dev/null
ok "budget '$BUDGET_NAME': \$$BUDGET_LIMIT_USD/day on agent '$AGENT_NAME' (warn at \$$BUDGET_WARN_USD)"

log "\`make spend\` shows usage against the limit."
