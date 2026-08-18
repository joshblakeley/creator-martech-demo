-- Fit scoring. THE MODEL DOES NOT DO THIS ARITHMETIC.
--
-- Six measures at 1-10, weighted into an overall score out of 100, with
-- percentile normalisation.
--
-- Why it lives in SQL rather than in the Fit Scoring agent's prompt:
--   1. It is deterministic. Ask twice, get the same score — which is a better
--      answer than a temperature setting when someone asks whether the numbers
--      are stable.
--   2. It is explainable by construction — every dimension is a column the
--      agent can cite, not a number it has to justify after the fact.
--   3. The JavaScript MCP is not generally available, so computing this
--      agent-side was not an option anyway.
--
-- Weights add up to 1.00. Change them here and re-run `make db` — no prompt
-- needs editing.
--
-- WATCH THE ORDER. DROP VIEW takes the permissions on it too, so re-running
-- this file alone quietly leaves fit_sql unable to read the view, and the
-- scoring agent starts failing with "permission denied". Always follow a
-- change here with 03-roles.sql. `make db` does both in order, and
-- `make prove-grants` catches it if you forget.

BEGIN;

DROP VIEW IF EXISTS fit.creator_fit_scores;

CREATE VIEW fit.creator_fit_scores AS
WITH perf AS (
  SELECT
    cp.creator_id,
    SUM(cp.gmv_usd)                                        AS lifetime_gmv_usd,
    SUM(cp.spend_usd)                                      AS lifetime_spend_usd,
    SUM(cp.gmv_usd) / NULLIF(SUM(cp.spend_usd), 0)         AS roas,
    COUNT(*)                                               AS campaign_count,
    -- Share of this creator's past campaigns whose brand category matches
    -- the creator's own primary category: "do they actually work in this
    -- space, or did they take one cheque in it?"
    SUM(CASE WHEN b.category = c.primary_category THEN 1 ELSE 0 END)::numeric
      / NULLIF(COUNT(*), 0)                                AS on_category_share
  FROM campaign.campaign_performance cp
  JOIN creator.brands   b ON b.brand_id   = cp.brand_id
  JOIN creator.creators c ON c.creator_id = cp.creator_id
  GROUP BY cp.creator_id
),
raw AS (
  SELECT
    c.creator_id,
    c.handle,
    c.display_name,
    c.primary_category,
    c.follower_count,
    c.typical_post_rate_usd,
    c.brand_safety_score,
    -- Carried through so the restricted policy's row filter works on this
    -- server too. Policies attach per server, and a view missing this column
    -- returns zero rows rather than all of them.
    c.safety_tier,
    c.email,
    c.phone,
    COALESCE(p.roas, 0)               AS roas,
    COALESCE(p.on_category_share, 0)  AS on_category_share,
    COALESCE(p.lifetime_gmv_usd, 0)   AS lifetime_gmv_usd,
    COALESCE(p.campaign_count, 0)     AS campaign_count,
    c.avg_engagement_rate,
    c.audience_geo_share,
    (CURRENT_DATE - c.last_active_at) AS days_since_active,
    -- Follower tier. Two jobs:
    --
    --   1. It is the cohort that engagement and cost efficiency are
    --      percentile-ranked WITHIN (see dims below). Ranking engagement
    --      globally is wrong on the merits — a 3% rate at 20k followers
    --      and a 3% rate at 2M are not comparable numbers — and it also
    --      also misleads: very small creators carry inflated engagement, so a
    --      genuinely strong mid-size creator scores mid-table and "find someone
    --      like our best performer" returns someone who is not.
    --
    --   2. It gives the scout a named band to filter on, so "micro-influencer"
    --      becomes `follower_tier = 'micro'` rather than two magic numbers
    --      living in a prompt.
    CASE
      WHEN c.follower_count <  10000  THEN 'nano'
      WHEN c.follower_count < 100001  THEN 'micro'
      WHEN c.follower_count < 500000  THEN 'mid'
      ELSE 'macro'
    END AS follower_tier
  FROM creator.creators c
  LEFT JOIN perf p ON p.creator_id = c.creator_id
),
-- Percentile-rank each raw signal, then bucket into 1-10. width_bucket
-- returns 11 when the input is exactly 1.0 (the top-ranked row), so every
-- dimension is clamped with LEAST(10, ...).
dims AS (
  SELECT
    raw.*,
    LEAST(10, width_bucket(PERCENT_RANK() OVER (PARTITION BY follower_tier ORDER BY avg_engagement_rate), 0, 1, 10)) AS dim_engagement_quality,
    LEAST(10, width_bucket(PERCENT_RANK() OVER (PARTITION BY follower_tier ORDER BY roas),                0, 1, 10)) AS dim_cost_efficiency,
    LEAST(10, width_bucket(PERCENT_RANK() OVER (ORDER BY on_category_share),    0, 1, 10)) AS dim_category_affinity,
    LEAST(10, width_bucket(PERCENT_RANK() OVER (ORDER BY audience_geo_share),   0, 1, 10)) AS dim_audience_fit,
    -- brand_safety_score is already a 1-10 scale; use it directly rather
    -- than percentile-ranking it, so an absolute safety floor stays
    -- absolute rather than becoming relative to the cohort.
    brand_safety_score                                                                     AS dim_brand_safety,
    LEAST(10, width_bucket(PERCENT_RANK() OVER (ORDER BY days_since_active DESC), 0, 1, 10)) AS dim_recency
  FROM raw
),
weighted AS (
  SELECT
    dims.*,
    ( dim_engagement_quality * 0.25
    + dim_cost_efficiency    * 0.25
    + dim_category_affinity  * 0.20
    + dim_audience_fit       * 0.15
    + dim_brand_safety       * 0.10
    + dim_recency            * 0.05 ) AS weighted_1_10
  FROM dims
)
SELECT
  creator_id,
  handle,
  display_name,
  primary_category,
  follower_count,
  follower_tier,
  typical_post_rate_usd,
  email,
  phone,
  brand_safety_score,
  safety_tier,
  dim_engagement_quality,
  dim_cost_efficiency,
  dim_category_affinity,
  dim_audience_fit,
  dim_brand_safety,
  dim_recency,
  ROUND(weighted_1_10 * 10)::int                                          AS fit_score,
  ROUND(PERCENT_RANK() OVER (ORDER BY weighted_1_10) * 100)::int          AS fit_percentile,
  ROUND(roas, 2)                                                         AS roas,
  lifetime_gmv_usd,
  campaign_count
