-- Shared merge pipeline: temp _markings_raw → temp _markings_merged
-- Caller must populate temp table _markings_raw first.
-- Requires: processing/sql/params/params.sql loaded by caller.

----------------------------------------------------------------------
-- Merge connected marking lines for continuous rendering
--
-- After endpoint snapping, dissolve + line-merge connected segments into
-- longer continuous lines (per style attributes).
----------------------------------------------------------------------

-- Assign a stable per-segment id for neighborhood queries.
DROP TABLE IF EXISTS _markings_raw_seg;
CREATE TEMP TABLE _markings_raw_seg AS
SELECT
    row_number() OVER ()::bigint AS seg_id,
    *
FROM _markings_raw;

CREATE INDEX _markings_raw_seg_style_idx
    ON _markings_raw_seg (road_marking, type, side, stroke, width, arrow, colour, layer, preset_dasharray);

-- Materialize all segment endpoints and index them for fast local neighbor lookups.
DROP TABLE IF EXISTS _markings_endpoints;
CREATE TEMP TABLE _markings_endpoints AS
SELECT
    road_marking,
    seg_id,
    lane_width,
    layer,
    ST_StartPoint(geom)::geometry(Point) AS pt
FROM _markings_raw_seg
UNION ALL
SELECT
    road_marking,
    seg_id,
    lane_width,
    layer,
    ST_EndPoint(geom)::geometry(Point) AS pt
FROM _markings_raw_seg;

CREATE INDEX _markings_endpoints_road_marking_idx
    ON _markings_endpoints (road_marking);
CREATE INDEX _markings_endpoints_pt_idx
    ON _markings_endpoints USING GIST (pt);

DROP TABLE IF EXISTS _markings_merged;
CREATE TEMP TABLE _markings_merged AS
WITH snapped AS (
    SELECT
        s.seg_id,
        s.osm_id,
        s.road_marking,
        s.type,
        s.side,
        s.stroke,
        s.width,
        s.arrow,
        s.colour,
        s.layer,
        s.preset_dasharray,
        CASE
            WHEN t.targets IS NULL OR ST_IsEmpty(t.targets) THEN s.geom
            ELSE ST_Snap(s.geom, t.targets, metres(:'road_markings_dissolve_snap_tolerance'::numeric))
        END AS geom
    FROM _markings_raw_seg s
    LEFT JOIN LATERAL (
        SELECT
            ST_UnaryUnion(ST_Collect(pt)) AS targets
        FROM (
            -- Neighbors around the segment start point.
            SELECT e.pt
            FROM _markings_endpoints e
            WHERE e.road_marking = s.road_marking
              AND e.layer IS NOT DISTINCT FROM s.layer
              AND (
                (s.lane_width IS NOT NULL AND e.lane_width IS NOT NULL AND s.lane_width < e.lane_width)
                OR (
                  (s.lane_width IS NULL OR e.lane_width IS NULL OR s.lane_width = e.lane_width)
                  AND e.seg_id < s.seg_id
                )
              )
              AND ST_DWithin(e.pt, ST_StartPoint(s.geom), metres(:'road_markings_dissolve_snap_tolerance'::numeric))
              AND NOT ST_Equals(e.pt, ST_StartPoint(s.geom))

            UNION ALL

            -- Neighbors around the segment end point.
            SELECT e.pt
            FROM _markings_endpoints e
            WHERE e.road_marking = s.road_marking
              AND e.layer IS NOT DISTINCT FROM s.layer
              AND (
                (s.lane_width IS NOT NULL AND e.lane_width IS NOT NULL AND s.lane_width < e.lane_width)
                OR (
                  (s.lane_width IS NULL OR e.lane_width IS NULL OR s.lane_width = e.lane_width)
                  AND e.seg_id < s.seg_id
                )
              )
              AND ST_DWithin(e.pt, ST_EndPoint(s.geom), metres(:'road_markings_dissolve_snap_tolerance'::numeric))
              AND NOT ST_Equals(e.pt, ST_EndPoint(s.geom))
        ) q
    ) t ON true
),
dissolved AS (
    -- Merge all segments with the same style attributes (osm_id ignored).
    -- ST_LineMerge joins only geometrically connected parts.
    SELECT
        row_number() OVER (
            ORDER BY road_marking, type, side, stroke, width, arrow, colour, layer, preset_dasharray
        )::bigint AS style_group_id,
        road_marking,
        type,
        side,
        stroke,
        width,
        arrow,
        colour,
        layer,
        preset_dasharray,
        geom
    FROM (
        SELECT
            road_marking,
            type,
            side,
            stroke,
            width,
            arrow,
            colour,
            layer,
            preset_dasharray,
            CASE
                -- Turn-lane chains: preserve direction when merging adjacent segments.
                WHEN road_marking = 'turn_lane_chain'
                THEN ST_LineMerge(
                    ST_UnaryUnion(ST_Collect(geom)),
                    true
                )
                ELSE ST_LineMerge(
                    ST_UnaryUnion(ST_Collect(geom))
                )
            END AS geom
        FROM snapped
        GROUP BY road_marking, type, side, stroke, width, arrow, colour, layer, preset_dasharray
    ) grouped
),
components AS (
    SELECT
        d.style_group_id,
        d.road_marking,
        d.type,
        d.side,
        d.stroke,
        d.width,
        d.arrow,
        d.colour,
        d.layer,
        d.preset_dasharray,
        dp.path AS part_path,
        dp.geom::geometry(LineString) AS geom
    FROM dissolved d
    CROSS JOIN LATERAL ST_Dump(d.geom) AS dp
    WHERE dp.geom IS NOT NULL
      AND NOT ST_IsEmpty(dp.geom)
      AND ST_GeometryType(dp.geom) = 'ST_LineString'
),
attributed AS (
    -- Pick osm_id from the longest original segment fully contained in each component.
    SELECT DISTINCT ON (c.style_group_id, c.part_path)
        s.osm_id,
        c.road_marking,
        c.type,
        c.side,
        c.stroke,
        c.width,
        c.arrow,
        c.colour,
        c.layer,
        c.preset_dasharray,
        c.geom
    FROM components c
    INNER JOIN snapped s
        ON s.road_marking = c.road_marking
       AND s.type IS NOT DISTINCT FROM c.type
       AND s.side IS NOT DISTINCT FROM c.side
       AND s.stroke IS NOT DISTINCT FROM c.stroke
       AND s.width IS NOT DISTINCT FROM c.width
       AND s.arrow IS NOT DISTINCT FROM c.arrow
       AND s.colour IS NOT DISTINCT FROM c.colour
       AND s.layer IS NOT DISTINCT FROM c.layer
       AND s.preset_dasharray IS NOT DISTINCT FROM c.preset_dasharray
       AND c.geom && s.geom
       AND (
           ST_Covers(c.geom, s.geom)
           OR ST_Intersects(c.geom, s.geom)
       )
    ORDER BY
        c.style_group_id,
        c.part_path,
        CASE WHEN ST_Covers(c.geom, s.geom) THEN 1 ELSE 0 END DESC,
        ST_Length(s.geom) DESC,
        s.osm_id
)
SELECT
    osm_id,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    preset_dasharray,
    geom
FROM attributed
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString';

CREATE INDEX _markings_merged_geom_idx ON _markings_merged USING GIST (geom);
