-- road_marking_barred_area.sql — generic barred_area polygons from lane markings
-- Depends on: lanes_clipped (road_marking_lanes_prepare.sql), lanes, highway
-- Output: road_marking_polygon (barred_area)

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/line_offset.sql'


----------------------------------------------------------------------
-- barred_area polygon candidates + reject when OSM feature exists
--
-- Skip polygon when a candidate matches osm_feature polygons (similarity or
-- overlap). Gaps where barred-area lanes cross or touch service highways are cut from
-- edge lines before buffering (width/2 corridor around each service way).
----------------------------------------------------------------------

DROP TABLE IF EXISTS _barred_area_polygons_raw;
CREATE TEMP TABLE _barred_area_polygons_raw AS
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
        lc.marking_left,
        lc.marking_right,
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
marking_sides AS (
    SELECT
        osm_id,
        lane_index,
        direction,
        lane_width,
        layer,
        lane_geom,
        'left'::text AS side,
        buffer_left AS buffer_amount
    FROM lane_base
    WHERE marking_left = 'barred_area'

    UNION ALL

    SELECT
        osm_id,
        lane_index,
        direction,
        lane_width,
        layer,
        lane_geom,
        'right'::text AS side,
        buffer_right AS buffer_amount
    FROM lane_base
    WHERE marking_right = 'barred_area'
),
with_lane_azimuth AS (
    SELECT
        ms.*,
        ST_Azimuth(
            ST_LineInterpolatePoint(lane_geom, GREATEST(0.0, LEAST(1.0, 0.5 - 0.01))),
            ST_LineInterpolatePoint(lane_geom, GREATEST(0.0, LEAST(1.0, 0.5 + 0.01)))
        ) AS lane_azimuth
    FROM marking_sides ms
    WHERE buffer_amount IS NOT NULL
      AND buffer_amount > 0
      AND lane_width IS NOT NULL
      AND lane_width > 0
      AND ST_NPoints(lane_geom) >= 2
),
with_edge AS (
    SELECT
        wla.*,
        CASE
            WHEN direction = 'backward' THEN ST_Reverse(
                line_offset(
                    lane_geom,
                    CASE WHEN side = 'left' THEN -lane_width / 2.0 ELSE lane_width / 2.0 END,
                    0.0
                )
            )
            ELSE line_offset(
                lane_geom,
                CASE WHEN side = 'left' THEN -lane_width / 2.0 ELSE lane_width / 2.0 END,
                0.0
            )
        END AS edge_geom
    FROM with_lane_azimuth wla
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
        ec.direction,
        ec.lane_azimuth,
        ec.buffer_amount,
        (dp).geom::geometry(LineString) AS edge_fragment
    FROM edges_clipped ec
    CROSS JOIN LATERAL ST_Dump(ec.clipped_edge_geom) AS dp
    WHERE ec.clipped_edge_geom IS NOT NULL
      AND NOT ST_IsEmpty(ec.clipped_edge_geom)
      AND ST_GeometryType((dp).geom) = 'ST_LineString'
      AND ST_Length((dp).geom)
          >= metres(:'barred_area_crossing_min_fragment_length'::double precision)
)
SELECT
    osm_id,
    lane_index,
    side,
    layer,
    direction,
    lane_azimuth,
    ST_Buffer(
        edge_fragment,
        metres(buffer_amount),
        CASE
            WHEN direction = 'backward' THEN
                CASE
                    WHEN side = 'left' THEN 'endcap=flat join=round side=right'
                    ELSE 'endcap=flat join=round side=left'
                END
            ELSE
                CASE
                    WHEN side = 'left' THEN 'endcap=flat join=round side=left'
                    ELSE 'endcap=flat join=round side=right'
                END
        END
    ) AS geom
FROM edge_fragments
WHERE edge_fragment IS NOT NULL
  AND NOT ST_IsEmpty(edge_fragment)
  AND ST_NPoints(edge_fragment) >= 2
  AND lane_azimuth IS NOT NULL;

DELETE FROM _barred_area_polygons_raw
WHERE geom IS NULL
   OR ST_IsEmpty(geom)
   OR ST_GeometryType(geom) NOT IN ('ST_Polygon', 'ST_MultiPolygon')
   OR ST_Area(geom) <= 0.01;

CREATE INDEX _barred_area_polygons_raw_geom_idx
    ON _barred_area_polygons_raw USING GIST (geom);

