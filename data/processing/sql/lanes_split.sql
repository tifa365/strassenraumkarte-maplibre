----------------------------------------------------------------------
-- lanes_split.sql
-- Split imported lane centerlines to match highway_preparation segments.
-- Run after highway_preparation.sql, before lanes_spread_dual_carriageway.sql.
--
-- Each highway row has a unique segment_id (possibly multiple per osm_id).
-- Lane rows from OSM import still carry the full way geometry; here each
-- lane is clipped to the matching highway segment so downstream steps
-- join 1:1 on segment_id.
--
-- lanes_import keeps the original OSM-import geometry (see data_preparation.sh).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'lanes_import'
    ) THEN
        CREATE TABLE lanes_import AS SELECT * FROM lanes;
    END IF;
END $$;

DROP TABLE IF EXISTS lanes_split;

CREATE TABLE lanes_split AS
WITH lane_geoms AS (
    SELECT
        osm_id,
        lane_index,
        ST_LineMerge(ST_UnaryUnion(ST_Collect(geom))) AS merged_geom
    FROM lanes_import
    GROUP BY osm_id, lane_index
),
lane_attrs AS (
    SELECT DISTINCT ON (osm_id, lane_index)
        osm_id,
        highway,
        name,
        lane_index,
        type,
        class,
        direction,
        width,
        surface,
        turn,
        colour,
        marking_left,
        marking_right,
        separation_left,
        separation_right,
        buffer_left,
        buffer_right,
        traffic_mode_left,
        traffic_mode_right,
        hierarchy,
        layer,
        "lane_markings:junction",
        "offset",
        transition
    FROM lanes_import
    ORDER BY osm_id, lane_index, ST_Length(geom) DESC
),
lane_source AS (
    SELECT
        a.*,
        d.geom
    FROM lane_attrs a
    JOIN lane_geoms g
      ON g.osm_id = a.osm_id
     AND g.lane_index = a.lane_index
    CROSS JOIN LATERAL ST_Dump(
        CASE
            WHEN ST_GeometryType(g.merged_geom) = 'ST_MultiLineString'
            THEN g.merged_geom
            ELSE ST_Multi(g.merged_geom)
        END
    ) d
    WHERE ST_GeometryType(d.geom) = 'ST_LineString'
      AND ST_NPoints(d.geom) >= 2
),
clipped AS (
    SELECT
        h.segment_id,
        l.osm_id,
        l.highway,
        l.name,
        l.lane_index,
        l.type,
        l.class,
        l.direction,
        l.width,
        l.surface,
        l.turn,
        l.colour,
        l.marking_left,
        l.marking_right,
        l.separation_left,
        l.separation_right,
        l.buffer_left,
        l.buffer_right,
        l.traffic_mode_left,
        l.traffic_mode_right,
        l.hierarchy,
        l.layer,
        l."lane_markings:junction",
        l."offset",
        l.transition,
        ST_LineSubstring(
            l.geom,
            LEAST(
                ST_LineLocatePoint(l.geom, ST_StartPoint(h.geom)),
                ST_LineLocatePoint(l.geom, ST_EndPoint(h.geom))
            ),
            GREATEST(
                ST_LineLocatePoint(l.geom, ST_StartPoint(h.geom)),
                ST_LineLocatePoint(l.geom, ST_EndPoint(h.geom))
            )
        ) AS geom
    FROM lane_source l
    JOIN highway h ON h.osm_id = l.osm_id
    WHERE ST_NPoints(l.geom) >= 2
      AND ST_NPoints(h.geom) >= 2
)
SELECT *
FROM clipped
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString'
  AND ST_Length(geom) > metres(0.01);

DROP TABLE IF EXISTS lanes;
ALTER TABLE lanes_split RENAME TO lanes;

DROP INDEX IF EXISTS lanes_geom_idx;
DROP INDEX IF EXISTS lanes_segment_id_idx;
DROP INDEX IF EXISTS lanes_osm_id_lane_index_idx;
CREATE INDEX lanes_geom_idx ON lanes USING GIST (geom);
CREATE INDEX lanes_segment_id_idx ON lanes (segment_id);
CREATE INDEX lanes_osm_id_lane_index_idx ON lanes (osm_id, lane_index);
