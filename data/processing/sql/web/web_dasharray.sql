-- web_dasharray.sql — [later-phase stub] Precompute QGIS's
-- array_foreach/string_to_array/nested-CASE dash-pattern expressions (see
-- processing/sql/road_marking_lane_divider.sql's customDash logic) into
-- literal numeric arrays for MapLibre's `line-dasharray` to read directly —
-- that expression logic isn't representable as a MapLibre style-spec
-- expression, so it has to be baked into an attribute at generation time
-- like everything else non-trivial in this migration.
--
-- Not yet implemented — see the migration plan's data-defined-properties
-- findings ("genuinely hard" complex dash-array expressions).

\i 'processing/sql/web/params_web.sql'
