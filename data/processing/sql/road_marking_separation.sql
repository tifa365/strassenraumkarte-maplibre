-- road_marking_separation.sql — separation lines from lane separation attributes
-- Depends on: lanes_clipped (road_marking_lanes_prepare.sql), lanes, highway,
--             barrier_way, barrier_node (osm_import.lua)
-- Output: separation (osm_id, separation, layer, geom),
--         separation_bollard_suppressed (bollard dedup audit log),
--         separation_excluded (fully discarded bollard-only lines; subset of suppressed)

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/line_offset.sql'


----------------------------------------------------------------------
-- 1) Offset separation lines, clip at service ways → _markings_raw
----------------------------------------------------------------------

DROP TABLE IF EXISTS _markings_raw;
CREATE TEMP TABLE _markings_raw AS
WITH crossing_obstacles AS (
    SELECT
        h.layer,
        h.width,
        h.geom
    FROM highway h
    WHERE h.type = 'service'
      AND h.geom IS NOT NULL
      AND NOT ST_IsEmpty(h.geom)
      AND ST_GeometryType(h.geom) = 'ST_LineString'
      AND h.width IS NOT NULL
      AND h.width > 0
),
lane_base AS (
    SELECT
        lc.osm_id,
        lc.lane_index,
        l.direction,
        lc.width AS lane_width,
        lc.buffer_left,
        lc.buffer_right,
        lc.layer,
        lc.separation_left,
        lc.separation_right,
        lc.geom AS lane_geom
    FROM lanes_clipped lc
    JOIN LATERAL (
        SELECT l.*
        FROM lanes l
        WHERE l.osm_id = lc.osm_id
          AND l.lane_index = lc.lane_index
          AND l.geom && ST_Expand(lc.geom, metres(0.001))
          AND ST_DWithin(l.geom, lc.geom, metres(0.001))
        ORDER BY ST_Length(ST_Intersection(l.geom, lc.geom)) DESC,
                 ST_Length(lc.geom) DESC
        LIMIT 1
    ) l ON true
    WHERE lc.geom IS NOT NULL
      AND NOT ST_IsEmpty(lc.geom)
      AND ST_GeometryType(lc.geom) = 'ST_LineString'
),
separation_sides AS (
    SELECT
        osm_id,
        lane_index,
        direction,
        lane_width,
        layer,
        lane_geom,
        'left'::text AS side,
        separation_left AS separation_value,
        buffer_left AS buffer_side
    FROM lane_base
    WHERE separation_left IS NOT NULL
      AND separation_left NOT IN ('no', 'none')

    UNION ALL

    SELECT
        osm_id,
        lane_index,
        direction,
        lane_width,
        layer,
        lane_geom,
        'right'::text AS side,
        separation_right AS separation_value,
        buffer_right AS buffer_side
    FROM lane_base
    WHERE separation_right IS NOT NULL
      AND separation_right NOT IN ('no', 'none')
),
with_offset_distance AS (
    SELECT
        ss.*,
        lane_width / 2.0
            + CASE
                WHEN buffer_side IS NULL OR buffer_side <= 0 THEN 0.0
                WHEN buffer_side <= :'separation_buffer_k'::double precision * 2.0
                    THEN buffer_side / 2.0
                ELSE :'separation_buffer_k'::double precision
              END AS offset_distance
    FROM separation_sides ss
    WHERE lane_width IS NOT NULL
      AND lane_width > 0
      AND ST_NPoints(lane_geom) >= 2
),
with_edge AS (
    SELECT
        wod.*,
        CASE
            WHEN direction = 'backward' THEN ST_Reverse(
                line_offset(
                    lane_geom,
                    -- line_offset(): positive = right of line direction; left = negative
                    CASE WHEN side = 'left' THEN -offset_distance ELSE offset_distance END,
                    0.0
                )
            )
            ELSE line_offset(
                lane_geom,
                CASE WHEN side = 'left' THEN -offset_distance ELSE offset_distance END,
                0.0
            )
        END AS edge_geom
    FROM with_offset_distance wod
),
with_edge_clipped AS (
    SELECT
        we.*,
        cz.zone_geom
    FROM with_edge we
    LEFT JOIN LATERAL (
        SELECT ST_Union(
            ST_Buffer(
                o.geom,
                metres(o.width) / 2.0,
                'endcap=flat join=round'
            )
        ) AS zone_geom
        FROM crossing_obstacles o
        WHERE we.layer IS NOT DISTINCT FROM o.layer
          AND we.lane_geom && ST_Expand(o.geom, metres(o.width / 2.0 + 0.001))
          AND (
              ST_Crosses(we.lane_geom, o.geom)
              OR ST_Touches(we.lane_geom, o.geom)
          )
    ) cz ON cz.zone_geom IS NOT NULL
       AND NOT ST_IsEmpty(cz.zone_geom)
),
edges_clipped AS (
    SELECT
        wec.*,
        CASE
            WHEN wec.zone_geom IS NOT NULL AND NOT ST_IsEmpty(wec.zone_geom)
            THEN ST_Difference(wec.edge_geom, wec.zone_geom)
            ELSE wec.edge_geom
        END AS clipped_edge_geom
    FROM with_edge_clipped wec
),
edge_fragments AS (
    SELECT
        ec.osm_id,
        ec.lane_index,
        ec.side,
        ec.layer,
        ec.lane_width,
        ec.separation_value,
        (dp).geom::geometry(LineString) AS geom
    FROM edges_clipped ec
    CROSS JOIN LATERAL ST_Dump(ec.clipped_edge_geom) AS dp
    WHERE ec.clipped_edge_geom IS NOT NULL
      AND NOT ST_IsEmpty(ec.clipped_edge_geom)
      AND ST_GeometryType((dp).geom) = 'ST_LineString'
      AND ST_Length((dp).geom)
          >= metres(:'barred_area_crossing_min_fragment_length'::double precision)
)
SELECT
    'separation'::text AS road_marking,
    ef.osm_id,
    NULL::text AS type,
    ef.side,
    ef.separation_value AS stroke,
    NULL::numeric AS width,
    NULL::text AS arrow,
    NULL::text AS colour,
    ef.layer,
    NULL::text AS preset_dasharray,
    ef.lane_width,
    ef.geom
