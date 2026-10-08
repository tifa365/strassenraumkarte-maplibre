-- web_label_visibility.sql — viewport-dependent QGIS label expressions as
-- deterministic per-feature zoom thresholds for MapLibre.

-- QGIS label_waterway Size expression:
--   if(
--     $length < 250 OR
--     (@map_scale > 6000 AND waterway NOT IN ('river', 'canal')) OR
--     (@map_scale > 12000 AND waterway != 'river'),
--     0, 10
--   )
--
-- Scales are converted to zoom with the renderer's real scale at z16
-- (:qgis_scale_at_z16, see params_web.sql).  A NULL threshold
-- means the QGIS size is always zero because the line is shorter than 250
-- projected map units.  Strict scale comparisons become label_min_zoom <= z.
\i 'processing/sql/web/params_web.sql'

ALTER TABLE label_waterway
    ADD COLUMN IF NOT EXISTS label_min_zoom real;

UPDATE label_waterway
SET label_min_zoom = CASE
    WHEN ST_Length(geom) < 250 THEN NULL
    WHEN waterway = 'river' THEN 0
    WHEN waterway = 'canal' THEN 16 + ln(:qgis_scale_at_z16::double precision / 12000.0) / ln(2.0)
    ELSE 16 + ln(:qgis_scale_at_z16::double precision / 6000.0) / ln(2.0)
END;