DELETE FROM _barred_area_polygons_raw b
WHERE EXISTS (
    SELECT 1
    FROM LATERAL (
        SELECT ST_Union(rmp.geom) AS features_geom
        FROM road_marking_polygon rmp
        WHERE rmp.source = 'osm_feature'
          AND rmp.road_marking IN ('restriction', 'barred_area')
          AND rmp.geom IS NOT NULL
          AND NOT ST_IsEmpty(rmp.geom)
          AND b.layer IS NOT DISTINCT FROM rmp.layer
          AND b.geom && rmp.geom
          AND ST_Intersects(b.geom, rmp.geom)
    ) feat
    CROSS JOIN LATERAL (
        SELECT
            ST_Area(b.geom) AS candidate_area,
            2.0 * sqrt(ST_Area(ST_MinimumBoundingCircle(b.geom)) / pi()) AS candidate_diameter,
            ST_Area(feat.features_geom) AS feature_area,
            2.0 * sqrt(ST_Area(ST_MinimumBoundingCircle(feat.features_geom)) / pi())
                AS feature_diameter,
            ST_Area(ST_Intersection(b.geom, feat.features_geom)) AS overlap_area
    ) metrics
    WHERE feat.features_geom IS NOT NULL
      AND NOT ST_IsEmpty(feat.features_geom)
      AND metrics.overlap_area > 0
      AND (
          (
              metrics.feature_area / NULLIF(metrics.candidate_area, 0)
                  BETWEEN 1.0 / :'barred_area_osm_feature_max_size_ratio'::double precision
                      AND :'barred_area_osm_feature_max_size_ratio'::double precision
              AND metrics.feature_diameter / NULLIF(metrics.candidate_diameter, 0)
                  BETWEEN 1.0 / :'barred_area_osm_feature_max_size_ratio'::double precision
                      AND :'barred_area_osm_feature_max_size_ratio'::double precision
          )
          OR metrics.overlap_area
              >= :'barred_area_osm_feature_overlap_min_frac'::double precision
                 * metrics.candidate_area
      )
);

----------------------------------------------------------------------
-- 2c) barred_area polygons from lane buffer (source = highway_attributes)
--
-- Candidates prepared in §2c.1; rejected overlaps with osm_feature removed.
-- direction = lane travel azimuth + 45° (degrees, integer stored as real).
----------------------------------------------------------------------

INSERT INTO road_marking_polygon (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    'highway_attributes'::text,
    'barred_area'::text,
    'W'::text,
    osm_id,
    NULL::text,
    'stripes'::text,
    NULL::text,
    NULL::text,
    NULL::real,
    NULL::real,
    :'road_marking_default_colour'::text,
    MOD(
        ROUND(DEGREES(
            CASE
                WHEN direction = 'backward' THEN lane_azimuth + pi()
                ELSE lane_azimuth
            END
        ))::integer + 45 + 360,
        360
    )::real,
    NULL::text,
    NULL::text,
    layer,
    NULL::text,
    geom
FROM _barred_area_polygons_raw
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) IN ('ST_Polygon', 'ST_MultiPolygon')
  AND ST_Area(geom) > 0.01;


----------------------------------------------------------------------
-- 2c.2) Merge touching restriction/barred_area polygons (mergeable pattern + layer)
--
-- restriction and barred_area may merge together. Patterns NULL, stripes and other
-- values except zigzag/x/crosshatch/chessboard share one merge group. Singleton
-- clusters unchanged. Merged direction = NULL (recomputed in highway_area_direction.sql).
----------------------------------------------------------------------

DROP TABLE IF EXISTS _barred_area_merge_candidates;
CREATE TEMP TABLE _barred_area_merge_candidates AS
SELECT
    r.source,
    r.road_marking,
    r.osm_type,
    r.osm_id,
    r.stroke,
    r.pattern,
    r.arrow,
    r.symbol,
    r.width,
    r.length,
    r.colour,
    r.direction,
    r.type,
    r.class,
    r.layer,
    r.dasharray,
    r.geom,
    r.ctid AS orig_ctid,
    CASE
        WHEN r.pattern IS NULL
          OR r.pattern NOT IN ('zigzag', 'x', 'crosshatch', 'chessboard')
        THEN '__mergeable__'::text
        ELSE r.pattern
    END AS merge_pattern
FROM road_marking_polygon r
WHERE r.road_marking IN ('restriction', 'barred_area')
  AND r.geom IS NOT NULL
  AND NOT ST_IsEmpty(r.geom)
  AND ST_Dimension(r.geom) = 2;

CREATE INDEX _barred_area_merge_candidates_geom_idx
    ON _barred_area_merge_candidates USING GIST (geom);
CREATE INDEX _barred_area_merge_candidates_partition_idx
    ON _barred_area_merge_candidates (merge_pattern, layer);

DROP TABLE IF EXISTS _barred_area_merge_clustered;
CREATE TEMP TABLE _barred_area_merge_clustered AS
SELECT
    c.*,
    ST_ClusterDBSCAN(c.geom, 0, 1) OVER (
        PARTITION BY c.merge_pattern, c.layer
    ) AS cluster_id
