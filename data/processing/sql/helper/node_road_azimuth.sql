-- Shared road azimuth at highway nodes (stop positions, crossing nodes).
-- Same logic as road_marking_stop_lines.sql §3b (centerline approach direction).
--
-- Prerequisite: temp table _node_road_azimuth_input(node_id, geom) must exist.
-- Output: temp table _node_road_azimuth(node_id, geom, road_azimuth) with road_azimuth in radians.
-- road_azimuth is the orientation of the road centerline itself, consistently in the direction
-- the road geometry is drawn (its own ST_StartPoint -> ST_EndPoint sense) — not a
-- perpendicular/crossing axis. Consumers that need a line across the road (e.g. a crossing
-- axis) must add ±90°.
--
-- Note: a road split at the node (ST_Split below) yields one part ending at the node and one
-- part starting at it; both must report the *same* drawn-direction sense at that point (they
-- are prefix/suffix of the same original line). Segments from different ways touching the same
-- node may still be drawn in independent/opposite conventions, so contributions are aligned to
-- a common sense (flipped by 180° if needed) before averaging — otherwise a plain circular mean
-- of near-opposite azimuths degenerates towards an arbitrary value close to 0°.
--
-- Road selection at each node: primarily highway.type IN ('road', 'motorway'); for nodes
-- without such a road (typically service-road-only locations), highway.type = 'service' is
-- used as a fallback so a road_azimuth can still be determined.

DROP TABLE IF EXISTS _node_road_azimuth;
CREATE TEMP TABLE _node_road_azimuth AS
WITH
roads_at_node_primary AS (
    SELECT DISTINCT
        inp.node_id,
        inp.geom AS node_geom,
        hr.osm_id AS road_id,
        hr.geom AS road_geom
    FROM _node_road_azimuth_input inp
    JOIN highway hr
      ON hr.geom && inp.geom
     AND ST_Intersects(hr.geom, inp.geom)
     AND hr.type IN ('road', 'motorway')
),
roads_at_node_service AS (
    -- Fallback: only for nodes that found no motorway/road match above.
    SELECT DISTINCT
        inp.node_id,
        inp.geom AS node_geom,
        hr.osm_id AS road_id,
        hr.geom AS road_geom
    FROM _node_road_azimuth_input inp
    JOIN highway hr
      ON hr.geom && inp.geom
     AND ST_Intersects(hr.geom, inp.geom)
     AND hr.type = 'service'
    WHERE NOT EXISTS (
        SELECT 1
        FROM roads_at_node_primary p
        WHERE p.node_id = inp.node_id
    )
),
roads_at_node AS (
    SELECT * FROM roads_at_node_primary
    UNION ALL
    SELECT * FROM roads_at_node_service
),
road_parts AS (
    SELECT
        ran.node_id,
        ran.node_geom,
        ran.road_id,
        (d.geom)::geometry(LineString) AS geom
    FROM roads_at_node ran
    CROSS JOIN LATERAL (
        SELECT geom
        FROM (
            SELECT (ST_Dump(
                CASE
                    WHEN ST_Intersects(ST_StartPoint(ran.road_geom), ran.node_geom)
                      OR ST_Intersects(ST_EndPoint(ran.road_geom), ran.node_geom)
                    THEN ran.road_geom
                    ELSE ST_Split(ran.road_geom, ran.node_geom)
                END
            )).geom
        ) parts
        WHERE ST_GeometryType(parts.geom) = 'ST_LineString'
          AND ST_Length(parts.geom) > metres(0.01)
          AND ST_Intersects(parts.geom, ran.node_geom)
    ) d
),
road_parts_with_dir AS (
    SELECT
        rp.node_id,
        rp.road_id,
        rp.geom,
        -- Local tangent of the part in its own drawn (ST_StartPoint -> ST_EndPoint) sense,
        -- regardless of whether the node is at its start or its end.
        CASE
            WHEN ST_Equals(ST_StartPoint(rp.geom), rp.node_geom)
            THEN ST_Azimuth(
                ST_PointN(rp.geom, 1),
                ST_PointN(rp.geom, LEAST(2, ST_NPoints(rp.geom)))
            )
            WHEN ST_Equals(ST_EndPoint(rp.geom), rp.node_geom)
            THEN ST_Azimuth(
                ST_PointN(rp.geom, GREATEST(1, ST_NPoints(rp.geom) - 1)),
                ST_PointN(rp.geom, ST_NPoints(rp.geom))
            )
            ELSE NULL::double precision
        END AS azimuth_forward
    FROM road_parts rp
    WHERE ST_NPoints(rp.geom) >= 2
),
segments_at_node AS (
    SELECT *
    FROM road_parts_with_dir
    WHERE azimuth_forward IS NOT NULL
),
-- Align every contributing segment to the same sense before averaging: pick one segment per
-- node (deterministically) as reference and flip any other segment by 180° if it points more
-- than 90° away from that reference. Segments that are genuinely part of the same drawn line
-- already agree and are left unchanged; this only corrects segments from a differently-drawn
-- way touching the same node.
segments_with_ref AS (
    SELECT
        s.*,
        FIRST_VALUE(s.azimuth_forward) OVER (
            PARTITION BY s.node_id
            ORDER BY s.road_id, ST_AsBinary(s.geom)
        ) AS ref_azimuth
    FROM segments_at_node s
),
segments_aligned AS (
    SELECT
        node_id,
        CASE
            WHEN ABS(ATAN2(
                SIN(azimuth_forward - ref_azimuth),
                COS(azimuth_forward - ref_azimuth)
            )) > pi() / 2
            THEN azimuth_forward + pi()
            ELSE azimuth_forward
        END AS azimuth_aligned
    FROM segments_with_ref
),
azimuth_per_node AS (
    SELECT
        node_id,
        CASE
            WHEN COUNT(*) = 1 THEN MAX(azimuth_aligned)
            ELSE ATAN2(AVG(SIN(azimuth_aligned)), AVG(COS(azimuth_aligned)))
        END AS road_azimuth
    FROM segments_aligned
    GROUP BY node_id
)
SELECT
    inp.node_id,
    inp.geom,
    az.road_azimuth
FROM _node_road_azimuth_input inp
LEFT JOIN azimuth_per_node az
  ON az.node_id = inp.node_id;

CREATE INDEX _node_road_azimuth_geom_idx
    ON _node_road_azimuth USING GIST (geom);
CREATE INDEX _node_road_azimuth_node_id_idx
    ON _node_road_azimuth (node_id);
