-- params_web.sql — psql variables for the Web/MapLibre attribute-derivation
-- pass (data/processing/sql/web/). Include at the start of each web_*.sql
-- script:
--   \i 'processing/sql/web/params_web.sql'
-- Same conventions as processing/sql/params/params.sql: distances are ground
-- metres, converted via metres() where used in geometric operations.
--
-- See docs/MAPLIBRE_FEASIBILITY.md and the active migration plan for why
-- each of these exists.


-- =============================================================================
-- 1) LABEL DEDUP (web_label_dedup.sql)
-- =============================================================================

-- Search radius for matching a place_node to a place_polygon representing
-- the same real-world settlement (QGIS's collision engine silently picks a
-- winner between the two at render time; we dedupe deterministically in SQL
-- instead — see docs/MAPLIBRE_FEASIBILITY.md "the one real cross-engine
-- risk").
\set place_dedup_radius_m 200.0


-- QGIS map scale (denominator) at tile zoom 16 as the renderer computes it:
-- 156543.034 m/px / 2^16 * 96 dpi / 0.0254 m/in. Scale-based QGIS label rules
-- are converted to zoom thresholds with it. Keep in sync with
-- scripts/qgis_scale.py (checked by scripts/audit_maplibre_parity.py).
\set qgis_scale_at_z16 9027.9955


-- =============================================================================
-- 2) TEXTURE ROTATION BUCKETS (web_texture_rotation.sql)
-- =============================================================================

-- Angle step for pre-rotated texture sprite variants. QGIS rotates RasterFill
-- textures continuously via "direction"/"direction"+45; MapLibre has no
-- fill-pattern-rotate, so we bucket to the nearest step and pick a matching
-- pre-rotated sprite instead. 15° keeps the sprite count small (24/texture)
-- while staying visually indistinguishable from continuous rotation for
-- these non-photographic, low-frequency patterns — see Phase 3 QA note in
-- the migration plan if this ever needs tightening to 10/7.5°.
\set texture_rotation_step_deg 15.0


-- =============================================================================
-- 3) DASHARRAY LITERALIZATION (web_dasharray.sql)
-- =============================================================================

-- Placeholder section — no tunables yet. web_dasharray.sql precomputes the
-- QGIS array_foreach/string_to_array dash-pattern expressions (see
-- data/processing/sql/road_marking_lane_divider.sql) into literal numeric
-- arrays MapLibre's line-dasharray can read directly.


-- =============================================================================
-- 4) NON-NATIVE ROAD-MARKING SYMBOL GEOMETRY (web_road_marking_symbols.sql)
-- =============================================================================

-- No tunables: the sharks-teeth size, interval, initial offset, marker
-- offset, normalized triangle, and rotation are copied literally from the
-- QGIS MarkerLine. Keeping them out of configurable parameters makes an
-- accidental visual "improvement" show up as a parity change.
