-- Creator-matchmaking demo schema.
--
-- Three tables plus a scores view (02-views.sql). The tables live in
-- schema `creator`; the scores view in schema `fit`; campaign rollups in
-- schema `campaign`. The split is not cosmetic — one schema per MCP server,
-- with a matching database permission in 03-roles.sql.

BEGIN;

CREATE SCHEMA IF NOT EXISTS creator;
CREATE SCHEMA IF NOT EXISTS fit;
CREATE SCHEMA IF NOT EXISTS campaign;

DROP TABLE IF EXISTS campaign.campaign_performance CASCADE;
DROP TABLE IF EXISTS creator.creators CASCADE;
DROP TABLE IF EXISTS creator.brands CASCADE;

-- Fictional brands. Invented for this demo — not real companies.
CREATE TABLE creator.brands (
  brand_id      text PRIMARY KEY,
  brand_name    text NOT NULL,
  category      text NOT NULL,
  target_geo    text NOT NULL,
  target_age    text NOT NULL
);

CREATE TABLE creator.creators (
  creator_id            text PRIMARY KEY,
  handle                text NOT NULL UNIQUE,
  display_name          text NOT NULL,
  primary_category      text NOT NULL,
  follower_count        integer NOT NULL,
  -- Stored as a fraction: 0.0342 = 3.42%.
  avg_engagement_rate   numeric(6,4) NOT NULL,
  -- The SAME number pre-multiplied for display. Not redundancy — it removes
  -- an arithmetic step from the model.
  --
  -- Converting a fraction to a percentage is arithmetic, and the model does not
  -- reliably get it right. Same principle as computing the scores in SQL: give
  -- it the number to say, never a sum to do.
  engagement_pct        numeric(5,2) GENERATED ALWAYS AS (avg_engagement_rate * 100) STORED,
  audience_geo_primary  text NOT NULL,
  -- Share of audience in audience_geo_primary. 0.812 = 81.2%.
  audience_geo_share    numeric(4,3) NOT NULL,
  audience_age_band     text NOT NULL,
  -- 1-10. The scout's safety filter reads this directly.
  brand_safety_score    integer NOT NULL CHECK (brand_safety_score BETWEEN 1 AND 10),
  -- The same threshold as a text flag, because a row filter cannot compare
  -- numbers. The SQL server sends every value as a string ("9", not 9), so a
  -- filter written as `>= 8` matches nothing — and since filters fail closed,
  -- that drops every row. Written as `>= "8"` it sorts alphabetically, so "10"
  -- lands below "8" and the safest creators get excluded. Both verified.
  --
  -- A text flag compared with `==` has neither problem.
  safety_tier           text GENERATED ALWAYS AS (
                          CASE WHEN brand_safety_score >= 8 THEN 'approved' ELSE 'restricted' END
                        ) STORED,
  typical_post_rate_usd numeric(10,2) NOT NULL,
  -- Personal details. The restricted policy masks these, and the rule on email
  -- is set to fail rather than pass anything through if the column is renamed —
  -- which is what `make break-schema` demonstrates.
  email                 text NOT NULL,
  phone                 text,
  bio                   text,
  last_active_at        date NOT NULL
);

CREATE INDEX ON creator.creators (primary_category);
CREATE INDEX ON creator.creators (follower_count);

CREATE TABLE campaign.campaign_performance (
  campaign_id  text NOT NULL,
  creator_id   text NOT NULL REFERENCES creator.creators(creator_id) ON DELETE CASCADE,
  brand_id     text NOT NULL REFERENCES creator.brands(brand_id) ON DELETE CASCADE,
  posted_at    date NOT NULL,
  impressions  bigint NOT NULL,
  clicks       bigint NOT NULL,
  conversions  bigint NOT NULL,
  gmv_usd      numeric(12,2) NOT NULL,
  spend_usd    numeric(12,2) NOT NULL,
  PRIMARY KEY (campaign_id, creator_id)
);

CREATE INDEX ON campaign.campaign_performance (creator_id);
CREATE INDEX ON campaign.campaign_performance (posted_at);

COMMIT;
