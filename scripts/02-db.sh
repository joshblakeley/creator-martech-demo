#!/usr/bin/env bash
# Load schema, views, roles and seed data into Postgres, in order.
#
# ORDER MATTERS. 03-roles.sql must run AFTER 02-views.sql: DROP VIEW
# destroys the grants on the view, so applying roles first leaves fit_sql
# without SELECT on fit.creator_fit_scores and the fit-scoring subagent
# fails with "permission denied for view". `make prove-grants` is the check.

. "$(dirname "$0")/_lib.sh"

: "${PG_ADMIN_DSN:?set PG_ADMIN_DSN in env/secrets.env}"
: "${PG_CREATOR_PW:?set PG_CREATOR_PW in env/secrets.env}"
: "${PG_FIT_PW:?set PG_FIT_PW in env/secrets.env}"
: "${PG_CAMPAIGN_PW:?set PG_CAMPAIGN_PW in env/secrets.env}"

BULK="$ROOT/config/sql/07-seed-bulk.sql"
if [ ! -f "$BULK" ]; then
  log "generating bulk creators (committed artifact was missing)"
  python3 "$ROOT/scripts/gen-bulk-creators.py" > "$BULK"
fi

log "schema"
pg -f "$ROOT/config/sql/01-schema.sql" >/dev/null

log "views (fit scoring + campaign rollup)"
pg -f "$ROOT/config/sql/02-views.sql" >/dev/null

log "roles and grants (after views — see header)"
pg -v creator_pw="$PG_CREATOR_PW" \
   -v fit_pw="$PG_FIT_PW" \
   -v campaign_pw="$PG_CAMPAIGN_PW" \
   -f "$ROOT/config/sql/03-roles.sql" >/dev/null

log "brands"
pg -f "$ROOT/config/sql/04-seed-brands.sql" >/dev/null

log "hand-written creators"
pg -f "$ROOT/config/sql/05-seed-showcase.sql" >/dev/null

log "bulk creators (the haystack)"
pg -f "$BULK" >/dev/null

log "campaign history"
pg -f "$ROOT/config/sql/06-seed-performance.sql" >/dev/null

CREATORS="$(pg_scalar 'SELECT count(*) FROM creator.creators')"
SHOWCASE="$(pg_scalar "SELECT count(*) FROM creator.creators WHERE creator_id LIKE 'showcase-%'")"
PERF="$(pg_scalar 'SELECT count(*) FROM campaign.campaign_performance')"
SCORES="$(pg_scalar 'SELECT count(*) FROM fit.creator_fit_scores')"

ok "creators: $CREATORS ($SHOWCASE showcase) · campaigns: $PERF · scored: $SCORES"

# If the near-miss data drifts, nothing errors — the exclusions just stop being
# specific. Check it here.
BAD="$(pg -tAq <<'SQL'
SELECT count(*) FROM (
  SELECT creator_id,
    (primary_category = 'skincare')::int
  + (follower_count BETWEEN 10000 AND 100000)::int
  + (typical_post_rate_usd <= 5000)::int
  + (brand_safety_score >= 8)::int
  + (audience_geo_primary = 'US')::int AS gates_passed
  FROM creator.creators
  WHERE creator_id IN ('showcase-09','showcase-10','showcase-11','showcase-12')
) t WHERE gates_passed <> 4;
SQL
)"
if [ "$BAD" != "0" ]; then
  die "$BAD of the 4 near-miss creators do not fail exactly one rule. Fix config/sql/05-seed-showcase.sql."
fi
ok "near-miss invariant holds (each fails exactly one gate)"
