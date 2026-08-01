-- Split road/motorway centerlines at junction vertices and assign road_segment_id
-- to topologically connected chains between junction nodes.
-- Junction detection uses topological degree (not osm_id count): each line end at a
-- point counts 1, each line passing through (interior vertex) counts 2 — equivalent
-- to counting arms of exploded atomic segments at that vertex.
-- Other highway types are left unchanged (no split, road_segment_id NULL).

BEGIN;

-- Crossing tags on path ways (osm_import.lua); preserve through highway rebuild
ALTER TABLE highway ADD COLUMN IF NOT EXISTS crossing text;
ALTER TABLE highway ADD COLUMN IF NOT EXISTS "crossing:markings" text;
ALTER TABLE highway ADD COLUMN IF NOT EXISTS crossing_ref text;
ALTER TABLE highway ADD COLUMN IF NOT EXISTS width_mapped real;
ALTER TABLE highway ADD COLUMN IF NOT EXISTS "width:effective" real;
ALTER TABLE highway ADD COLUMN IF NOT EXISTS "width:effective_source" text;

-- Only road and motorway lines participate in junction logic
CREATE TEMP TABLE _road_lines AS
SELECT
    row_number() OVER () AS line_id,
    osm_type,
    osm_id,
    highway,
    type,
    class,
    name,
    oneway,
    "oneway:bicycle",
    dual_carriageway,
    surface,
    "sett:length",
    width,
    width_mapped,
    "width:effective",
    "width:effective_source",
    placement_offset,
    left_offset,
    transition,
    "lane_markings:temporary",
    bridge,
    tunnel,
    construction,
    is_sidepath,
    tactile_paving,
    informal,
    crossing,
    "crossing:markings",
    crossing_ref,
    hierarchy,
    layer,
    geom
FROM highway
WHERE type IN ('road', 'motorway');

ANALYZE _road_lines;

-- Step 1: all vertices (support points) per road/motorway line
CREATE TEMP TABLE _vertices AS
SELECT
    line_id,
    osm_id,
    (ST_DumpPoints(geom)).geom AS pt
FROM _road_lines;

ANALYZE _vertices;

-- Step 1b: line endpoints and distinct support points per line
CREATE TEMP TABLE _endpoints AS
SELECT line_id, osm_id, ST_StartPoint(geom) AS pt
FROM _road_lines
UNION ALL
SELECT line_id, osm_id, ST_EndPoint(geom) AS pt
FROM _road_lines;

CREATE TEMP TABLE _line_points AS
SELECT DISTINCT
    line_id,
    osm_id,
    pt
FROM _vertices;

ANALYZE _endpoints;
ANALYZE _line_points;

-- Step 2: junction nodes — topological degree > 2 at a support point
-- (T-junction: through-line interior +2, joining line end +1 → degree 3)
CREATE TEMP TABLE _junction_nodes AS
WITH classified AS (
    SELECT
        lp.pt,
        lp.osm_id,
        EXISTS (
            SELECT 1
            FROM _endpoints e
            WHERE e.line_id = lp.line_id
              AND e.pt = lp.pt
        ) AS is_endpoint
    FROM _line_points lp
),
degrees AS (
    SELECT
        pt,
        SUM(CASE WHEN is_endpoint THEN 1 ELSE 2 END) AS degree
    FROM classified
    GROUP BY pt
)
SELECT pt AS geom
FROM degrees
WHERE degree > 2;

CREATE INDEX _junction_nodes_geom_idx ON _junction_nodes USING btree (geom);

ANALYZE _junction_nodes;

-- Debug: persist junction nodes with topological degree
DROP TABLE IF EXISTS highway_junction_nodes;

