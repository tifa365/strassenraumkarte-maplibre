-- web_label_dedup.sql — Deduplicate place labels between place_node and
-- place_polygon (a settlement can be tagged in OSM as both a node and a
-- closed way with the same place=*/name=*, e.g. a town centre point plus its
-- administrative boundary). In the QGIS style both are labeled at the same
-- priority (7); QGIS's collision engine silently picks a winner. For the
-- MapLibre port we need a deterministic choice made once in SQL, not left to
-- a different (and differently-behaving) client-side label engine.
--
-- Rule: prefer the polygon representation (a settlement boundary's centroid
-- is generally a more stable/representative label anchor than an
-- independently-placed node) — suppress the node when a matching polygon
-- exists within the search radius. See docs/MAPLIBRE_FEASIBILITY.md "the one
-- real cross-engine risk" for the background.
--
-- Depends on: place_node, place_polygon (osm_import.lua)

\i 'processing/sql/web/params_web.sql'

ALTER TABLE place_node ADD COLUMN IF NOT EXISTS label_suppressed boolean;
ALTER TABLE place_polygon ADD COLUMN IF NOT EXISTS label_min_zoom real;

UPDATE place_node
SET label_suppressed = EXISTS (
    SELECT 1
    FROM place_polygon pp
    WHERE pp.place IS NOT DISTINCT FROM place_node.place
      AND pp.name IS NOT DISTINCT FROM place_node.name
      AND place_node.name IS NOT NULL
      AND ST_DWithin(
          place_node.geom,
          ST_Centroid(pp.geom),
          metres(:'place_dedup_radius_m'::double precision)
      )
);

-- QGIS's smallest polygon-label band also requires
--     $area / @map_scale > 0.75
-- MapLibre has no @map_scale variable, so solve that inequality once for the
-- zoom at which the polygon becomes eligible.  The project's established
-- scale mapping is the renderer's real one (:qgis_scale_at_z16 at z16, halving
-- per zoom level; see params_web.sql).
UPDATE place_polygon
SET label_min_zoom = CASE
    WHEN geom IS NULL OR ST_IsEmpty(geom) OR ST_Area(geom) <= 0 THEN NULL
    ELSE (
        16.0
        + ln((:qgis_scale_at_z16::double precision * 0.75) / ST_Area(geom)) / ln(2.0)
    )::real
END;
