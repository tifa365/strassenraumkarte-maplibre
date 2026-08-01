-- highway_area_parking_class.sql — set class for street parking polygons
-- from the predominant overlapping (non-parking) highway_area, or else the
-- nearest highway centerline (road / motorway / service).
--
-- Target: area:highway IN ('parking', 'parking_two_wheel').
-- Import leaves class NULL; type is already lane|street_side.
--
-- Depends on: highway_area (highway_area_merge.sql); highway (highway_preparation.sql).

\i 'processing/sql/params/params.sql'

DROP TABLE IF EXISTS _parking_class_resolved;
CREATE TEMP TABLE _parking_class_resolved AS
WITH parking AS (
    SELECT
        ha.ctid AS parking_ctid,
        ha.layer,
        ha.geom
    FROM highway_area ha
    WHERE ha."area:highway" IN ('parking', 'parking_two_wheel')
      AND ha.geom IS NOT NULL
      AND NOT ST_IsEmpty(ha.geom)
),
roads AS (
    SELECT
        ha."area:highway" AS road_class,
        ha.hierarchy,
        ha.layer,
        ha.geom
    FROM highway_area ha
    WHERE ha."area:highway" NOT IN ('parking', 'parking_two_wheel', 'parking_space')
      AND ha."area:highway" IS NOT NULL
      AND ha.geom IS NOT NULL
      AND NOT ST_IsEmpty(ha.geom)
),
overlap_raw AS (
    SELECT
        p.parking_ctid,
        r.road_class,
        r.hierarchy,
        ST_Area(ST_Intersection(p.geom, r.geom)) AS overlap_area,
        (p.layer IS NOT DISTINCT FROM r.layer) AS same_layer
    FROM parking p
    INNER JOIN roads r
        ON p.geom && r.geom
       AND ST_Intersects(p.geom, r.geom)
),
overlap_same_layer AS (
    SELECT
        parking_ctid,
        BOOL_OR(same_layer AND overlap_area > 0) AS has_same_layer
    FROM overlap_raw
    GROUP BY parking_ctid
),
overlap_filtered AS (
    SELECT o.*
    FROM overlap_raw o
    INNER JOIN overlap_same_layer s
        ON s.parking_ctid = o.parking_ctid
    WHERE o.overlap_area > 0
      AND (NOT s.has_same_layer OR o.same_layer)
),
overlap_by_class AS (
    SELECT
        parking_ctid,
        road_class,
        SUM(overlap_area) AS total_area,
        MIN(hierarchy) AS hierarchy
    FROM overlap_filtered
    GROUP BY parking_ctid, road_class
),
best_overlap AS (
    SELECT DISTINCT ON (parking_ctid)
        parking_ctid,
        road_class
    FROM overlap_by_class
    ORDER BY
        parking_ctid,
        total_area DESC,
        hierarchy ASC NULLS LAST,
        road_class ASC
),
need_fallback AS (
    SELECT
        p.parking_ctid,
        p.geom
    FROM parking p
    LEFT JOIN best_overlap b
        ON b.parking_ctid = p.parking_ctid
    WHERE b.parking_ctid IS NULL
),
nearest_highway AS (
    SELECT DISTINCT ON (n.parking_ctid)
        n.parking_ctid,
        h.highway AS road_class
    FROM need_fallback n
    INNER JOIN highway h
        ON h.type IN ('road', 'motorway', 'service')
       AND h.highway IS NOT NULL
       AND h.geom IS NOT NULL
       AND NOT ST_IsEmpty(h.geom)
       AND n.geom && ST_Expand(
            n.geom,
            metres(:'parking_class_highway_search_m'::double precision)
        )
       AND ST_DWithin(
            n.geom,
            h.geom,
            metres(:'parking_class_highway_search_m'::double precision)
        )
    ORDER BY
        n.parking_ctid,
        n.geom <-> h.geom
)
SELECT parking_ctid, road_class FROM best_overlap
UNION ALL
SELECT parking_ctid, road_class FROM nearest_highway;

CREATE INDEX _parking_class_resolved_ctid_idx
    ON _parking_class_resolved (parking_ctid);

UPDATE highway_area ha
SET class = r.road_class
FROM _parking_class_resolved r
WHERE ha.ctid = r.parking_ctid;

DROP TABLE IF EXISTS _parking_class_resolved;
