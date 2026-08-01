-- Directs specific street furniture such as street cabinets or street lamps to the closest street

-- Step 1: Orienting to roads
-- Select all relevant features and calculate the angle of the shortest distance to the closest road (if there is a road within a specific distance)
WITH nearest_road AS (
    SELECT DISTINCT ON (feature.osm_id)
        feature.osm_id AS feature_id,
        -- angle of the shortest distance to the closest road
        ST_Azimuth(
            feature.geom,
            ST_ClosestPoint(highway.geom, feature.geom)
        ) AS angle
    FROM feature_node feature
    -- only if there is a highway within a specific distance
    JOIN highway
        ON ST_DWithin(feature.geom, highway.geom, metres(20))
    -- select relevant features without direction value
    WHERE (feature.class IN ('charging_station', 'grit_bin', 'loading_ramp', 'monitoring_station', 'street_cabinet', 'vending_machine') OR feature.subclass IN ('stolperstein') OR (feature.class = 'street_lamp' AND (feature.subclass ~ 'bent_mast' OR feature.subclass ~ 'angled_mast' OR feature.subclass ~ 'wall')))
        AND feature.direction IS NULL
        -- in the first step, only orienting to roads
        AND highway.highway IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road')
    -- find the closest road, if there are multiple roads nearby
    ORDER BY feature.osm_id, ST_Distance(feature.geom, highway.geom) ASC
)
UPDATE feature_node feature
SET direction = ROUND(DEGREES(nearest_road.angle))
FROM nearest_road
WHERE feature.osm_id = nearest_road.feature_id;

-- Step 2: Orienting to other ways
-- Repeat step 1 for all objects that still do not have a direction, but use all (other) ways now within a specific distance
WITH nearest_way AS (
    SELECT DISTINCT ON (feature.osm_id)
        feature.osm_id AS feature_id,
        ST_Azimuth(
            feature.geom,
            ST_ClosestPoint(highway.geom, feature.geom)
        ) AS angle
    FROM feature_node feature
    JOIN highway
        ON ST_DWithin(feature.geom, highway.geom, metres(10))
    WHERE (feature.class IN ('street_cabinet', 'loading_ramp') OR (feature.class = 'street_lamp' AND (feature.subclass ~ 'bent_mast' OR feature.subclass ~ 'angled_mast')) OR (feature.class = 'vending_machine' AND feature.subclass ~ 'parking_tickets'))
        AND feature.direction IS NULL
    ORDER BY feature.osm_id, ST_Distance(feature.geom, highway.geom) ASC
)
UPDATE feature_node feature
SET direction = ROUND(DEGREES(nearest_way.angle))
FROM nearest_way
WHERE feature.osm_id = nearest_way.feature_id;

-- For guard stones, allways orient them towards the closest way, regardless of its classification
WITH nearest_way AS (
    SELECT DISTINCT ON (feature.osm_id)
        feature.osm_id AS feature_id,
        ST_Azimuth(
            feature.geom,
            ST_ClosestPoint(highway.geom, feature.geom)
        ) AS angle
    FROM feature_node feature
    JOIN highway
        ON ST_DWithin(feature.geom, highway.geom, metres(10))
    WHERE feature.class = 'guard_stone'
        AND feature.direction IS NULL
    ORDER BY feature.osm_id, ST_Distance(feature.geom, highway.geom) ASC
)
UPDATE feature_node feature
SET direction = ROUND(DEGREES(nearest_way.angle))
FROM nearest_way
WHERE feature.osm_id = nearest_way.feature_id;