FROM _barred_area_merge_candidates c;

CREATE INDEX _barred_area_merge_clustered_partition_idx
    ON _barred_area_merge_clustered (merge_pattern, layer, cluster_id);

DROP TABLE IF EXISTS _barred_area_merge_parts;
CREATE TEMP TABLE _barred_area_merge_parts AS
WITH cluster_sizes AS (
    SELECT
        merge_pattern,
        layer,
        cluster_id,
        COUNT(*) AS member_count
    FROM _barred_area_merge_clustered
    WHERE cluster_id IS NOT NULL
    GROUP BY merge_pattern, layer, cluster_id
    HAVING COUNT(*) > 1
),
merge_clusters AS (
    SELECT
        cl.merge_pattern,
        cl.layer,
        cl.cluster_id,
        ST_UnaryUnion(ST_Collect(cl.geom)) AS union_geom
    FROM _barred_area_merge_clustered cl
    INNER JOIN cluster_sizes cs
        ON cs.merge_pattern IS NOT DISTINCT FROM cl.merge_pattern
       AND cs.layer IS NOT DISTINCT FROM cl.layer
       AND cs.cluster_id = cl.cluster_id
    GROUP BY cl.merge_pattern, cl.layer, cl.cluster_id
),
union_parts AS (
    SELECT
        mc.merge_pattern,
        mc.layer,
        mc.cluster_id,
        (dp).path AS part_path,
        (dp).geom AS geom
    FROM merge_clusters mc
    CROSS JOIN LATERAL ST_Dump(mc.union_geom) dp
    WHERE (dp).geom IS NOT NULL
      AND NOT ST_IsEmpty((dp).geom)
      AND ST_GeometryType((dp).geom) IN ('ST_Polygon', 'ST_MultiPolygon')
      AND ST_Area((dp).geom) > 0.01
),
cluster_attrs AS (
    SELECT DISTINCT ON (cl.merge_pattern, cl.layer, cl.cluster_id)
        cl.merge_pattern,
        cl.layer,
        cl.cluster_id,
        cl.source,
        cl.road_marking,
        cl.osm_type,
        cl.osm_id,
        cl.stroke,
        cl.pattern,
        cl.arrow,
        cl.symbol,
        cl.width,
        cl.length,
        cl.colour,
        cl.type,
        cl.class,
        cl.dasharray
    FROM _barred_area_merge_clustered cl
    INNER JOIN cluster_sizes cs
        ON cs.merge_pattern IS NOT DISTINCT FROM cl.merge_pattern
       AND cs.layer IS NOT DISTINCT FROM cl.layer
       AND cs.cluster_id = cl.cluster_id
    ORDER BY
        cl.merge_pattern,
        cl.layer,
        cl.cluster_id,
        ST_Area(cl.geom) DESC,
        cl.osm_id
)
SELECT
    ca.source,
    ca.road_marking,
    ca.osm_type,
    ca.osm_id,
    ca.stroke,
    ca.pattern,
    ca.arrow,
    ca.symbol,
    ca.width,
    ca.length,
    ca.colour,
    NULL::real AS direction,
    ca.type,
    ca.class,
    ca.layer,
    ca.dasharray,
    up.geom
FROM union_parts up
INNER JOIN cluster_attrs ca
    ON ca.merge_pattern IS NOT DISTINCT FROM up.merge_pattern
   AND ca.layer IS NOT DISTINCT FROM up.layer
   AND ca.cluster_id = up.cluster_id;

DELETE FROM road_marking_polygon r
USING (
    SELECT DISTINCT cl.orig_ctid
    FROM _barred_area_merge_clustered cl
    INNER JOIN (
        SELECT merge_pattern, layer, cluster_id
        FROM _barred_area_merge_clustered
        WHERE cluster_id IS NOT NULL
        GROUP BY merge_pattern, layer, cluster_id
        HAVING COUNT(*) > 1
    ) cs
        ON cs.merge_pattern IS NOT DISTINCT FROM cl.merge_pattern
       AND cs.layer IS NOT DISTINCT FROM cl.layer
       AND cs.cluster_id = cl.cluster_id
) doomed
WHERE r.ctid = doomed.orig_ctid;

INSERT INTO road_marking_polygon (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
FROM _barred_area_merge_parts
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) IN ('ST_Polygon', 'ST_MultiPolygon')
  AND ST_Area(geom) > 0.01;

DROP TABLE IF EXISTS _barred_area_merge_parts;
DROP TABLE IF EXISTS _barred_area_merge_clustered;
DROP TABLE IF EXISTS _barred_area_merge_candidates;

DROP TABLE IF EXISTS _barred_area_polygons_raw;

