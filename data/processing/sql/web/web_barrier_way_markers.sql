-- Materialize the QGIS barrier_way MarkerLine rules as map-unit polygons.
-- QGIS places the bollard and palisade markers every 1.5 m / 0.2 m from the
-- start of every line part. Retaining-wall triangles start 1 m along and recur
-- every 2 m, or 0.33 m / 0.65 m for walls lower than 1 m, which are also lighter
-- (#909090 instead of #505050) and smaller (0.4 m instead of 0.6 m). A wall
-- without a height counts as tall: QGIS evaluates if(to_real("height") < 1, ...)
-- and NULL < 1 is not true. Marker size and rotation are independent of screen
-- zoom here.

DROP TABLE IF EXISTS barrier_way_marker_polygons;

CREATE TABLE barrier_way_marker_polygons AS
WITH parts AS (
    SELECT
        barrier_way.osm_id,
        barrier_way.barrier,
        COALESCE(barrier_way.height < 1, false) AS low_wall,
        COALESCE(barrier_way.layer, 0) AS layer,
        COALESCE(dump.path[1], 1)::integer AS part_index,
        dump.geom::geometry(LineString, 3857) AS line_geom,
        ST_Length(dump.geom) AS line_length,
        CASE barrier_way.barrier
            WHEN 'bollard' THEN 1.5
            WHEN 'palisade' THEN 0.2
            WHEN 'retaining_wall' THEN CASE WHEN COALESCE(barrier_way.height < 1, false) THEN 0.65 ELSE 2.0 END
        END AS interval_m,
        CASE barrier_way.barrier
            WHEN 'retaining_wall' THEN CASE WHEN COALESCE(barrier_way.height < 1, false) THEN 0.33 ELSE 1.0 END
            ELSE 0.0
        END AS offset_m,
        CASE barrier_way.barrier
            WHEN 'bollard' THEN 0.4
            WHEN 'palisade' THEN 0.2
            WHEN 'retaining_wall' THEN CASE WHEN COALESCE(barrier_way.height < 1, false) THEN 0.4 ELSE 0.6 END
        END AS marker_size_m
    FROM barrier_way
    CROSS JOIN LATERAL ST_Dump(barrier_way.geom) AS dump
    WHERE barrier_way.barrier IN ('bollard', 'palisade', 'retaining_wall')
      AND dump.geom IS NOT NULL
      AND NOT ST_IsEmpty(dump.geom)
      AND ST_Length(dump.geom) > 0
),
markers AS (
    SELECT
        parts.*, marker_index,
        offset_m + marker_index * interval_m AS distance_along,
        ST_LineInterpolatePoint(
            line_geom, (offset_m + marker_index * interval_m) / line_length
        )::geometry(Point, 3857) AS marker_point
    FROM parts
    CROSS JOIN LATERAL generate_series(
        0, floor((line_length - offset_m - 1e-9) / interval_m)::integer
    ) AS marker_index
    WHERE line_length > offset_m
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
)
SELECT
    row_number() OVER (ORDER BY barrier, layer, part_index, marker_index)::bigint
        AS marker_id,
    osm_id, barrier, layer, part_index, marker_index, distance_along, marker_size_m,
    CASE WHEN barrier = 'palisade' THEN '#656565' WHEN barrier = 'retaining_wall' AND low_wall THEN '#909090' ELSE '#505050' END AS colour,
    CASE barrier WHEN 'palisade' THEN '#505050' ELSE '#232323' END AS outline_colour,
    CASE barrier
        WHEN 'retaining_wall' THEN ST_MakePolygon(ST_MakeLine(ARRAY[
            ST_SetSRID(ST_MakePoint(ST_X(marker_point) + tangent_x * (marker_size_m / 2.0), ST_Y(marker_point) + tangent_y * (marker_size_m / 2.0)), 3857),
            ST_SetSRID(ST_MakePoint(ST_X(marker_point) - tangent_x * (marker_size_m / 4.0) + tangent_y * (marker_size_m / 2.0), ST_Y(marker_point) - tangent_y * (marker_size_m / 4.0) - tangent_x * (marker_size_m / 2.0)), 3857),
            ST_SetSRID(ST_MakePoint(ST_X(marker_point) - tangent_x * (marker_size_m / 4.0) - tangent_y * (marker_size_m / 2.0), ST_Y(marker_point) - tangent_y * (marker_size_m / 4.0) + tangent_x * (marker_size_m / 2.0)), 3857),
            ST_SetSRID(ST_MakePoint(ST_X(marker_point) + tangent_x * (marker_size_m / 2.0), ST_Y(marker_point) + tangent_y * (marker_size_m / 2.0)), 3857)
        ]))
        ELSE ST_Buffer(marker_point, marker_size_m / 2.0, 'quad_segs=8')
    END::geometry(Polygon, 3857) AS geom
FROM oriented;

ALTER TABLE barrier_way_marker_polygons ADD PRIMARY KEY (marker_id);
CREATE INDEX barrier_way_marker_polygons_geom_idx
    ON barrier_way_marker_polygons USING gist (geom);
ANALYZE barrier_way_marker_polygons;
