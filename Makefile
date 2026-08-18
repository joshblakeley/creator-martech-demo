.SHELLFLAGS := -eu -o pipefail -c
SHELL := /usr/bin/env bash

ENV ?= integration
export ENV

.DEFAULT_GOAL := help

help:
	@awk 'BEGIN{FS=":.*##"; printf "Usage: make <target> [ENV=integration|production]\n\nProvision:\n"} \
	     /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- provisioning ---------------------------------------------------------

up: secret db mcp agent budget ## Build everything
	@echo "✓ stack up in env=$$ENV — run 'make verify' then 'make smoke'"

preflight: ## Check the things that are slow to fix
	@bash scripts/00-preflight.sh

secret: ## Store the three database passwords as cluster secrets
	@bash scripts/01-secret.sh

db: ## Create the tables, views, logins and sample data
	@bash scripts/02-db.sh

mcp: secret ## Reconcile the three SQL MCP servers (and their data policies)
	@bash scripts/03-mcp.sh

diff: ## Show what applying the manifests would change, without applying
	@# `diff` exits non-zero when drift exists (the GitOps convention), so each
	@# call is allowed to fail without stopping the other.
	@. scripts/_lib.sh; require_token; \
	R=$$(mktemp -d); trap 'rm -rf $$R' EXIT; \
	for m in config/manifests/*-sql.yaml; do sed "s|__CONTRACTOR_EMAIL__|$$CONTRACTOR_EMAIL|g" $$m > $$R/$$(basename $$m); done; \
	echo "--- MCP servers ---"; rpai $$(rpai_cfg) mcp diff -f $$R || true; \
	echo "--- agent ---"; bash scripts/render-agent.sh > $$R/agent.yaml; \
	rpai $$(rpai_cfg) agent diff -f $$R/agent.yaml || true

agent: mcp ## Create the orchestrator and its two specialists
	@bash scripts/04-agent.sh

budget: agent ## Set a daily spend limit for the agent
	@bash scripts/06-budget.sh

down: ## Remove everything except the database contents
	@bash scripts/99-teardown.sh

# --- verification ---------------------------------------------------------

verify: prove-grants prove-nearmiss ## Check the database side is set up correctly
	@echo "✓ data layer verified"

prove-grants: ## Prove the three logins really are separate
	@. scripts/_lib.sh; \
	echo "each login should reach ONLY its own data:"; \
	fails=0; \
	probe() { \
	  printf "  %-34s" "$$1"; \
	  if out=$$(PGPASSWORD="$$3" psql "host=$$PG_HOST port=$${PG_PORT:-5432} dbname=$$PG_DATABASE user=$$2 sslmode=$${PG_SSLMODE:-require}" -tAq -c "$$4" 2>&1); then \
	    echo "OK ($$out rows)"; \
	  elif echo "$$out" | grep -qi "permission denied"; then \
	    echo "DENIED — $$(echo "$$out" | grep -i 'permission denied' | head -1 | cut -c1-52)"; \
	  else \
	    echo "ERROR (not a permission denial!) — $$(echo "$$out" | head -1 | cut -c1-44)"; \
	    fails=$$((fails+1)); \
	  fi; \
	}; \
	probe "creator_sql  -> creator base"  creator_sql  "$$PG_CREATOR_PW"  "SELECT count(*) FROM creator.creators"; \
	probe "creator_sql  -> scores view"   creator_sql  "$$PG_CREATOR_PW"  "SELECT count(*) FROM fit.creator_fit_scores"; \
	probe "fit_sql      -> scores view"   fit_sql      "$$PG_FIT_PW"      "SELECT count(*) FROM fit.creator_fit_scores"; \
	probe "fit_sql      -> creator base"  fit_sql      "$$PG_FIT_PW"      "SELECT count(*) FROM creator.creators"; \
	probe "campaign_sql -> rollup"        campaign_sql "$$PG_CAMPAIGN_PW" "SELECT count(*) FROM campaign.monthly_rollup"; \
	probe "campaign_sql -> creator base"  campaign_sql "$$PG_CAMPAIGN_PW" "SELECT count(*) FROM creator.creators"; \
	echo "  (expected: OK, DENIED, OK, DENIED, OK, DENIED)"; \
	if [ "$$fails" -gt 0 ]; then \
	  echo; \
	  echo "  ✗ $$fails probe(s) failed for a reason OTHER than permissions."; \
	  echo "    A connection error is NOT proof of isolation — it means nothing"; \
	  echo "    connected. Fix the connection before trusting this output."; \
	  echo "    Testing against plaintext Postgres? PG_SSLMODE=disable make prove-grants"; \
	  exit 1; \
	fi

prove-nearmiss: ## Show each near-miss creator failing exactly one rule
	@. scripts/_lib.sh; psql "$$PG_ADMIN_DSN" -q -c "\
	SELECT handle, \
	  (primary_category='skincare') AS cat, \
	  (follower_count BETWEEN 10000 AND 100000) AS band, \
	  (typical_post_rate_usd <= 5000) AS budget, \
	  (brand_safety_score >= 8) AS safety, \
	  (audience_geo_primary='US') AS geo, \
	  follower_count, typical_post_rate_usd AS rate, brand_safety_score AS sfy \
	FROM creator.creators \
	WHERE creator_id IN ('showcase-09','showcase-10','showcase-11','showcase-12') \
	ORDER BY creator_id;"

shortlist: ## The shortlist, straight from SQL
	@. scripts/_lib.sh; psql "$$PG_ADMIN_DSN" -q -c "\
	SELECT handle, follower_count, typical_post_rate_usd AS rate, \
	       brand_safety_score AS safety, ROUND(avg_engagement_rate*100,2) AS eng_pct \
	FROM creator.creators \
	WHERE primary_category='skincare' AND follower_count BETWEEN 10000 AND 100000 \
	  AND typical_post_rate_usd <= 5000 AND brand_safety_score >= 8 \
	  AND audience_geo_primary='US' \
	ORDER BY follower_count LIMIT 12;"

scores: ## Fit scores for the hand-written creators
	@. scripts/_lib.sh; psql "$$PG_ADMIN_DSN" -q -c "\
	SELECT handle, follower_tier AS tier, fit_score AS fit, fit_percentile AS pct, \
	       dim_engagement_quality AS eng, dim_cost_efficiency AS cost, \
	       dim_category_affinity AS catf, dim_audience_fit AS aud, \
	       dim_brand_safety AS safe, dim_recency AS rec \
	FROM fit.creator_fit_scores WHERE creator_id LIKE 'showcase-%' \
	ORDER BY fit_score DESC;"

top-performer: ## The brand's best-performing creator so far
	@. scripts/_lib.sh; psql "$$PG_ADMIN_DSN" -q -c "\
	SELECT c.handle, count(*) AS campaigns, sum(cp.gmv_usd) AS gmv, \
	       ROUND(sum(cp.gmv_usd)/sum(cp.spend_usd),2) AS roas \
	FROM campaign.campaign_performance cp JOIN creator.creators c USING (creator_id) \
	WHERE cp.brand_id='brand-lumen' GROUP BY c.handle ORDER BY gmv DESC LIMIT 5;"

determinism: ## Ask twice, check the scores are identical
	@. scripts/_lib.sh; \
	a=$$(psql "$$PG_ADMIN_DSN" -tAq -c "SELECT md5(string_agg(creator_id||':'||fit_score, ',' ORDER BY creator_id)) FROM fit.creator_fit_scores"); \
	b=$$(psql "$$PG_ADMIN_DSN" -tAq -c "SELECT md5(string_agg(creator_id||':'||fit_score, ',' ORDER BY creator_id)) FROM fit.creator_fit_scores"); \
	echo "  run 1: $$a"; echo "  run 2: $$b"; \
	[ "$$a" = "$$b" ] && echo "  ✓ identical" || { echo "  ✗ DIVERGED"; exit 1; }

# --- day to day ----------------------------------------------------------

status: ## Show what is currently running
	@. scripts/_lib.sh; \
	echo "ENV=$$ENV  CLUSTER=$$CLUSTER_ID"; \
	echo "--- MCP servers ---"; rpai $$(rpai_cfg) mcp list; \
	echo "--- agent ---";       rpai $$(rpai_cfg) agent get "$$AGENT_NAME"


agent-url: ## Print the agent URL
	@. scripts/_lib.sh; rpai $$(rpai_cfg) agent get "$$AGENT_NAME" -o json | jq -r '.managed.status.url'


ask: ## Ask a question. make ask Q="..." [AS=<config name>]
	@if [ -n "$(ACT)" ]; then \
	  echo "ACT= does not work. Identity headers are stripped from traffic arriving"; \
	  echo "from outside the cluster, so passing one runs the call as your own user"; \
	  echo "and a policy aimed at someone else appears to do nothing."; \
	  echo; \
	  echo "Identity comes from the credentials. Sign a second config in instead:"; \
	  echo "  RPAI_CONFIG=~/.rpai/contractor rpai auth login"; \
	  echo "  make ask AS=contractor Q=\"...\""; \
	  exit 1; \
	fi; \
	[ -n "$(Q)" ] || { echo 'usage: make ask Q="your question" [AS=<config name>]'; exit 1; }; \
	case "$(Q)" in *,000*|*",00"*) \
	  echo "WARNING: Q looks like it lost a '\$$' to make expansion (\"$(Q)\")."; \
	  echo "         make eats \$$5 as an empty variable — write amounts as '5000 USD'."; ;; esac; \
	. scripts/_lib.sh; \
	echo "→ identity: $$(rpai_identity)"; \
	rpai $$(rpai_cfg) agent a2a send "$$AGENT_NAME" "$(Q)"

prerun: ## Run the example questions ahead of time so the answers are ready
	@bash scripts/prerun.sh

smoke: ## Ask the shortlist question end to end
	@$(MAKE) --no-print-directory ask \
	  Q="Find 5 skincare micro-influencers for Lumen Skincare with a rate under 5000 USD per post. Show which rule each creator passed and why the near misses were excluded."

spend: ## Spend so far against the limit
	@. scripts/_lib.sh; require_token; \
	adp_rpc redpanda.api.adp.v1alpha1.BudgetService/GetBudget "$$(jq -nc --arg n "$$BUDGET_NAME" '{name:$$n}')" \
	  | jq -r '.budget | "limit: $$\(.limitMicrocents|tonumber/100000000)  spent: $$\(((.currentSpendMicrocents//"0")|tonumber)/100000000)  resets: \(.periodResetsAt // "n/a")"'

stop-agent: ## Pause the agent
	@. scripts/_lib.sh; rpai $$(rpai_cfg) agent stop "$$AGENT_NAME"


start-agent: ## Resume the agent
	@. scripts/_lib.sh; rpai $$(rpai_cfg) agent start "$$AGENT_NAME"


# --- showing the policy fail rather than leak ----------------------------

break-schema: ## Rename the email column, to show the policy refuse rather than leak
	@. scripts/_lib.sh; \
	psql "$$PG_ADMIN_DSN" -v ON_ERROR_STOP=1 -q -c "ALTER TABLE creator.creators RENAME COLUMN email TO contact_email;"; \
	echo "✗ creator.creators.email renamed to contact_email."; \
	echo; \
	echo "  Ask the CONTRACTOR identity for creator contact details now:"; \
	echo "    make ask ACT=\$$CONTRACTOR_EMAIL Q=\"List skincare micro creators with their contact details.\""; \
	echo; \
	echo "  The scout queries the TABLE, so its response now carries contact_email."; \
	echo "  The policy selector \$$.records.email matches nothing, and because"; \
	echo "  absence_safe is false the gateway FAILS CLOSED rather than passing the"; \
	echo "  address through under a new name."; \
	echo; \
	echo "  Note: fit.creator_fit_scores still emits a column named 'email' —"; \
	echo "  Postgres propagates a column rename into a view by attribute number,"; \
	echo "  so the view's output name is unchanged and the fit path still masks"; \
	echo "  correctly — the server whose shape actually changed is the one"; \
	echo "  that refuses."; \
	echo; \
	echo "  Restore with: make fix-schema"

fix-schema: ## Put the email column back
	@. scripts/_lib.sh; \
	psql "$$PG_ADMIN_DSN" -v ON_ERROR_STOP=1 -q -c "ALTER TABLE creator.creators RENAME COLUMN contact_email TO email;"; \
	echo "✓ column restored"

db-drop: ## Delete the sample database contents
	@. scripts/_lib.sh; \
	psql "$$PG_ADMIN_DSN" -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS creator, fit, campaign CASCADE;"; \
	echo "✓ schemas dropped"

.PHONY: help up preflight secret db mcp diff agent budget down verify prerun \
        prove-grants prove-nearmiss shortlist scores top-performer determinism \
        status agent-url ask smoke spend stop-agent start-agent \
        break-schema fix-schema db-drop
