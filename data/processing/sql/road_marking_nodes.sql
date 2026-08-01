-- road_marking_nodes.sql — Snap directional OSM road_marking points to lane centerlines
-- Requires: lanes_clipped (road_marking_lanes_prepare.sql), road_marking_node from import
-- Depends on: helper/line_offset.sql

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'

\i 'processing/sql/helper/line_offset.sql'

----------------------------------------------------------------------
-- Snap osm_feature_forward/backward nodes to lanes (single pass, original OSM position)
----------------------------------------------------------------------

WITH nodes AS (
    SELECT
        n.osm_id,
        n.source,
        n.geom AS orig_geom,
        CASE
            WHEN n.source = 'osm_feature_forward' THEN 'forward'::text
            WHEN n.source = 'osm_feature_backward' THEN 'backward'::text
        END AS lane_side
    FROM road_marking_node n
    WHERE n.source IN ('osm_feature_forward', 'osm_feature_backward')
      AND n.geom IS NOT NULL
      AND NOT ST_IsEmpty(n.geom)
),
nearest_dir AS (
    SELECT DISTINCT ON (nd.osm_id, nd.source)
        nd.osm_id,
        nd.source,
        l.layer,
        ST_ClosestPoint(l.geom, nd.orig_geom) AS new_geom
    FROM nodes nd
    JOIN lanes_clipped l
      ON l.direction = nd.lane_side
     AND ST_DWithin(nd.orig_geom, l.geom, metres(:'road_marking_node_lane_search_m'::double precision))
     AND (l.type IS NULL OR l.type IS DISTINCT FROM 'parking')
    WHERE l.geom IS NOT NULL
      AND NOT ST_IsEmpty(l.geom)
    ORDER BY nd.osm_id, nd.source, nd.orig_geom <-> l.geom
),
nodes_pending AS (
    SELECT nd.*
    FROM nodes nd
    LEFT JOIN nearest_dir d
      ON d.osm_id = nd.osm_id
     AND d.source = nd.source
    WHERE d.osm_id IS NULL
),
nearest_both AS (
    SELECT DISTINCT ON (np.osm_id, np.source)
        np.osm_id,
        np.source,
        np.lane_side,
        np.orig_geom,
        l.layer,
        l.width,
        l.geom AS lane_geom
    FROM nodes_pending np
    JOIN lanes_clipped l
      ON l.direction = 'both_ways'
     AND ST_DWithin(np.orig_geom, l.geom, metres(:'road_marking_node_lane_search_m'::double precision))
     AND l.width IS NOT NULL
     AND l.width > 0
    WHERE l.geom IS NOT NULL
      AND NOT ST_IsEmpty(l.geom)
    ORDER BY np.osm_id, np.source, np.orig_geom <-> l.geom
),
offset_pts AS (
    SELECT
        nb.osm_id,
        nb.source,
        nb.layer,
        ST_ClosestPoint(
            line_offset(
                nb.lane_geom,
                CASE
                    WHEN nb.lane_side = 'forward' THEN (nb.width / 4.0)::double precision
                    ELSE -(nb.width / 4.0)::double precision
                END
            ),
            nb.orig_geom
        ) AS new_geom
    FROM nearest_both nb
),
final_geom AS (
    SELECT nd.osm_id, nd.source, d.layer, d.new_geom
    FROM nearest_dir d
    JOIN nodes nd
      ON nd.osm_id = d.osm_id
     AND nd.source = d.source
    UNION ALL
    SELECT op.osm_id, op.source, op.layer, op.new_geom
    FROM offset_pts op
)
UPDATE road_marking_node n
SET
    geom = fg.new_geom,
    layer = COALESCE(fg.layer, n.layer)
FROM final_geom fg
WHERE n.osm_id = fg.osm_id
  AND n.source = fg.source;

----------------------------------------------------------------------
-- Default width and length for road_marking=traffic_sign (when empty in OSM)
----------------------------------------------------------------------

UPDATE road_marking_node
SET
    width = COALESCE(width, :'traffic_sign_default_width'::real),
    length = COALESCE(
        length,
        COALESCE(width, :'traffic_sign_default_width'::real)
            * :'traffic_sign_distortion_factor'::real
    )
WHERE road_marking = 'traffic_sign';

UPDATE road_marking_way
SET
    width = COALESCE(width, :'traffic_sign_default_width'::real),
    length = COALESCE(
        length,
        COALESCE(width, :'traffic_sign_default_width'::real)
            * :'traffic_sign_distortion_factor'::real
    )
WHERE road_marking = 'traffic_sign';

UPDATE road_marking_polygon
SET
    width = COALESCE(width, :'traffic_sign_default_width'::real),
    length = COALESCE(
        length,
        COALESCE(width, :'traffic_sign_default_width'::real)
            * :'traffic_sign_distortion_factor'::real
    )
WHERE road_marking = 'traffic_sign';