FROM weighted;

COMMENT ON VIEW fit.creator_fit_scores IS
  'Deterministic fit scoring: six dimensions 1-10, overall 1-100, percentile-normalised. Weights live in the view definition, not in any prompt.';

-- Monthly rollup, for questions the orchestrator answers without a specialist
-- ("what is our ROI this month versus last?"). It reads this through
-- campaign-sql and never touches the creator list.
DROP VIEW IF EXISTS campaign.monthly_rollup;

CREATE VIEW campaign.monthly_rollup AS
SELECT
  b.brand_id,
  b.brand_name,
  date_trunc('month', cp.posted_at)::date          AS month,
  COUNT(DISTINCT cp.creator_id)                    AS creators,
  SUM(cp.impressions)                              AS impressions,
  SUM(cp.clicks)                                   AS clicks,
  SUM(cp.conversions)                              AS conversions,
  SUM(cp.gmv_usd)                                  AS gmv_usd,
  SUM(cp.spend_usd)                                AS spend_usd,
  ROUND(SUM(cp.gmv_usd) / NULLIF(SUM(cp.spend_usd), 0), 2) AS roas,
  -- Figures inside the 24-48h settling window are marked provisional. Making
  -- that a column means the agent reports it as data rather than being told to
  -- remember a caveat.
  (MAX(cp.posted_at) > CURRENT_DATE - INTERVAL '2 days') AS provisional
FROM campaign.campaign_performance cp
JOIN creator.brands b ON b.brand_id = cp.brand_id
GROUP BY b.brand_id, b.brand_name, date_trunc('month', cp.posted_at);

-- Creator-level performance, for the orchestrator.
--
-- The monthly rollup groups by brand and month, so it cannot say which creator
-- drove the revenue. This view can, which is what "find creators like our best
-- performer" needs.
--
-- Deliberately narrow. It exposes identity plus performance and NOTHING else:
-- no post rate, no engagement, no audience, no contact details. So the
-- orchestrator can answer "who performed best" without gaining a path into
-- the creator base — the scoping story survives, and the Scout is still the
-- only route to creator attributes.
DROP VIEW IF EXISTS campaign.creator_performance;

CREATE VIEW campaign.creator_performance AS
SELECT
  c.creator_id,
  c.handle,
  c.display_name,
  b.brand_id,
  b.brand_name,
  COUNT(*)                                                  AS campaigns,
  SUM(cp.gmv_usd)                                           AS gmv_usd,
  SUM(cp.spend_usd)                                          AS spend_usd,
  ROUND(SUM(cp.gmv_usd) / NULLIF(SUM(cp.spend_usd), 0), 2)   AS roas,
  SUM(cp.conversions)                                        AS conversions,
  MAX(cp.posted_at)                                          AS last_campaign_at
FROM campaign.campaign_performance cp
JOIN creator.creators c ON c.creator_id = cp.creator_id
JOIN creator.brands   b ON b.brand_id   = cp.brand_id
GROUP BY c.creator_id, c.handle, c.display_name, b.brand_id, b.brand_name;

COMMENT ON VIEW campaign.creator_performance IS
  'Creator-level campaign performance for the orchestrator: identity + results only, deliberately no rate/engagement/audience/contact columns.';

COMMIT;
