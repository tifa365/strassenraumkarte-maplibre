-- road_marking_parking.sql — parking area outlines and parking_space symbols
-- Depends on: highway_area (highway_area_merge.sql), feature_polygon (import),
--   barrier_way / barrier_polygon (import), highway_transformed, lanes.
--
-- 1) Outline segments from parking highway_area + selected feature_polygon
-- 2) Drop segments covered by barrier=kerb; parking_space edges covered by
--    parent parking lot outer boundaries; dedupe shared edges
-- 3) Merge connected outline fragments → road_marking_way (parking_edge)
-- 4) parking_space symbols → road_marking_node with geometry-based direction

\i 'processing/sql/params/params.sql'


----------------------------------------------------------------------
-- 1) Source polygons for outlines
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_outline_sources;
CREATE TEMP TABLE _parking_outline_sources AS
SELECT
    ha.osm_type,
    ha.osm_id,
    ha.layer,
    ha.temporary,
    CASE ha."area:highway"
        WHEN 'parking' THEN 'parking'
        WHEN 'parking_two_wheel' THEN 'motorcycle_parking'
        WHEN 'parking_space' THEN 'parking_space'
    END AS class,
    ha.geom
FROM highway_area ha
WHERE ha."area:highway" IN ('parking', 'parking_two_wheel')
  AND ha.markings IS NOT NULL
  AND ha.markings NOT IN ('no', 'none')
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
UNION ALL
SELECT
    ha.osm_type,
    ha.osm_id,
    ha.layer,
    ha.temporary,
    'parking_space'::text AS class,
    ha.geom
FROM highway_area ha
WHERE ha."area:highway" = 'parking_space'
  AND (ha.markings IS NULL OR ha.markings NOT IN ('no', 'none'))
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
UNION ALL
SELECT
    fp.osm_type,
    fp.osm_id,
    fp.layer,
    fp.temporary,
    fp.class,
    fp.geom
FROM feature_polygon fp
WHERE fp.class IN (
        'bicycle_parking',
        'bicycle_rental',
        'small_electric_vehicle_parking'
    )
  AND fp.geom IS NOT NULL
  AND NOT ST_IsEmpty(fp.geom)
  AND (
        (
            fp.position IN ('lane', 'street_side')
            AND (fp.markings IS NULL OR fp.markings NOT IN ('no', 'none'))
        )
        OR (
            fp.markings IS NOT NULL
            AND fp.markings NOT IN ('no', 'none')
        )
    );

CREATE INDEX _parking_outline_sources_geom_idx
    ON _parking_outline_sources USING GIST (geom);


----------------------------------------------------------------------
-- 2) Boundary segments
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_outline_raw;
CREATE TEMP TABLE _parking_outline_raw AS
WITH boundary_lines AS (
    SELECT
        s.osm_type,
        s.osm_id,
        s.layer,
        s.temporary,
        s.class,
        (bd).path[1] AS fragment_id,
        (bd).geom AS geom
    FROM _parking_outline_sources s
    CROSS JOIN LATERAL ST_Dump(ST_Boundary(s.geom)) AS bd
    WHERE NOT ST_IsEmpty((bd).geom)
),
segments AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        temporary,
        class,
        fragment_id,
        (ds).path[1] AS seg_idx,
        (ds).geom AS geom
    FROM boundary_lines
    CROSS JOIN LATERAL ST_DumpSegments(geom) AS ds
    WHERE ST_GeometryType((ds).geom) = 'ST_LineString'
      AND ST_Length((ds).geom) > metres(:'parking_outline_min_length'::numeric)
)
SELECT * FROM segments;

CREATE INDEX _parking_outline_raw_geom_idx
    ON _parking_outline_raw USING GIST (geom);


----------------------------------------------------------------------
-- 3) Drop segments covered by kerb; dedupe identical shared edges
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_kerbs;
CREATE TEMP TABLE _parking_kerbs AS
SELECT geom
FROM barrier_way
WHERE barrier = 'kerb'
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString'
UNION ALL
SELECT (bd).geom
FROM barrier_polygon bp
CROSS JOIN LATERAL ST_Dump(ST_Boundary(bp.geom)) AS bd
WHERE bp.barrier = 'kerb'
  AND bp.geom IS NOT NULL
  AND NOT ST_IsEmpty(bp.geom)
  AND NOT ST_IsEmpty((bd).geom)
  AND ST_GeometryType((bd).geom) = 'ST_LineString';

