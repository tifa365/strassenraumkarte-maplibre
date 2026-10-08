-- web_road_marking_symbols.sql — materialize QGIS MarkerLine symbols which
-- MapLibre cannot express natively.
--
-- sharks_teeth is a QGIS MarkerLine containing a SimpleMarker triangle.  The
-- QGIS project defines (all values are ground metres before metres()):
--
--   marker size       = dasharray[0]
--   marker interval   = sum(dasharray)
--   along-line offset = dasharray[1]
--   marker angle      = 180 degrees + the line angle averaged over 4 map units
--   marker offset     = (0, -0.25 * dasharray[0]), rotated with the marker
--
-- QGIS's normalized triangle is (-1,1), (1,1), (0,-1), scaled by
-- marker-size / 2.  In map coordinates the transform makes the tip point to
-- the right of the digitized line. QGIS's 4-map-unit average-angle setting is
-- a full window, so it samples 2 map units before and after each marker
-- (clamped at open-line ends), and does not place
-- a marker exactly at the line end. The CTEs below intentionally preserve all
-- of those details instead of approximating the result with a MapLibre icon.

\i 'processing/sql/web/params_web.sql'

DROP TABLE IF EXISTS road_marking_sharks_teeth;

CREATE TABLE road_marking_sharks_teeth AS
WITH parsed AS (
    SELECT
        rm.source,
        rm.osm_type,
        rm.osm_id,
        COALESCE(NULLIF(rm.colour, ''), 'white') AS colour,
        COALESCE(rm.layer, 0) AS layer,
        -- ST_Dump uses an empty path for an atomic LineString.
        COALESCE(dump.path[1], 1)::integer AS part_index,
        dump.geom::geometry(LineString, 3857) AS line_geom,
        string_to_array(rm.dasharray, ';')::double precision[] AS dash_values
    FROM road_marking_way rm
    CROSS JOIN LATERAL ST_Dump(rm.geom) AS dump
    WHERE rm.stroke = 'sharks_teeth'
      AND rm.geom IS NOT NULL
      AND NOT ST_IsEmpty(rm.geom)
      AND rm.dasharray ~ '^([0-9]+(?:\.[0-9]+)?;)+[0-9]+(?:\.[0-9]+)?$'
),
inputs AS (
    SELECT
        parsed.*,
        dash_values[1] AS marker_size_m,
        dash_values[2] AS offset_m,
        (
            SELECT sum(value)
            FROM unnest(dash_values) AS values_(value)
        ) AS interval_m,
        ST_Length(line_geom) AS line_length
    FROM parsed
    WHERE cardinality(dash_values) >= 2
      AND dash_values[1] > 0
      AND dash_values[2] >= 0
),
valid_inputs AS (
    SELECT
        inputs.*,
        metres(marker_size_m) AS marker_size,
        metres(offset_m) AS marker_offset,
        metres(interval_m) AS marker_interval
    FROM inputs
    WHERE interval_m > 0
      AND line_length > metres(offset_m)
),
markers AS (
    SELECT
        inp.*,
        marker_index,
        marker_offset + marker_index * marker_interval AS distance_along,
        ST_LineInterpolatePoint(
            line_geom,
            (marker_offset + marker_index * marker_interval) / line_length
        )::geometry(Point, 3857) AS marker_point
    FROM valid_inputs inp
    CROSS JOIN LATERAL generate_series(
        0,
        floor(
            (line_length - marker_offset - 1e-9) / marker_interval
        )::integer
    ) AS marker_index
),
angle_points AS (
    SELECT
        marker.*,
        4.0::double precision AS average_angle_map_units,
        ST_LineInterpolatePoint(
            line_geom,
            GREATEST(0.0, distance_along - 2.0) / line_length
        )::geometry(Point, 3857) AS angle_start,
        ST_LineInterpolatePoint(
            line_geom,
            LEAST(line_length, distance_along + 2.0) / line_length
        )::geometry(Point, 3857) AS angle_end
    FROM markers marker
),
oriented AS (
    SELECT
        angle_points.*,
        (ST_X(angle_end) - ST_X(angle_start))
            / ST_Distance(angle_start, angle_end) AS tangent_x,
        (ST_Y(angle_end) - ST_Y(angle_start))
            / ST_Distance(angle_start, angle_end) AS tangent_y
    FROM angle_points
    WHERE ST_Distance(angle_start, angle_end) > 0
),
vertices AS (
    SELECT
        oriented.*,
        marker_size / 2.0 AS half_size,
        -- right normal of the digitized segment
        tangent_y AS right_x,
        -tangent_x AS right_y,
        ST_X(marker_point) + tangent_y * marker_size * 0.25 AS center_x,
        ST_Y(marker_point) - tangent_x * marker_size * 0.25 AS center_y
    FROM oriented
),
triangles AS (
    SELECT
        vertices.*,
        ST_SetSRID(
            ST_MakePoint(
                center_x + tangent_x * half_size - right_x * half_size,
                center_y + tangent_y * half_size - right_y * half_size
            ),
            3857
        ) AS base_1,
        ST_SetSRID(
            ST_MakePoint(
                center_x - tangent_x * half_size - right_x * half_size,
                center_y - tangent_y * half_size - right_y * half_size
            ),
            3857
        ) AS base_2,
        ST_SetSRID(
            ST_MakePoint(
                center_x + right_x * half_size,
                center_y + right_y * half_size
            ),
            3857
        ) AS tip
    FROM vertices
)
SELECT
    row_number() OVER (
        ORDER BY source, osm_type, osm_id, part_index, marker_index
    )::bigint AS tooth_id,
    source,
    osm_type,
    osm_id,
    colour,
    layer,
    part_index,
    marker_index,
    average_angle_map_units::real AS average_angle_map_units,
    marker_size_m::real AS marker_size_m,
    interval_m::real AS interval_m,
    offset_m::real AS offset_m,
    distance_along,
    ST_MakePolygon(
        ST_MakeLine(ARRAY[base_1, base_2, tip, base_1])
    )::geometry(Polygon, 3857) AS geom
FROM triangles;

ALTER TABLE road_marking_sharks_teeth
    ADD PRIMARY KEY (tooth_id);

CREATE INDEX road_marking_sharks_teeth_geom_idx
    ON road_marking_sharks_teeth USING gist (geom);

ANALYZE road_marking_sharks_teeth;
