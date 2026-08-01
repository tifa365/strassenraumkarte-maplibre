-- Generate tactile paving lines along kerbs and paths

BEGIN;

-- Step A: Select kerb nodes with tactile_paving and intersecting kerb ways (ways with barrier=kerb are used to render the tectile pavings)
CREATE TEMP TABLE kerb_nodes AS
SELECT DISTINCT barrier_node.geom
FROM barrier_node
JOIN barrier_way
ON ST_Intersects(barrier_node.geom, barrier_way.geom)
WHERE
    barrier_node.barrier = 'kerb'
    AND barrier_node.tactile_paving = 'yes'
    AND barrier_way.barrier = 'kerb'
    -- exclude kerb segments that are tagged with tactile_paving itself
    AND barrier_way.tactile_paving IS NULL;

-- Step B: Transfer width attributes from intersecting crossing ways
-- (for example, with 4 meter wide crossing markings, it can be assumed that tactile paving is also installed along 4 meters of the edge)
ALTER TABLE kerb_nodes ADD COLUMN width NUMERIC;

UPDATE kerb_nodes
SET width = COALESCE(
    (
        SELECT MAX(highway.width)
        FROM highway
        WHERE
            highway.class = 'crossing'
            AND ST_Intersects(highway.geom, kerb_nodes.geom)
    ),
    5  -- default 5 meter (assume 5 meter of tactile paving along the kerb at a crossing)
);

CREATE INDEX kerb_nodes_geom_idx ON kerb_nodes USING GIST (geom);

-- Step C: Buffer selected kerb nodes by the crossing width (or the default value)
CREATE TEMP TABLE kerb_buffer AS
SELECT ST_Buffer(geom, metres(width) / 2) AS geom
FROM kerb_nodes;

CREATE INDEX kerb_buffer_geom_idx ON kerb_buffer USING GIST (geom);

-- Step D: Extract kerb segments inside the buffer circle
CREATE TEMP TABLE kerb_segments AS
SELECT DISTINCT barrier_way.layer, barrier_way.geom
FROM barrier_way
-- only extract the segments that intersect with the tactile paving kerb node
JOIN kerb_nodes
ON ST_Intersects(barrier_way.geom, kerb_nodes.geom)
-- and only segments without having tactile paving tags themself
WHERE
    barrier_way.barrier = 'kerb'
    AND barrier_way.tactile_paving IS NULL;

CREATE INDEX kerb_segments_geom_idx ON kerb_segments USING GIST (geom);

DROP TABLE IF EXISTS tactile_paving;

CREATE TABLE tactile_paving AS
SELECT
    -- add a "class" attribute to distinguish segments with tactile paving oriented at kerb or highway lines for rendering later
    'kerb' AS class,
    kerb_segments.layer,
    ST_Intersection(kerb_segments.geom, kerb_buffer.geom) AS geom
FROM kerb_segments
JOIN kerb_buffer
ON ST_Intersects(kerb_segments.geom, kerb_buffer.geom)

-- Step E: Add kerb ways tagged with tactile paving themself and highway lines with tactile paving along the way
UNION

SELECT
    'kerb' AS class,
    barrier_way.layer,
    barrier_way.geom
FROM barrier_way
WHERE barrier_way.barrier = 'kerb' AND barrier_way.tactile_paving = 'yes'

UNION

SELECT
    'highway' AS class,
    highway.layer,
    highway.geom
FROM highway
WHERE
    highway.tactile_paving = 'yes'
    AND highway.highway IN ('footway', 'path')
    -- exclude crossings, because "tactile_paving" doesn't mean that tactile paving is _along_ the way, but at its edges
    -- (footway=*/path=* live in highway.class after the schema refactor)
    AND (highway.class IS DISTINCT FROM 'crossing');

END;

CREATE INDEX tactile_paving_geom_idx ON tactile_paving USING GIST (geom);