CREATE INDEX _parking_kerbs_geom_idx
    ON _parking_kerbs USING GIST (geom);


DROP TABLE IF EXISTS _parking_outline_no_kerb;
CREATE TEMP TABLE _parking_outline_no_kerb AS
SELECT
    s.osm_type,
    s.osm_id,
    s.layer,
    s.temporary,
    s.class,
    s.fragment_id,
    s.seg_idx,
    s.geom
FROM _parking_outline_raw s
WHERE NOT EXISTS (
    SELECT 1
    FROM _parking_kerbs k
    WHERE k.geom && s.geom
      AND ST_Intersects(k.geom, s.geom)
      AND ST_Covers(k.geom, s.geom)
);

CREATE INDEX _parking_outline_no_kerb_geom_idx
    ON _parking_outline_no_kerb USING GIST (geom);


-- Outer boundaries of parking lots: remaining street parking in highway_area
-- plus off-street amenity parking / motorcycle_parking in landuse.
-- parking_space outlines that coincide with these edges are dropped below.
DROP TABLE IF EXISTS _parking_lot_boundaries;
CREATE TEMP TABLE _parking_lot_boundaries AS
SELECT
    ha.geom AS poly_geom,
    (bd).geom AS geom
FROM highway_area ha
CROSS JOIN LATERAL ST_Dump(ST_Boundary(ha.geom)) AS bd
WHERE ha."area:highway" IN ('parking', 'parking_two_wheel')
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
  AND NOT ST_IsEmpty((bd).geom)
  AND ST_GeometryType((bd).geom) IN ('ST_LineString', 'ST_LinearRing')
UNION ALL
SELECT
    lu.geom AS poly_geom,
    (bd).geom AS geom
FROM landuse lu
CROSS JOIN LATERAL ST_Dump(ST_Boundary(lu.geom)) AS bd
WHERE lu.class IN ('parking', 'motorcycle_parking')
  AND lu.geom IS NOT NULL
  AND NOT ST_IsEmpty(lu.geom)
  AND NOT ST_IsEmpty((bd).geom)
  AND ST_GeometryType((bd).geom) IN ('ST_LineString', 'ST_LinearRing');

CREATE INDEX _parking_lot_boundaries_geom_idx
    ON _parking_lot_boundaries USING GIST (geom);
CREATE INDEX _parking_lot_boundaries_poly_geom_idx
    ON _parking_lot_boundaries USING GIST (poly_geom);


DROP TABLE IF EXISTS _parking_outline_no_lot_edge;
CREATE TEMP TABLE _parking_outline_no_lot_edge AS
SELECT
    s.osm_type,
    s.osm_id,
    s.layer,
    s.temporary,
    s.class,
    s.fragment_id,
    s.seg_idx,
    s.geom
FROM _parking_outline_no_kerb s
WHERE s.class IS DISTINCT FROM 'parking_space'
   OR NOT EXISTS (
        SELECT 1
        FROM highway_area space
        INNER JOIN _parking_lot_boundaries b
            ON b.poly_geom && space.geom
           AND ST_Covers(b.poly_geom, ST_PointOnSurface(space.geom))
        WHERE space.osm_type = s.osm_type
          AND space.osm_id = s.osm_id
          AND space."area:highway" = 'parking_space'
          AND b.geom && s.geom
          AND ST_Intersects(b.geom, s.geom)
          AND ST_Covers(b.geom, s.geom)
    );

CREATE INDEX _parking_outline_no_lot_edge_geom_idx
    ON _parking_outline_no_lot_edge USING GIST (geom);


-- Keep one copy of geometrically identical segments (shared parking edges).
-- Normalize endpoint order so reversed duplicates collapse.
DROP TABLE IF EXISTS _parking_outline_deduped;
CREATE TEMP TABLE _parking_outline_deduped AS
SELECT DISTINCT ON (edge_key)
    osm_type,
    osm_id,
    layer,
    temporary,
    class,
    fragment_id,
    seg_idx,
    geom
