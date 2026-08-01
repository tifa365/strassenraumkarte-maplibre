-- Adjust traffic sign directions and locations (for traffic sign nodes)

-- 1) For traffic signs on highway lines without direction tags: derive direction from highway line direction
UPDATE traffic_sign_node
-- get direction of the highway line at the location of the node
SET direction = DEGREES(
    CASE
        -- forward (or NULL) direction: get direction to the next vertex, or direction from the previous vertex, if it's the last point on the line
        WHEN traffic_sign_node.direction IS NULL OR traffic_sign_node.direction = 'forward' THEN
            CASE
                WHEN ST_Equals(traffic_sign_node.geom, ST_EndPoint(subquery.geom)) THEN
                    ST_Azimuth(
                        ST_PointN(subquery.geom, idx - 1),
                        traffic_sign_node.geom
                    )
                ELSE
                    ST_Azimuth(
                        traffic_sign_node.geom,
                        ST_PointN(subquery.geom, idx + 1)
                    )
            END
        -- backward direction: get direction from the previous vertex, or direction to the next vertex, it it's the first point on the line
        ELSE
            CASE
                WHEN ST_Equals(traffic_sign_node.geom, ST_StartPoint(subquery.geom)) THEN
                    ST_Azimuth(
                        traffic_sign_node.geom,
                        ST_PointN(subquery.geom, idx + 1)
                    )
                ELSE
                    ST_Azimuth(
                        ST_PointN(subquery.geom, idx - 1),
                        traffic_sign_node.geom
                    )
            END
    END
)::INTEGER +
    CASE
        -- reverse the angle (exept for signs that are directed in backward direction)
        WHEN traffic_sign_node.direction IS NULL OR traffic_sign_node.direction = 'forward' THEN 180
        ELSE 0
    END
FROM (
    SELECT highway.geom, traffic_sign_node.geom AS node_geom,
           generate_series(2, ST_NumPoints(highway.geom)) AS idx -- start with 2, because we need the previous vertex
    FROM highway
    JOIN traffic_sign_node
    ON ST_Intersects(traffic_sign_node.geom, highway.geom)
) subquery
WHERE
    (
        -- fill in empty direction values
        traffic_sign_node.direction IS NULL
        -- or replace forward/backward values by angle number
        OR traffic_sign_node.direction IN ('forward', 'backward')
    )
    AND ST_Equals(traffic_sign_node.geom, ST_PointN(subquery.geom, subquery.idx));


-- 2) For traffic signs next to the highway line: Direct traffic signs according to the direction of close highway lines
-- Step A: Calculate the angle of the shortest distance to the closest road (if there is a road within a specific distance)
WITH nearest_road AS (
    SELECT DISTINCT ON (traffic_sign_node.osm_id)
        traffic_sign_node.osm_id AS traffic_sign_osm_id,
        -- angle of the shortest distance to the closest road
        ST_Azimuth(
            traffic_sign_node.geom,
            ST_ClosestPoint(highway.geom, traffic_sign_node.geom)
        ) AS angle
    FROM traffic_sign_node
    -- only if there is a highway within a specific distance
    JOIN highway
        ON ST_DWithin(traffic_sign_node.geom, highway.geom, metres(20))
    -- select traffic signs without direction value
    WHERE
        traffic_sign_node.direction IS NULL
        -- in the first step, only orienting to roads
        AND highway.highway IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road')
    -- find the closest road, if there are multiple roads nearby
    ORDER BY traffic_sign_node.osm_id, ST_Distance(traffic_sign_node.geom, highway.geom) ASC
)
UPDATE traffic_sign_node
SET direction = DEGREES(nearest_road.angle)::INTEGER - 90
FROM nearest_road
WHERE traffic_sign_node.osm_id = nearest_road.traffic_sign_osm_id;

-- Step 2: Orienting to other ways
-- Repeat step 1 for all traffic signs that still do not have a direction, but use all (other) ways now within a specific distance
WITH nearest_way AS (
    SELECT DISTINCT ON (traffic_sign_node.osm_id)
        traffic_sign_node.osm_id AS traffic_sign_osm_id,
        ST_Azimuth(
            traffic_sign_node.geom,
            ST_ClosestPoint(highway.geom, traffic_sign_node.geom)
        ) AS angle
    FROM traffic_sign_node
    JOIN highway
        ON ST_DWithin(traffic_sign_node.geom, highway.geom, metres(10))
    WHERE traffic_sign_node.direction IS NULL
    ORDER BY traffic_sign_node.osm_id, ST_Distance(traffic_sign_node.geom, highway.geom) ASC
)
UPDATE traffic_sign_node
SET direction = DEGREES(nearest_way.angle)::INTEGER - 90
FROM nearest_way
WHERE traffic_sign_node.osm_id = nearest_way.traffic_sign_osm_id;


-- 3) Normalize direction values (0 .. 360, convert to integer)
ALTER TABLE traffic_sign_node 
ALTER COLUMN direction 
SET DATA TYPE INTEGER 
USING direction::INTEGER;

UPDATE traffic_sign_node
SET direction = (direction % 360 + 3600) % 360
WHERE direction < 0 OR direction >= 360;

ALTER TABLE traffic_sign_node DROP COLUMN IF EXISTS oneway;
ALTER TABLE traffic_sign_node DROP COLUMN IF EXISTS "oneway:bicycle";


-- TODO: Move traffic signs from the centerline to the side of the highway; but check whether there is already a matching sign at this location (or in the immediate vicinity)