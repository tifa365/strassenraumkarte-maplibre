-- Creates bridge areas shrunk at the ends to render shadow areas under bridges

-- Basic idea:
-- 1) split the outer edges of bridges at their corners into individual segments,
-- 2) buffer segments that are intersected by highways,
-- 3) subtract these buffers from bridge polygons.

-- 1) Split the outer edges of bridges at their corners into individual segments

-- Step A: Extract exterior rings of bridge polygons
DROP TABLE IF EXISTS bridge_shade;

CREATE TABLE bridge_shade AS

WITH edges AS (
    SELECT
        osm_id,
        layer,
        ST_ExteriorRing(geom) AS geom
    FROM bridge
),

-- Step B: Extract bridge segments
segments AS (
    SELECT
        osm_id,
        layer,
        (ST_DumpSegments(geom)).geom AS geom,
        (ST_DumpSegments(geom)).path[1] AS num,
        (
            SELECT COUNT(*)
            FROM ST_DumpSegments(geom)
        ) AS max_num
    FROM edges
),

-- Step C: Get the angle difference between each segment and the previous segment
segment_angle AS (
    SELECT segment.osm_id, segment.layer, segment.num, segment.max_num, segment.geom,
        ABS(DEGREES(ST_Azimuth(ST_StartPoint(segment.geom), ST_EndPoint(segment.geom)))::INTEGER -
        DEGREES(ST_Azimuth(ST_StartPoint(prev.geom), ST_EndPoint(prev.geom)))::INTEGER) AS angle
    FROM segments segment
    LEFT JOIN
        segments prev
        ON
            -- previous segment of the first segment is the last segment
            CASE
                WHEN segment.num = 1 THEN prev.num = segment.max_num
                ELSE prev.num = segment.num - 1
            END
            AND segment.osm_id = prev.osm_id
    ORDER BY
        segment.num
),

-- Step D: Merge all segments with small angles to each other (until the next segment appears with a significant angle)
edges_grouped AS (
    WITH segment_classification AS (
        SELECT
            osm_id,
            layer,
            num,
            geom,
            angle,
            SUM(CASE WHEN angle > 30 THEN 1 ELSE 0 END)
                OVER (PARTITION BY osm_id ORDER BY num ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            AS edge_id
        FROM segment_angle
    )
    SELECT
        osm_id,
        edge_id,
        layer,
        ST_LineMerge(ST_Collect(geom)) AS geom
    FROM segment_classification
    GROUP BY osm_id, edge_id, layer
    ORDER BY osm_id, edge_id, layer
),


-- 2) Buffer segments that are intersected by highways or railway tracks

-- Step A1: Select segments that intersect with highway lines
edges_intersect_hw AS (
    SELECT DISTINCT
        edges_grouped.osm_id,
        edges_grouped.geom
    FROM edges_grouped
    JOIN highway
    ON ST_Intersects(edges_grouped.geom, highway.geom)
    -- take only intersections in the same layer into account (consider layer = 0 and layer = NULL the same)
    WHERE
        highway.layer = edges_grouped.layer
        OR ((highway.layer IS NULL OR highway.layer = 0) AND (edges_grouped.layer IS NULL OR edges_grouped.layer = 0))
),

-- Step A2: Select segments that intersect with railway lines
edges_intersect_rw AS (
    SELECT DISTINCT
        edges_grouped.osm_id,
        edges_grouped.geom
    FROM edges_grouped
    JOIN railway_way railway
    ON ST_Intersects(edges_grouped.geom, railway.geom)
    -- take only intersections in the same layer into account (consider layer = 0 and layer = NULL the same)
    WHERE
        railway.layer = edges_grouped.layer
        OR ((railway.layer IS NULL OR railway.layer = 0) AND (edges_grouped.layer IS NULL OR edges_grouped.layer = 0))
),

-- Step A3: Union highway and railway intersected edges
edges_intersect AS (
    SELECT osm_id, geom FROM edges_intersect_hw
    UNION
    SELECT osm_id, geom FROM edges_intersect_rw
),

-- Step B: Buffer intersection segments
edges_buffer AS (
    SELECT DISTINCT
        osm_id,
        ST_Buffer((ST_Dump(ST_Union(geom))).geom, metres(5)) AS geom
    FROM edges_intersect
    GROUP BY osm_id
)


-- 3) Finally, subtract buffers from bridge polygons (separately for each bridge)
SELECT
    bridge.osm_id, bridge.layer,
    ST_Difference(bridge.geom, ST_Union(edges_buffer.geom)) AS geom
FROM bridge
-- don't subtract buffers from other (nearby) bridges
JOIN edges_buffer
ON bridge.osm_id = edges_buffer.osm_id
GROUP BY bridge.osm_id, bridge.layer, bridge.geom;