FROM (
    SELECT
        s.*,
        CASE
            WHEN ST_X(ST_StartPoint(s.geom)) < ST_X(ST_EndPoint(s.geom))
              OR (
                  ST_X(ST_StartPoint(s.geom)) = ST_X(ST_EndPoint(s.geom))
                  AND ST_Y(ST_StartPoint(s.geom)) <= ST_Y(ST_EndPoint(s.geom))
              )
            THEN ST_AsBinary(s.geom)
            ELSE ST_AsBinary(ST_Reverse(s.geom))
        END AS edge_key
    FROM _parking_outline_no_lot_edge s
) t
ORDER BY
    edge_key,
    osm_id,
    class,
    fragment_id,
    seg_idx;

CREATE INDEX _parking_outline_deduped_geom_idx
    ON _parking_outline_deduped USING GIST (geom);


----------------------------------------------------------------------
-- 4) Merge connected segments per feature/style → road_marking_way
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_outline_merged;
CREATE TEMP TABLE _parking_outline_merged AS
WITH dissolved AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        temporary,
        class,
        ST_LineMerge(ST_UnaryUnion(ST_Collect(geom))) AS geom
    FROM _parking_outline_deduped
    GROUP BY osm_type, osm_id, layer, temporary, class
),
dumped AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        temporary,
        class,
        (ST_Dump(geom)).geom AS geom
    FROM dissolved
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
)
SELECT
    osm_type,
    osm_id,
    layer,
    temporary,
    class,
    geom
FROM dumped
WHERE ST_GeometryType(geom) = 'ST_LineString'
  AND ST_Length(geom) > metres(:'parking_outline_min_length'::numeric);


DELETE FROM road_marking_way
WHERE road_marking = 'parking_edge'
  AND source = 'parking_outline';

INSERT INTO road_marking_way (
    osm_type,
    osm_id,
    source,
    road_marking,
    stroke,
    dasharray,
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
    geom
)
SELECT
    m.osm_type,
    m.osm_id,
    'parking_outline'::text AS source,
    'parking_edge'::text AS road_marking,
    'solid'::text AS stroke,
    NULL::text AS dasharray,
    NULL::text AS pattern,
    NULL::text AS arrow,
    NULL::text AS symbol,
    0.12::real AS width,
    NULL::real AS length,
    CASE
        WHEN m.temporary IS NOT NULL
         AND m.temporary NOT IN ('no', 'none')
        THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    NULL::real AS direction,
    'parking'::text AS type,
    m.class,
    m.layer,
    m.geom
FROM _parking_outline_merged m;


----------------------------------------------------------------------
-- 5) parking_space symbols → road_marking_node
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_symbol_sources;
CREATE TEMP TABLE _parking_symbol_sources AS
SELECT
    ha.osm_type,
    ha.osm_id,
    ha.layer,
    ha.temporary,
    ha.symbol,
    ha.geom,
    ST_PointOnSurface(ha.geom)::geometry(Point) AS pt,
    ST_OrientedEnvelope(ha.geom) AS envelope
FROM highway_area ha
WHERE ha."area:highway" = 'parking_space'
  AND ha.symbol IS NOT NULL
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom);

CREATE INDEX _parking_symbol_sources_geom_idx
    ON _parking_symbol_sources USING GIST (geom);
CREATE INDEX _parking_symbol_sources_pt_idx
    ON _parking_symbol_sources USING GIST (pt);


DROP TABLE IF EXISTS _parking_symbol_roads;
CREATE TEMP TABLE _parking_symbol_roads AS
SELECT geom
FROM highway_transformed
WHERE type IN ('road', 'motorway', 'service')
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_Length(geom) > metres(0.5);

CREATE INDEX _parking_symbol_roads_geom_idx
    ON _parking_symbol_roads USING GIST (geom);


DROP TABLE IF EXISTS _parking_symbol_lanes;
CREATE TEMP TABLE _parking_symbol_lanes AS
SELECT
    geom,
    direction
FROM lanes
WHERE type IN ('road', 'motorway', 'service')
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_Length(geom) > metres(0.5);

CREATE INDEX _parking_symbol_lanes_geom_idx
    ON _parking_symbol_lanes USING GIST (geom);


