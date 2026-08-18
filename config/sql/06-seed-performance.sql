-- Campaign history for the showcase creators.
--
-- Expanded deterministically from a per-creator parameter table rather
-- than written out row by row: the intent (who is the top performer, who
-- is mediocre, who is off-category) stays legible, and the row count stays
-- reviewable.
--
-- showcase-01 (@thequietroutine) is the designated INCUMBENT TOP
-- PERFORMER. The Scout->Fit lookalike question ("recommend and rank new
-- creators like our top performer") depends on it being unambiguously
-- best: most campaigns, highest ROAS, fully on-category. Keep it that way
-- if you edit this file.

BEGIN;

DELETE FROM campaign.campaign_performance WHERE campaign_id LIKE 'showcase-camp-%';

WITH params(creator_id, brand_id, n_campaigns, base_spend, roas_target) AS (
  VALUES
    -- The incumbent: deep history, on-category, best return.
    ('showcase-01', 'brand-lumen',   6, 3200.00, 6.10),
    -- Strong-but-not-best cohort.
    ('showcase-02', 'brand-lumen',   4, 2400.00, 4.80),
    ('showcase-03', 'brand-lumen',   4, 4600.00, 4.20),
    ('showcase-04', 'brand-lumen',   3, 1800.00, 5.30),
    ('showcase-05', 'brand-verdant', 3, 3900.00, 3.40),
    ('showcase-06', 'brand-lumen',   2, 1500.00, 4.60),
    ('showcase-07', 'brand-lumen',   3, 4850.00, 2.90),
    ('showcase-08', 'brand-lumen',   3, 2100.00, 5.05),
    -- Near-misses still carry history: an excluded creator with a good
    -- track record makes the exclusion a real trade-off rather than a filter
    -- discarding bad data.
    --
    -- Campaign counts here are held at 3 deliberately. Both creators carry
    -- a higher per-post rate than the incumbent, so at 4-5 campaigns their
    -- lifetime GMV overtakes showcase-01 and "who is our top performer?"
    -- stops having one answer (the incumbent still led on ROAS and campaign
    -- count, but not GMV). Three keeps showcase-01 ahead on all three
    -- measures, so "find someone like our best performer" has one answer.
    ('showcase-09', 'brand-lumen',   3, 4700.00, 5.70),
    ('showcase-10', 'brand-lumen',   3, 5400.00, 5.20),
    ('showcase-11', 'brand-lumen',   2, 2900.00, 3.10),
    ('showcase-12', 'brand-lumen',   4, 3600.00, 4.90),
    ('showcase-13', 'brand-lumen',   3, 2700.00, 4.10),
    -- Off-category history on purpose: lowers dim_category_affinity, so one
    -- measure moves independently of the others.
    ('showcase-14', 'brand-tenor',   3, 3300.00, 3.80)
)
INSERT INTO campaign.campaign_performance
  (campaign_id, creator_id, brand_id, posted_at,
   impressions, clicks, conversions, gmv_usd, spend_usd)
SELECT
  'showcase-camp-' || p.creator_id || '-' || g.i,
  p.creator_id,
  p.brand_id,
  -- Most recent campaign lands 5 days ago, then back at ~monthly
  -- intervals. Keeps `monthly_rollup` populated across several months so
  -- the month-over-month ROI question has something to compare.
  (CURRENT_DATE - 5 - (g.i - 1) * 29)::date,
  (p.base_spend * 340)::bigint,
  (p.base_spend * 340 * 0.021)::bigint,
  (p.base_spend * 340 * 0.021 * 0.043)::bigint,
  -- Slight deterministic drift per campaign so ROAS is not suspiciously
  -- identical across a creator's history.
  ROUND(p.base_spend * (p.roas_target + ((g.i % 3) - 1) * 0.18), 2),
  p.base_spend
FROM params p
CROSS JOIN generate_series(1, 6) AS g(i)
WHERE g.i <= p.n_campaigns;

COMMIT;
