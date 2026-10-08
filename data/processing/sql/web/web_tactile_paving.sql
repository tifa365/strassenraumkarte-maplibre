-- web_tactile_paving.sql — materialize QGIS's tactile-paving MarkerLine.
--
-- The source line has a 1 m MarkerLine interval, starts 0.5 m along each
-- part, and shifts the marker 0.5 m to the right of the digitized line. Each
-- marker is QGIS's 1 m red ``cross2`` SimpleMarker with a 0.12 m off-white
-- outline. MapLibre cannot place ground-unit markers along a line, so emit the
-- two crossed bars as literal polygons instead.

DROP TABLE IF EXISTS tactile_paving_markers;

CREATE TABLE tactile_paving_markers AS
WITH parts AS (
    SELECT
        COALESCE(paving.layer, 0) AS layer,
        COALESCE(dump.path[1], 1)::integer AS part_index,
        dump.geom::geometry(LineString, 3857) AS line_geom,
        ST_Length(dump.geom) AS line_length
    FROM tactile_paving paving
    CROSS JOIN LATERAL ST_Dump(paving.geom) AS dump
    WHERE dump.geom IS NOT NULL
      AND NOT ST_IsEmpty(dump.geom)
      AND ST_Length(dump.geom) > 0.5
),
markers AS (
    SELECT
        parts.*,
        marker_index,
        0.5 + marker_index AS distance_along,
        ST_LineInterpolatePoint(
            line_geom, (0.5 + marker_index) / line_length
        )::geometry(Point, 3857) AS marker_point
    FROM parts
    CROSS JOIN LATERAL generate_series(
        0, floor((line_length - 0.5 - 1e-9) / 1.0)::integer
    ) AS marker_index
),
oriented AS (
    SELECT
        markers.*,
        (ST_X(angle_end) - ST_X(angle_start)) / ST_Distance(angle_start, angle_end)
            AS tangent_x,
        (ST_Y(angle_end) - ST_Y(angle_start)) / ST_Distance(angle_start, angle_end)
            AS tangent_y
    FROM markers
    CROSS JOIN LATERAL (
        SELECT
            ST_LineInterpolatePoint(
                line_geom, GREATEST(0.0, distance_along - 2.0) / line_length
            )::geometry(Point, 3857) AS angle_start,
            ST_LineInterpolatePoint(
                line_geom, LEAST(line_length, distance_along + 2.0) / line_length
            )::geometry(Point, 3857) AS angle_end
    ) AS angle
    WHERE ST_Distance(angle_start, angle_end) > 0
),
bars AS (
    SELECT
        oriented.*,
        ST_SetSRID(ST_MakePoint(
            ST_X(marker_point) + tangent_y * 0.5,
            ST_Y(marker_point) - tangent_x * 0.5
        ), 3857) AS center,
        (tangent_x + tangent_y) / sqrt(2.0) AS diagonal_1_x,
        (tangent_y - tangent_x) / sqrt(2.0) AS diagonal_1_y,
        (tangent_x - tangent_y) / sqrt(2.0) AS diagonal_2_x,
        (tangent_y + tangent_x) / sqrt(2.0) AS diagonal_2_y
    FROM oriented
),
crosses AS (
    SELECT
        bars.*,
        ST_UnaryUnion(ST_Collect(
            ST_Buffer(ST_MakeLine(
                ST_SetSRID(ST_MakePoint(
                    ST_X(center) - diagonal_1_x * 0.5,
                    ST_Y(center) - diagonal_1_y * 0.5
                ), 3857),
                ST_SetSRID(ST_MakePoint(
                    ST_X(center) + diagonal_1_x * 0.5,
                    ST_Y(center) + diagonal_1_y * 0.5
                ), 3857)
            ), 0.06, 'endcap=flat join=mitre'),
            ST_Buffer(ST_MakeLine(
                ST_SetSRID(ST_MakePoint(
                    ST_X(center) - diagonal_2_x * 0.5,
                    ST_Y(center) - diagonal_2_y * 0.5
                ), 3857),
                ST_SetSRID(ST_MakePoint(
                    ST_X(center) + diagonal_2_x * 0.5,
                    ST_Y(center) + diagonal_2_y * 0.5
                ), 3857)
            ), 0.06, 'endcap=flat join=mitre')
        ))::geometry(Polygon, 3857) AS geom
    FROM bars
)
SELECT
    row_number() OVER (ORDER BY layer, part_index, marker_index)::bigint AS marker_id,
    layer,
    part_index,
    marker_index,
    distance_along,
    geom
FROM crosses;

ALTER TABLE tactile_paving_markers ADD PRIMARY KEY (marker_id);
CREATE INDEX tactile_paving_markers_geom_idx
    ON tactile_paving_markers USING gist (geom);
ANALYZE tactile_paving_markers;
