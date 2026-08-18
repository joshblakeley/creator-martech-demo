-- Fictional brands. Invented for this demo — deliberately NOT any real
-- customer of any real platform. If someone asks to swap in a real brand
-- name for a live demo, that is a data-handling conversation to have
-- first, not a find-and-replace.

BEGIN;

INSERT INTO creator.brands (brand_id, brand_name, category, target_geo, target_age) VALUES
  ('brand-lumen',    'Lumen Skincare',      'skincare',   'US', '25-34'),
  ('brand-verdant',  'Verdant Wellness',    'wellness',   'US', '25-34'),
  ('brand-tenor',    'Tenor Audio',         'tech',       'US', '18-24'),
  ('brand-atlas',    'Atlas Outdoor',       'outdoor',    'US', '35-44'),
  ('brand-saffron',  'Saffron Kitchen',     'food',       'US', '25-34'),
  ('brand-north',    'Northbound Denim',    'fashion',    'US', '18-24')
ON CONFLICT (brand_id) DO UPDATE
  SET brand_name = EXCLUDED.brand_name,
      category   = EXCLUDED.category,
      target_geo = EXCLUDED.target_geo,
      target_age = EXCLUDED.target_age;

COMMIT;
