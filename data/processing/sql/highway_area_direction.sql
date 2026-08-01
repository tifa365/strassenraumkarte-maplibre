-- Calculates the direction of street, landuse (paving_stones/sett) and road marking
-- area polygons for a better rendering of the surface texture.
-- Only rows with direction IS NULL are updated (OSM direction tags are preserved).
-- Parking polygons: street parking in highway_area; off-street parking in landuse.
--
-- Temp table _area_envelope_direction also stores nearest_road_azimuth (degrees) for
-- each polygon envelope — azimuth of the closest road/motorway centerline within
-- area_direction_road_search_m. Reuse this table for further steps in this script
-- before DROP.
--
-- With a nearby road, direction picks the long or short oriented-envelope axis that
-- aligns with the street (angle comparison mod 180°). If the long axis is across the
-- road (area wider than long along the street), the short axis is used.
--
-- road_marking_polygon: pattern = 'stripes' or (road_marking = 'restriction' and no
-- pattern) use nearest_road_azimuth when a road is found. barred_area direction is set
-- in road_marking_barred_area.sql (lane azimuth + 45°) for unmerged polygons; merged
-- barred_area/restriction clusters (direction NULL) are computed here like restriction
-- (+45°). pattern = 'zigzag' with a road
-- uses the envelope edge closest to the shortest-line bearing (ST_ShortestLine polygon
-- to road, oriented toward the road); zigzag without a road uses
-- direction_short. road_marking = 'restriction' adds +45° (except zigzag). OSM directions
-- are not updated.
--
-- Depends on: highway_transformed (lanes_spread_dual_carriageway.sql)

-- TODO: parking: In future, there might be a conflict between "direction" in the sense of
-- the orientation of the geometry and "direction" in the sense of backward-/forward parking
-- (see street parking documentation for what "direction" means on parking areas).
-- parking_space symbol orientation is handled separately in road_marking_parking.sql.

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'

CREATE TEMP TABLE _area_direction_roads AS
SELECT geom
FROM highway_transformed
WHERE type IN ('road', 'motorway')
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_Length(geom) > metres(0.5);

CREATE INDEX _area_direction_roads_geom_idx
    ON _area_direction_roads
    USING GIST (geom);

