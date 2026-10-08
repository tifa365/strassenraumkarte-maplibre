-- web_separation_markers.sql — materialize QGIS separation MarkerLine/HashLine
-- rules as polygons. Only the four explicit QGIS rule categories are emitted;
-- other separation values deliberately remain unrendered.

DROP TABLE IF EXISTS separation_markers;

CREATE TABLE separation_markers AS
WITH parts AS (
    SELECT
        separation.separation,
        COALESCE(separation.layer, 0) AS layer,
        rule.kind,
        COALESCE(dump.path[1], 1)::integer AS part_index,
        dump.geom::geometry(LineString, 3857) AS line_geom,
        ST_Length(dump.geom) AS line_length
    FROM separation
    CROSS JOIN LATERAL (VALUES
        ('bollard'::text), ('flex_post'), ('bump'), ('vertical_panel')
    ) AS rule(kind)
    CROSS JOIN LATERAL ST_Dump(separation.geom) AS dump
    WHERE separation.separation LIKE '%' || rule.kind || '%'
      AND dump.geom IS NOT NULL
      AND NOT ST_IsEmpty(dump.geom)
      AND ST_Length(dump.geom) > 1.0
),
markers AS (
    SELECT
        parts.*,
        marker_index,
        1.0 + marker_index * 2.0 AS distance_along,
        ST_LineInterpolatePoint(
            line_geom, (1.0 + marker_index * 2.0) / line_length
        )::geometry(Point, 3857) AS marker_point
    FROM parts
    CROSS JOIN LATERAL generate_series(
        0, floor((line_length - 1.0 - 1e-9) / 2.0)::integer
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
shapes AS (
    SELECT
        oriented.*,
        CASE kind
            WHEN 'bollard' THEN ST_Buffer(marker_point, 0.175, 'quad_segs=8')
            WHEN 'flex_post' THEN ST_Buffer(marker_point, 0.15, 'quad_segs=8')
            WHEN 'bump' THEN ST_MakePolygon(ST_MakeLine(ARRAY[
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) - tangent_x * 0.125 + tangent_y * 0.5, ST_Y(marker_point) - tangent_y * 0.125 - tangent_x * 0.5), 3857),
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) + tangent_x * 0.125 + tangent_y * 0.5, ST_Y(marker_point) + tangent_y * 0.125 - tangent_x * 0.5), 3857),
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) + tangent_x * 0.125 - tangent_y * 0.5, ST_Y(marker_point) + tangent_y * 0.125 + tangent_x * 0.5), 3857),
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) - tangent_x * 0.125 - tangent_y * 0.5, ST_Y(marker_point) - tangent_y * 0.125 + tangent_x * 0.5), 3857),
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) - tangent_x * 0.125 + tangent_y * 0.5, ST_Y(marker_point) - tangent_y * 0.125 - tangent_x * 0.5), 3857)
            ]))
            ELSE ST_MakePolygon(ST_MakeLine(ARRAY[
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) - tangent_x * 0.0875 + tangent_y * 0.175, ST_Y(marker_point) - tangent_y * 0.0875 - tangent_x * 0.175), 3857),
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) + tangent_x * 0.2625 + tangent_y * 0.175, ST_Y(marker_point) + tangent_y * 0.2625 - tangent_x * 0.175), 3857),
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) + tangent_x * 0.2625 - tangent_y * 0.175, ST_Y(marker_point) + tangent_y * 0.2625 + tangent_x * 0.175), 3857),
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) - tangent_x * 0.0875 - tangent_y * 0.175, ST_Y(marker_point) - tangent_y * 0.0875 + tangent_x * 0.175), 3857),
                ST_SetSRID(ST_MakePoint(ST_X(marker_point) - tangent_x * 0.0875 + tangent_y * 0.175, ST_Y(marker_point) - tangent_y * 0.0875 - tangent_x * 0.175), 3857)
            ]))
        END::geometry(Polygon, 3857) AS geom
    FROM oriented
)
SELECT
    row_number() OVER (ORDER BY layer, kind, part_index, marker_index)::bigint AS marker_id,
    layer, kind, part_index, marker_index, distance_along,
    CASE kind WHEN 'flex_post' THEN '#a0a0a0' ELSE '#505050' END AS colour,
    '#ededed'::text AS outline_colour,
    geom
FROM shapes;

ALTER TABLE separation_markers ADD PRIMARY KEY (marker_id);
CREATE INDEX separation_markers_geom_idx ON separation_markers USING gist (geom);
ANALYZE separation_markers;