DROP TABLE IF EXISTS _parking_symbol_direction;
CREATE TEMP TABLE _parking_symbol_direction AS
WITH envelope_sides AS (
    SELECT
        s.osm_type,
        s.osm_id,
        s.layer,
        s.temporary,
        s.symbol,
        s.pt,
        s.geom,
        ST_PointN(ST_ExteriorRing(s.envelope), 1) AS p1,
        ST_PointN(ST_ExteriorRing(s.envelope), 2) AS p2,
        ST_PointN(ST_ExteriorRing(s.envelope), 3) AS p3,
        ST_Distance(
            ST_PointN(ST_ExteriorRing(s.envelope), 1),
            ST_PointN(ST_ExteriorRing(s.envelope), 2)
        ) AS side1_len,
        ST_Distance(
            ST_PointN(ST_ExteriorRing(s.envelope), 2),
            ST_PointN(ST_ExteriorRing(s.envelope), 3)
        ) AS side2_len
    FROM _parking_symbol_sources s
    WHERE s.envelope IS NOT NULL
      AND NOT ST_IsEmpty(s.envelope)
),
long_edge AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        temporary,
        symbol,
        pt,
        geom,
        CASE
            WHEN side1_len >= side2_len THEN ST_Azimuth(p1, p2)
            ELSE ST_Azimuth(p2, p3)
        END AS long_azimuth_rad
    FROM envelope_sides
),
nearest_road AS (
    SELECT DISTINCT ON (le.osm_type, le.osm_id)
        le.osm_type,
        le.osm_id,
        le.layer,
        le.temporary,
        le.symbol,
        le.pt,
        le.geom,
        le.long_azimuth_rad,
        ST_Distance(le.pt, r.geom) AS road_dist,
        ST_Azimuth(
            ST_LineInterpolatePoint(
                r.geom,
                GREATEST(0::double precision, ST_LineLocatePoint(r.geom, sl.cp) - 1e-8)
            ),
            ST_LineInterpolatePoint(
                r.geom,
                LEAST(1::double precision, ST_LineLocatePoint(r.geom, sl.cp) + 1e-8)
            )
        ) AS road_azimuth_rad,
        ST_Azimuth(le.pt, sl.cp) AS to_road_azimuth_rad
    FROM long_edge le
    LEFT JOIN LATERAL (
        SELECT r.geom
        FROM _parking_symbol_roads r
        WHERE r.geom && ST_Expand(le.pt, metres(:'parking_symbol_road_search_m'::double precision))
          AND ST_DWithin(
                le.pt,
                r.geom,
                metres(:'parking_symbol_road_search_m'::double precision)
            )
        ORDER BY le.pt <-> r.geom
        LIMIT 1
    ) r ON true
    LEFT JOIN LATERAL (
        SELECT ST_ClosestPoint(r.geom, le.pt) AS cp
        WHERE r.geom IS NOT NULL
    ) sl ON true
),
angle_info AS (
    SELECT
        nr.*,
        DEGREES(nr.long_azimuth_rad) AS long_deg,
        MOD((DEGREES(nr.long_azimuth_rad) + 180.0)::numeric, 360.0)::double precision AS long_opp_deg,
        CASE
            WHEN nr.road_azimuth_rad IS NULL THEN NULL
            ELSE LEAST(
                LEAST(
                    ABS(DEGREES(nr.long_azimuth_rad) - DEGREES(nr.road_azimuth_rad)),
                    360.0 - ABS(DEGREES(nr.long_azimuth_rad) - DEGREES(nr.road_azimuth_rad))
                ),
                180.0 - LEAST(
                    ABS(DEGREES(nr.long_azimuth_rad) - DEGREES(nr.road_azimuth_rad)),
                    360.0 - ABS(DEGREES(nr.long_azimuth_rad) - DEGREES(nr.road_azimuth_rad))
                )
            )
        END AS undirected_vs_road_deg
    FROM nearest_road nr
),
nearest_lane AS (
    SELECT DISTINCT ON (a.osm_type, a.osm_id)
        a.osm_type,
        a.osm_id,
        ST_Azimuth(
            ST_LineInterpolatePoint(
                lane_geom.geom,
                GREATEST(0::double precision, ST_LineLocatePoint(lane_geom.geom, a.pt) - 1e-8)
            ),
            ST_LineInterpolatePoint(
                lane_geom.geom,
                LEAST(1::double precision, ST_LineLocatePoint(lane_geom.geom, a.pt) + 1e-8)
            )
        ) AS lane_azimuth_rad
    FROM angle_info a
    INNER JOIN LATERAL (
        SELECT
            CASE
                WHEN l.direction = 'backward' THEN ST_Reverse(l.geom)
                ELSE l.geom
            END AS geom
        FROM _parking_symbol_lanes l
        WHERE a.road_dist IS NOT NULL
          AND a.undirected_vs_road_deg IS NOT NULL
          AND a.undirected_vs_road_deg <= :'parking_symbol_parallel_angle_deg'::double precision
          AND l.geom && ST_Expand(a.pt, a.road_dist + metres(0.01))
          AND ST_DWithin(a.pt, l.geom, a.road_dist + metres(0.01))
        ORDER BY a.pt <-> l.geom
        LIMIT 1
    ) lane_geom ON true
),
chosen AS (
    SELECT
        a.osm_type,
        a.osm_id,
        a.layer,
        a.temporary,
        a.symbol,
        a.pt,
        CASE
            -- no nearby road: use long-edge azimuth
            WHEN a.road_azimuth_rad IS NULL THEN a.long_deg
            -- perpendicular / angled parking: point toward the road
            WHEN a.undirected_vs_road_deg > :'parking_symbol_parallel_angle_deg'::double precision THEN
                CASE
                    WHEN LEAST(
                        ABS(a.long_deg - DEGREES(a.to_road_azimuth_rad)),
                        360.0 - ABS(a.long_deg - DEGREES(a.to_road_azimuth_rad))
                    ) <= LEAST(
                        ABS(a.long_opp_deg - DEGREES(a.to_road_azimuth_rad)),
                        360.0 - ABS(a.long_opp_deg - DEGREES(a.to_road_azimuth_rad))
                    )
                    THEN a.long_deg
                    ELSE a.long_opp_deg
                END
            -- parallel parking: align with lane, then flip 180° (against traffic)
            ELSE
                MOD(
                    (
                        CASE
                            WHEN nl.lane_azimuth_rad IS NULL THEN a.long_deg
                            WHEN LEAST(
                                ABS(a.long_deg - DEGREES(nl.lane_azimuth_rad)),
                                360.0 - ABS(a.long_deg - DEGREES(nl.lane_azimuth_rad))
                            ) <= LEAST(
                                ABS(a.long_opp_deg - DEGREES(nl.lane_azimuth_rad)),
                                360.0 - ABS(a.long_opp_deg - DEGREES(nl.lane_azimuth_rad))
                            )
                            THEN a.long_deg
                            ELSE a.long_opp_deg
                        END + 180.0
                    )::numeric,
                    360.0
                )::double precision
        END AS direction
    FROM angle_info a
    LEFT JOIN nearest_lane nl
        ON nl.osm_type = a.osm_type
       AND nl.osm_id = a.osm_id
)
SELECT
    osm_type,
    osm_id,
    layer,
    temporary,
    symbol,
    pt AS geom,
    ROUND(direction::numeric, 1)::real AS direction