CREATE TEMP TABLE _area_envelope_direction AS
WITH areas AS (
    SELECT 'highway_area'::text AS target, osm_id, geom, NULL::text AS pattern, NULL::text AS road_marking
    FROM highway_area
    WHERE direction IS NULL
    UNION ALL
    SELECT 'landuse', osm_id, geom, NULL::text, NULL::text
    FROM landuse
    WHERE direction IS NULL
      AND surface IN ('paving_stones', 'sett')
    UNION ALL
    SELECT 'road_marking_polygon', osm_id, geom, pattern, road_marking
    FROM road_marking_polygon
    WHERE direction IS NULL
      AND source NOT IN ('lane_colour', 'highway_area_colour')
),
envelope AS (
    SELECT
        areas.target,
        areas.osm_id,
        areas.geom,
        areas.pattern,
        areas.road_marking,
        ST_OrientedEnvelope(areas.geom) AS envelope
    FROM areas
),
envelope_sides AS (
    SELECT
        envelope.target,
        envelope.osm_id,
        envelope.geom,
        envelope.pattern,
        envelope.road_marking,
        ST_PointN(ST_ExteriorRing(envelope.envelope), 1) AS p1,
        ST_PointN(ST_ExteriorRing(envelope.envelope), 2) AS p2,
        ST_PointN(ST_ExteriorRing(envelope.envelope), 3) AS p3,
        ST_PointN(ST_ExteriorRing(envelope.envelope), 4) AS p4,
        ST_Distance(
            ST_PointN(ST_ExteriorRing(envelope.envelope), 1),
            ST_PointN(ST_ExteriorRing(envelope.envelope), 2)
        ) AS side1_len,
        ST_Distance(
            ST_PointN(ST_ExteriorRing(envelope.envelope), 2),
            ST_PointN(ST_ExteriorRing(envelope.envelope), 3)
        ) AS side2_len
    FROM envelope
),
envelope_azimuth AS (
    SELECT
        target,
        osm_id,
        geom,
        pattern,
        road_marking,
        CASE
            WHEN side1_len >= side2_len THEN ST_Azimuth(p1, p2)
            ELSE ST_Azimuth(p2, p3)
        END AS azimuth_long,
        CASE
            WHEN side1_len < side2_len THEN ST_Azimuth(p1, p2)
            ELSE ST_Azimuth(p2, p3)
        END AS azimuth_short,
        ROUND(DEGREES(
            CASE
                WHEN side1_len >= side2_len THEN ST_Azimuth(p1, p2)
                ELSE ST_Azimuth(p2, p3)
            END
        ))::INTEGER AS direction_long,
        ROUND(DEGREES(
            CASE
                WHEN side1_len < side2_len THEN ST_Azimuth(p1, p2)
                ELSE ST_Azimuth(p2, p3)
            END
        ))::INTEGER AS direction_short
    FROM envelope_sides
),
nearest_road AS (
    SELECT DISTINCT ON (ea.target, ea.osm_id)
        ea.target,
        ea.osm_id,
        ST_Azimuth(
            ST_LineInterpolatePoint(
                ht.geom,
                GREATEST(0::double precision, ST_LineLocatePoint(ht.geom, sl.cp) - 1e-8)
            ),
            ST_LineInterpolatePoint(
                ht.geom,
                LEAST(1::double precision, ST_LineLocatePoint(ht.geom, sl.cp) + 1e-8)
            )
        ) AS road_azimuth,
        ST_Azimuth(
            ST_StartPoint(sl.shortest),
            ST_EndPoint(sl.shortest)
        ) AS link_azimuth
    FROM envelope_azimuth ea
    JOIN _area_direction_roads ht
      ON ht.geom && ST_Expand(ea.geom, metres(:'area_direction_road_search_m'::double precision))
     AND ST_DWithin(
            ea.geom,
            ht.geom,
            metres(:'area_direction_road_search_m'::double precision)
        )
    CROSS JOIN LATERAL (
        SELECT
            ST_ShortestLine(ea.geom, ht.geom) AS shortest,
            ST_EndPoint(ST_ShortestLine(ea.geom, ht.geom)) AS cp
    ) sl
    ORDER BY ea.target, ea.osm_id, ea.geom <-> ht.geom
),
envelope_edges AS (
    SELECT
        es.target,
        es.osm_id,
        edge.edge_azimuth_deg,
        nr.link_azimuth,
        ROUND(DEGREES(nr.link_azimuth))::INTEGER AS link_azimuth_deg,
        LEAST(
            LEAST(
                ABS(
                    edge.edge_azimuth_deg
                    - ROUND(DEGREES(nr.link_azimuth))::INTEGER
                ),
                360 - ABS(
                    edge.edge_azimuth_deg
                    - ROUND(DEGREES(nr.link_azimuth))::INTEGER
                )
            ),
            180 - LEAST(
                ABS(
                    edge.edge_azimuth_deg
                    - ROUND(DEGREES(nr.link_azimuth))::INTEGER
                ),
                360 - ABS(
                    edge.edge_azimuth_deg
                    - ROUND(DEGREES(nr.link_azimuth))::INTEGER
                )
            )
        )::double precision AS link_edge_diff_deg
    FROM envelope_sides es
    JOIN nearest_road nr
      ON nr.target = es.target
     AND nr.osm_id = es.osm_id
    CROSS JOIN LATERAL (
        VALUES
            (ROUND(DEGREES(ST_Azimuth(es.p1, es.p2)))::INTEGER),
            (ROUND(DEGREES(ST_Azimuth(es.p2, es.p3)))::INTEGER),
            (ROUND(DEGREES(ST_Azimuth(es.p3, es.p4)))::INTEGER),
            (ROUND(DEGREES(ST_Azimuth(es.p4, es.p1)))::INTEGER)
    ) AS edge(edge_azimuth_deg)
    WHERE es.pattern = 'zigzag'
),
zigzag_edge_pick AS (
    SELECT DISTINCT ON (target, osm_id)
        target,
        osm_id,
        -- edge match is undirected; flip 180° if edge points away from the link (polygon → road)
        MOD(
            CASE
                WHEN LEAST(
                    ABS(edge_azimuth_deg - link_azimuth_deg),
                    360 - ABS(edge_azimuth_deg - link_azimuth_deg)
                ) > 90
                THEN edge_azimuth_deg + 180
                ELSE edge_azimuth_deg
            END + 3600,
            360
        )::INTEGER AS direction_zigzag
    FROM envelope_edges
    ORDER BY target, osm_id, link_edge_diff_deg, edge_azimuth_deg
),
envelope_road_match AS (
    SELECT
        ea.target,
        ea.osm_id,
        ea.pattern,
        ea.road_marking,
        ea.direction_long,
        ea.direction_short,
        ROUND(DEGREES(nr.road_azimuth))::INTEGER AS nearest_road_azimuth,
        zep.direction_zigzag,
        LEAST(
            LEAST(
                ABS(ea.azimuth_long - nr.road_azimuth),
                2 * pi() - ABS(ea.azimuth_long - nr.road_azimuth)
            ),
            pi() - LEAST(
                ABS(ea.azimuth_long - nr.road_azimuth),
                2 * pi() - ABS(ea.azimuth_long - nr.road_azimuth)
            )
        ) AS undirected_long,
        LEAST(
            LEAST(
                ABS(ea.azimuth_short - nr.road_azimuth),
                2 * pi() - ABS(ea.azimuth_short - nr.road_azimuth)
            ),
            pi() - LEAST(
                ABS(ea.azimuth_short - nr.road_azimuth),
                2 * pi() - ABS(ea.azimuth_short - nr.road_azimuth)
            )
        ) AS undirected_short
    FROM envelope_azimuth ea
    LEFT JOIN nearest_road nr
      ON nr.target = ea.target
     AND nr.osm_id = ea.osm_id
    LEFT JOIN zigzag_edge_pick zep
      ON zep.target = ea.target
     AND zep.osm_id = ea.osm_id
)
SELECT
    erm.target,
    erm.osm_id,
    erm.nearest_road_azimuth,
    CASE
            -- road marking zizag pattern: direction oriented towards nearest road
            WHEN erm.target = 'road_marking_polygon'
             AND erm.pattern = 'zigzag'
             AND erm.direction_zigzag IS NOT NULL
            THEN erm.direction_zigzag
            -- road marking zizag pattern (fallback when there is no nearest road):
            -- direction oriented towards shortest axis
            WHEN erm.target = 'road_marking_polygon'
             AND erm.pattern = 'zigzag'
            THEN erm.direction_short
            -- road_marking = 'restriction' or merged barred_area (except zigzag): +45°
            WHEN erm.target = 'road_marking_polygon'
             AND erm.road_marking IN ('restriction', 'barred_area')
             AND erm.pattern IS DISTINCT FROM 'zigzag'
            THEN MOD(
                CASE
                    -- road marking stripes or no pattern:
                    -- direction oriented like the azimuth of the nearest road
                    WHEN erm.nearest_road_azimuth IS NOT NULL
                     AND (
                        erm.pattern = 'stripes'
                        OR erm.pattern IS NULL
                     )
                    THEN erm.nearest_road_azimuth
                    -- when area is wider than long along the street, use the short axis
                    WHEN erm.nearest_road_azimuth IS NOT NULL
                     AND erm.undirected_short < erm.undirected_long
                    THEN erm.direction_short
                    -- else: direction oriented towards longest axis
                    WHEN erm.nearest_road_azimuth IS NOT NULL
                    THEN erm.direction_long
                    ELSE erm.direction_long
                END + 45 + 3600,
                360
            )::INTEGER
            -- road marking stripes or no pattern:
            -- direction oriented like the azimuth of the nearest road
            WHEN erm.target = 'road_marking_polygon'
             AND erm.nearest_road_azimuth IS NOT NULL
             AND (
                erm.pattern = 'stripes'
                OR (erm.road_marking = 'restriction' AND erm.pattern IS NULL)
             )
            THEN erm.nearest_road_azimuth
            -- when area is wider than long along the street, use the short axis
            WHEN erm.nearest_road_azimuth IS NOT NULL
             AND erm.undirected_short < erm.undirected_long
            THEN erm.direction_short
            -- else: direction oriented towards longest axis
            WHEN erm.nearest_road_azimuth IS NOT NULL
            THEN erm.direction_long
            ELSE erm.direction_long
    END AS direction
FROM envelope_road_match erm;

DROP TABLE _area_direction_roads;

UPDATE highway_area
SET direction = d.direction
FROM _area_envelope_direction d
WHERE highway_area.osm_id = d.osm_id
  AND d.target = 'highway_area';

UPDATE landuse
SET direction = d.direction
FROM _area_envelope_direction d
WHERE landuse.osm_id = d.osm_id
  AND d.target = 'landuse';

UPDATE road_marking_polygon
SET direction = d.direction
FROM _area_envelope_direction d
WHERE road_marking_polygon.osm_id = d.osm_id
  AND d.target = 'road_marking_polygon';

DROP TABLE _area_envelope_direction;