CREATE TABLE highway_junction_nodes AS
WITH classified AS (
    SELECT
        lp.pt,
        lp.osm_id,
        EXISTS (
            SELECT 1
            FROM _endpoints e
            WHERE e.line_id = lp.line_id
              AND e.pt = lp.pt
        ) AS is_endpoint
    FROM _line_points lp
),
degrees AS (
    SELECT
        pt AS geom,
        SUM(CASE WHEN is_endpoint THEN 1 ELSE 2 END) AS degree
    FROM classified
    GROUP BY pt
)
SELECT geom, degree
FROM degrees
WHERE degree > 2;

CREATE INDEX highway_junction_nodes_geom_idx
ON highway_junction_nodes
USING GIST (geom);

-- Step 3: split blades — union of junction vertices per affected line
CREATE TEMP TABLE _blades AS
SELECT
    lp.line_id,
    ST_Union(lp.pt) AS blade
FROM _line_points lp
INNER JOIN _junction_nodes j ON j.geom = lp.pt
GROUP BY lp.line_id;

ANALYZE _blades;

-- Step 4: split at junction blades (ST_Split)
CREATE TEMP TABLE _road_split AS
SELECT
    r.osm_type,
    r.osm_id,
    r.highway,
    r.type,
    r.class,
    r.name,
    r.oneway,
    r."oneway:bicycle",
    r.dual_carriageway,
    r.surface,
    r."sett:length",
    r.width,
    r.width_mapped,
    r."width:effective",
    r."width:effective_source",
    r.placement_offset,
    r.left_offset,
    r.transition,
    r."lane_markings:temporary",
    r.bridge,
    r.tunnel,
    r.construction,
    r.is_sidepath,
    r.tactile_paving,
    r.informal,
    r.crossing,
    r."crossing:markings",
    r.crossing_ref,
    r.hierarchy,
    r.layer,
    dumped.geom AS seg_geom
FROM _road_lines r
INNER JOIN _blades b ON b.line_id = r.line_id
CROSS JOIN LATERAL ST_Dump(ST_Split(r.geom, b.blade)) AS dumped

UNION ALL

SELECT
    r.osm_type,
    r.osm_id,
    r.highway,
    r.type,
    r.class,
    r.name,
    r.oneway,
    r."oneway:bicycle",
    r.dual_carriageway,
    r.surface,
    r."sett:length",
    r.width,
    r.width_mapped,
    r."width:effective",
    r."width:effective_source",
    r.placement_offset,
    r.left_offset,
    r.transition,
    r."lane_markings:temporary",
    r.bridge,
    r.tunnel,
    r.construction,
    r.is_sidepath,
    r.tactile_paving,
    r.informal,
    r.crossing,
    r."crossing:markings",
    r.crossing_ref,
    r.hierarchy,
    r.layer,
    r.geom AS seg_geom
FROM _road_lines r
WHERE NOT EXISTS (
    SELECT 1
    FROM _blades b
    WHERE b.line_id = r.line_id
);

ANALYZE _road_split;

-- Step 5: all segments (split roads + unchanged other types) with segment_id
CREATE TEMP TABLE _segments AS
SELECT
    row_number() OVER () AS segment_id,
    seg_geom,
    osm_type,
    osm_id,
    highway,
    type,
    class,
    name,
    oneway,
    "oneway:bicycle",
    dual_carriageway,
    surface,
    "sett:length",
    width,
    width_mapped,
    "width:effective",
    "width:effective_source",
    placement_offset,
    left_offset,
    transition,
    "lane_markings:temporary",
    bridge,
    tunnel,
    construction,
    is_sidepath,
    tactile_paving,
    informal,
    crossing,
    "crossing:markings",
    crossing_ref,
    hierarchy,
    layer,
    is_road_network