FROM edge_fragments ef
WHERE ef.geom IS NOT NULL
  AND NOT ST_IsEmpty(ef.geom)
  AND ST_NPoints(ef.geom) >= 2;

CREATE INDEX _markings_raw_idx ON _markings_raw (road_marking, osm_id);
CREATE INDEX _markings_raw_geom_idx ON _markings_raw USING GIST (geom);

DELETE FROM _markings_raw
WHERE geom IS NULL
   OR ST_IsEmpty(geom)
   OR ST_GeometryType(geom) <> 'ST_LineString';


----------------------------------------------------------------------
-- 2) Merge connected segments with same separation value (shared helper)
----------------------------------------------------------------------

\i 'processing/sql/helper/road_marking_merge_connected_markings.sql'


----------------------------------------------------------------------
-- 3) Suppress generic bollard separation when OSM bollards cover ≥ 1/3
--    of the line length nearby (barrier_way + barrier_node).
----------------------------------------------------------------------

DROP TABLE IF EXISTS _separation_adjusted;
CREATE TEMP TABLE _separation_adjusted AS
WITH all_separation AS (
    SELECT
        row_number() OVER ()::bigint AS sep_id,
        m.osm_id,
        m.stroke,
        m.layer,
        m.geom,
        ST_Length(m.geom) AS sep_len,
        'bollard' = ANY(string_to_array(m.stroke, ';')) AS has_bollard
    FROM _markings_merged m
    WHERE m.road_marking = 'separation'
      AND m.geom IS NOT NULL
      AND NOT ST_IsEmpty(m.geom)
      AND ST_GeometryType(m.geom) = 'ST_LineString'
      AND ST_NPoints(m.geom) >= 2
),
bollard_candidates AS (
    SELECT
        s.*,
        ST_Buffer(
            s.geom,
            metres(:'separation_bollard_proximity_m'::double precision),
            'endcap=round join=round'
        ) AS zone
    FROM all_separation s
    WHERE s.has_bollard
),
way_overlap AS (
    SELECT
        bc.sep_id,
        COALESCE(SUM(ST_Length(ST_Intersection(bw.geom, bc.zone))), 0.0) AS way_len
    FROM bollard_candidates bc
    JOIN barrier_way bw
      ON bw.barrier = 'bollard'
     AND bc.layer IS NOT DISTINCT FROM bw.layer
     AND bw.geom && bc.zone
     AND ST_Intersects(bw.geom, bc.zone)
    GROUP BY bc.sep_id
),
node_overlap AS (
    SELECT
        bc.sep_id,
        GREATEST(COUNT(bn.*) - 1, 0)::double precision
            * metres(:'separation_bollard_node_spacing_m'::double precision) AS node_len
    FROM bollard_candidates bc
    JOIN barrier_node bn
      ON bn.barrier = 'bollard'
     AND bc.layer IS NOT DISTINCT FROM bn.layer
     AND ST_DWithin(
         bn.geom,
         bc.geom,
         metres(:'separation_bollard_proximity_m'::double precision)
     )
    GROUP BY bc.sep_id
),
coverage AS (
    SELECT
        bc.sep_id,
        COALESCE(wo.way_len, 0.0) AS way_len,
        COALESCE(no.node_len, 0.0) AS node_len,
        COALESCE(wo.way_len, 0.0) + COALESCE(no.node_len, 0.0) AS explicit_len,
        bc.sep_len
            * :'separation_bollard_coverage_frac'::double precision AS threshold_len
    FROM bollard_candidates bc
    LEFT JOIN way_overlap wo ON wo.sep_id = bc.sep_id
    LEFT JOIN node_overlap no ON no.sep_id = bc.sep_id
)
SELECT
    s.osm_id,
    s.stroke AS separation_original,
    CASE
        WHEN s.has_bollard
         AND COALESCE(c.explicit_len, 0.0) >= c.threshold_len
        THEN NULLIF(
            array_to_string(
                array_remove(string_to_array(s.stroke, ';'), 'bollard'),
                ';'
            ),
            ''
        )
        ELSE s.stroke
    END AS separation,
    s.layer,
    s.geom,
    s.sep_len,
    COALESCE(c.way_len, 0.0) AS bollard_way_len,
    COALESCE(c.node_len, 0.0) AS bollard_node_len,
    COALESCE(c.explicit_len, 0.0) AS bollard_explicit_len,
    COALESCE(c.threshold_len, 0.0) AS bollard_threshold_len,
    s.has_bollard,
    CASE
        WHEN s.has_bollard
         AND COALESCE(c.explicit_len, 0.0) >= c.threshold_len
        THEN true
        ELSE false
    END AS bollard_suppressed,
    CASE
        WHEN s.has_bollard
         AND COALESCE(c.explicit_len, 0.0) >= c.threshold_len
         AND COALESCE(
             NULLIF(
                 array_to_string(
                     array_remove(string_to_array(s.stroke, ';'), 'bollard'),
                     ';'
                 ),
                 ''
             ),
             'no'
         ) IN ('no', 'none')
        THEN true
        ELSE false
    END AS discard