FROM chosen;


DELETE FROM road_marking_node
WHERE source = 'parking_space';

INSERT INTO road_marking_node (
    osm_type,
    osm_id,
    source,
    road_marking,
    stroke,
    dasharray,
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
    geom
)
SELECT
    d.osm_type,
    d.osm_id,
    'parking_space'::text AS source,
    'symbol'::text AS road_marking,
    NULL::text AS stroke,
    NULL::text AS dasharray,
    NULL::text AS pattern,
    NULL::text AS arrow,
    d.symbol,
    0.7::real AS width,
    1.0::real AS length,
    CASE
        WHEN d.temporary IS NOT NULL
         AND d.temporary NOT IN ('no', 'none')
        THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    d.direction,
    'parking'::text AS type,
    d.symbol AS class,
    d.layer,
    d.geom
FROM _parking_symbol_direction d;


----------------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_outline_sources;
DROP TABLE IF EXISTS _parking_outline_raw;
DROP TABLE IF EXISTS _parking_kerbs;
DROP TABLE IF EXISTS _parking_outline_no_kerb;
DROP TABLE IF EXISTS _parking_lot_boundaries;
DROP TABLE IF EXISTS _parking_outline_no_lot_edge;
DROP TABLE IF EXISTS _parking_outline_deduped;
DROP TABLE IF EXISTS _parking_outline_merged;
DROP TABLE IF EXISTS _parking_symbol_sources;
DROP TABLE IF EXISTS _parking_symbol_roads;
DROP TABLE IF EXISTS _parking_symbol_lanes;
DROP TABLE IF EXISTS _parking_symbol_direction;