FROM (
    SELECT
        seg_geom,
        osm_type,
        osm_id,
        highway,
        type,
        class,
        name,
        oneway,
        "oneway:bicycle",
        dual_carriageway,
        surface,
        "sett:length",
        width,
        width_mapped,
        "width:effective",
        "width:effective_source",
        placement_offset,
        left_offset,
        transition,
        "lane_markings:temporary",
        bridge,
        tunnel,
        construction,
        is_sidepath,
        tactile_paving,
        informal,
        crossing,
        "crossing:markings",
        crossing_ref,
        hierarchy,
        layer,
        TRUE AS is_road_network
    FROM _road_split

    UNION ALL

    SELECT
        h.geom AS seg_geom,
        h.osm_type,
        h.osm_id,
        h.highway,
        h.type,
        h.class,
        h.name,
        h.oneway,
        h."oneway:bicycle",
        h.dual_carriageway,
        h.surface,
        h."sett:length",
        h.width,
        h.width_mapped,
        h."width:effective",
        h."width:effective_source",
        h.placement_offset,
        h.left_offset,
        h.transition,
        h."lane_markings:temporary",
        h.bridge,
        h.tunnel,
        h.construction,
        h.is_sidepath,
        h.tactile_paving,
        h.informal,
        h.crossing,
        h."crossing:markings",
        h.crossing_ref,
        h.hierarchy,
        h.layer,
        FALSE AS is_road_network
    FROM highway h
    WHERE h.type IS DISTINCT FROM 'road'
      AND h.type IS DISTINCT FROM 'motorway'
) all_parts;

ANALYZE _segments;

-- Step 6: segment endpoints for graph connectivity (road/motorway only)
CREATE TEMP TABLE _segment_endpoints AS
SELECT segment_id, ST_StartPoint(seg_geom) AS pt
FROM _segments
WHERE is_road_network
UNION ALL
SELECT segment_id, ST_EndPoint(seg_geom) AS pt
FROM _segments
WHERE is_road_network;

CREATE INDEX _segment_endpoints_pt_idx ON _segment_endpoints USING btree (pt);
CREATE INDEX _segment_endpoints_segment_id_idx ON _segment_endpoints (segment_id);

ANALYZE _segment_endpoints;

-- Step 7: road_segment_id via connected components (link at non-junction endpoints)
CREATE TEMP TABLE _road_segment_ids AS
WITH RECURSIVE
links AS (
    SELECT
        e1.segment_id AS n1,
        e2.segment_id AS n2
    FROM _segment_endpoints e1
    JOIN _segment_endpoints e2
      ON e1.pt = e2.pt
     AND e1.segment_id <> e2.segment_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM _junction_nodes j
        WHERE j.geom = e1.pt
    )
),
adj AS (
    SELECT n1, n2 FROM links
    UNION ALL
    SELECT n2, n1 FROM links
),
reach AS (
    SELECT
        segment_id AS node,
        segment_id AS root
    FROM _segments
    WHERE is_road_network

    UNION

    SELECT
        a.n2,
        r.root
    FROM reach r
    JOIN adj a ON a.n1 = r.node
)
SELECT
    node AS segment_id,
    MIN(root) AS road_segment_id
FROM reach
GROUP BY node;

CREATE INDEX _road_segment_ids_segment_id_idx ON _road_segment_ids (segment_id);

ANALYZE _road_segment_ids;