FROM all_separation s
LEFT JOIN coverage c ON c.sep_id = s.sep_id;


----------------------------------------------------------------------
-- 4) Persist merged lines → separation
----------------------------------------------------------------------

DROP TABLE IF EXISTS separation;

CREATE TABLE separation AS
SELECT
    a.osm_id,
    a.separation,
    a.layer,
    a.geom::geometry(LineString) AS geom
FROM _separation_adjusted a
WHERE NOT a.discard
  AND a.separation IS NOT NULL
  AND a.geom IS NOT NULL
  AND NOT ST_IsEmpty(a.geom)
  AND ST_GeometryType(a.geom) = 'ST_LineString'
  AND ST_NPoints(a.geom) >= 2;

CREATE INDEX separation_geom_idx ON separation USING GIST (geom);


DROP TABLE IF EXISTS separation_bollard_suppressed;

CREATE TABLE separation_bollard_suppressed AS
SELECT
    a.osm_id,
    a.separation_original,
    CASE
        WHEN a.discard THEN NULL::text
        ELSE a.separation
    END AS separation_result,
    CASE
        WHEN a.discard THEN 'discarded'::text
        ELSE 'bollard_token_removed'::text
    END AS outcome,
    a.layer,
    a.sep_len,
    a.bollard_way_len,
    a.bollard_node_len,
    a.bollard_explicit_len,
    a.bollard_threshold_len,
    a.geom::geometry(LineString) AS geom
FROM _separation_adjusted a
WHERE a.bollard_suppressed
  AND a.geom IS NOT NULL
  AND NOT ST_IsEmpty(a.geom)
  AND ST_GeometryType(a.geom) = 'ST_LineString'
  AND ST_NPoints(a.geom) >= 2;

CREATE INDEX separation_bollard_suppressed_geom_idx
    ON separation_bollard_suppressed USING GIST (geom);


DROP TABLE IF EXISTS separation_excluded;

CREATE TABLE separation_excluded AS
SELECT
    osm_id,
    separation_original,
    layer,
    sep_len,
    bollard_way_len,
    bollard_node_len,
    bollard_explicit_len,
    bollard_threshold_len,
    geom
FROM separation_bollard_suppressed
WHERE outcome = 'discarded';

CREATE INDEX separation_excluded_geom_idx ON separation_excluded USING GIST (geom);


-- Cleanup temporary tables
DROP TABLE IF EXISTS _markings_raw;
DROP TABLE IF EXISTS _markings_raw_seg;
DROP TABLE IF EXISTS _markings_endpoints;
DROP TABLE IF EXISTS _markings_merged;
DROP TABLE IF EXISTS _separation_adjusted;