-- Step 7b: length-weighted median of placement_offset and left_offset per road_segment_id
-- and width (sub-groups within each road_segment_id)
CREATE TEMP TABLE _segment_offset_medians AS
WITH base AS (
    SELECT
        r.road_segment_id,
        s.width,
        s.segment_id,
        s.placement_offset,
        s.left_offset,
        ST_Length(s.seg_geom) AS seg_len
    FROM _segments s
    JOIN _road_segment_ids r ON r.segment_id = s.segment_id
    WHERE s.is_road_network
),
placement_ranked AS (
    SELECT
        road_segment_id,
        width,
        placement_offset,
        SUM(seg_len) OVER (
            PARTITION BY road_segment_id, width
            ORDER BY placement_offset, segment_id
        ) AS cum_len,
        SUM(seg_len) OVER (PARTITION BY road_segment_id, width) AS total_len
    FROM base
    WHERE placement_offset IS NOT NULL
),
placement_median AS (
    SELECT DISTINCT ON (road_segment_id, width)
        road_segment_id,
        width,
        placement_offset AS placement_offset_median
    FROM placement_ranked
    WHERE cum_len >= total_len / 2.0
    ORDER BY road_segment_id, width, placement_offset, cum_len
),
left_ranked AS (
    SELECT
        road_segment_id,
        width,
        left_offset,
        SUM(seg_len) OVER (
            PARTITION BY road_segment_id, width
            ORDER BY left_offset, segment_id
        ) AS cum_len,
        SUM(seg_len) OVER (PARTITION BY road_segment_id, width) AS total_len
    FROM base
    WHERE left_offset IS NOT NULL
),
left_median AS (
    SELECT DISTINCT ON (road_segment_id, width)
        road_segment_id,
        width,
        left_offset AS left_offset_median
    FROM left_ranked
    WHERE cum_len >= total_len / 2.0
    ORDER BY road_segment_id, width, left_offset, cum_len
)
SELECT
    COALESCE(pm.road_segment_id, lm.road_segment_id) AS road_segment_id,
    COALESCE(pm.width, lm.width) AS width,
    pm.placement_offset_median,
    lm.left_offset_median
FROM placement_median pm
FULL OUTER JOIN left_median lm
  ON lm.road_segment_id = pm.road_segment_id
 AND lm.width IS NOT DISTINCT FROM pm.width;

ANALYZE _segment_offset_medians;

UPDATE _segments s
SET placement_offset = m.placement_offset_median
FROM _road_segment_ids r
JOIN _segment_offset_medians m ON m.road_segment_id = r.road_segment_id
WHERE s.segment_id = r.segment_id
  AND s.is_road_network
  AND m.width IS NOT DISTINCT FROM s.width
  AND m.placement_offset_median IS NOT NULL;

UPDATE _segments s
SET left_offset = m.left_offset_median
FROM _road_segment_ids r
JOIN _segment_offset_medians m ON m.road_segment_id = r.road_segment_id
WHERE s.segment_id = r.segment_id
  AND s.is_road_network
  AND m.width IS NOT DISTINCT FROM s.width
  AND m.left_offset_median IS NOT NULL;

-- Step 8: replace highway with split geometries, segment_id and road_segment_id
CREATE TABLE highway_new AS
SELECT
    s.segment_id,
    row_number() OVER (
        PARTITION BY s.osm_id
        ORDER BY s.segment_id
    )::integer AS osm_part,
    r.road_segment_id,
    s.osm_type,
    s.osm_id,
    s.highway,
    s.type,
    s.class,
    s.name,
    s.oneway,
    s."oneway:bicycle",
    s.dual_carriageway,
    s.surface,
    s."sett:length",
    s.width,
    s.width_mapped,
    s."width:effective",
    s."width:effective_source",
    s.placement_offset,
    s.left_offset,
    s.transition,
    s."lane_markings:temporary",
    s.bridge,
    s.tunnel,
    s.construction,
    s.is_sidepath,
    s.tactile_paving,
    s.informal,
    s.crossing,
    s."crossing:markings",
    s.crossing_ref,
    s.hierarchy,
    s.layer,
    s.seg_geom AS geom
FROM _segments s
LEFT JOIN _road_segment_ids r ON r.segment_id = s.segment_id;

DROP TABLE highway;

ALTER TABLE highway_new RENAME TO highway;

CREATE UNIQUE INDEX highway_segment_id_idx ON highway (segment_id);
CREATE INDEX highway_osm_id_part_idx ON highway (osm_id, osm_part);
CREATE INDEX highway_geom_idx ON highway USING GIST (geom);
CREATE INDEX highway_road_segment_id_idx ON highway (road_segment_id);

COMMIT;
