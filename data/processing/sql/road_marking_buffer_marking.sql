-- road_marking_buffer_marking.sql — Buffer marking restriction areas at crossing nodes tagged
-- crossing:buffer_marking=left/right/both (painted kerb extensions at the road edge).
--
-- Depends on: highway_area (after highway_area_merge.sql); crossing (crossing:buffer_marking,
--             layer, temporary — osm_import.lua); highway (width_mapped — osm_import.lua);
--             barrier_node (osm_import.lua); lanes (type=bicycle/bus/vehicle, width, layer);
--             road_marking_polygon (existing osm_feature restriction areas for §9/§9d);
--             feature_polygon (osm_import.lua, for §12b punch-out);
--             crossing_marking_lines_clipped (road_marking_crossing.sql, for §17 zebra clip)
-- Output: road_marking_polygon (road_marking=restriction, class=buffer_marking, source=
--         crossing_attribute, pattern=stripes); merges overlapping restriction/barred_area
--         polygons of compatible pattern/layer/colour into a single polygon (source=
--         feature_merge when a merge mixes osm_feature and crossing_attribute polygons).
--         After that merge, every crossing:buffer_marking crossing line is also used to cut
--         a pedestrian "tunnel" (pattern=none) out of whichever final road_marking=
--         restriction/barred_area polygon(s) with pattern stripes or NULL it passes through —
--         freshly generated, pre-existing osm_feature, or feature_merge alike — and to place a road_marking_node
--         (road_marking=symbol, symbol=footway) at the tunnel's centre. Zebra/ladder stripe polygons
--         from road_marking_crossing.sql are regenerated in §17 (centerline clipped against
--         restriction areas first) wherever crossing:buffer_marking is set.
--         After §12 merge, generated restriction areas (crossing_attribute buffer
--         markings and feature_merge results that include at least one buffer marking
--         member) are punched with feature_polygon areas and with road_marking_polygon
--         areas that did not merge into the same cluster (e.g. pattern=zigzag).
--
-- Side convention: crossing:buffer_marking values left/right refer to the side of the road
-- relative to the road's own direction (road_azimuth), using the standard right-hand rule:
-- the right side lies in direction road_azimuth+90° from the crossing node, the left side in
-- direction road_azimuth-90°. The generated area always faces the road, i.e. perpendicular to
-- the back (kerb-side) edge and in the opposite direction of the side placement (right side
-- faces road_azimuth-90°, left side faces road_azimuth+90°).
--
-- Reference point relocation (§9b-§9f): if Half A at the kerb/road-edge position overlaps a
-- roughly parallel lane(type=bicycle), the reference point is moved lane.width/2 further
-- toward the road (past the cycleway); relocation always happens once such a conflict is
-- detected (no check against other lanes at the new position), unless it would create a
-- significant overlap with an existing osm_feature restriction area, in which case the
-- candidate is discarded entirely (no fallback). Relocated candidates only ever get Half A
-- (never Half B). Candidates without a detected conflict, or without a usable relocation
-- (no intersection point with the conflicting lane, or unknown lane width), keep the original
-- position and may still get Half B (§10).
--
-- highway_area clipping (§10/§10b): when the crossing node lies on a motorway/road highway
-- (not service-only), the marking is clipped to the union of all carriageway area(s) touched
-- by Half A (geom_a). Half A (+ Half B at the original position) is intersected with that
-- union; every resulting fragment on such a carriageway is kept (MultiPolygon when split
-- across several areas). Parts outside those carriageways are removed. Service-only crossings
-- get Half A alone, unclipped.
--
-- layer semantics: layer = NULL is treated as equivalent to layer = 0 everywhere in this
-- script (COALESCE(layer, 0) comparisons), so an unset layer matches an explicit layer = 0.
--
-- Footway cutout (§13-§16): runs after the §12 merge, against final road_marking=
-- restriction or barred_area polygons (any source) whose pattern is stripes or NULL. For each
-- (crossing_id, side), the crossing line (geom_extended) is buffered by half the crossing
-- way's mapped width (or buffer_marking_footway_cutout_default_width/2 as fallback) with
-- square end caps into a tunnel, which is intersected against every matching polygon it
-- overlaps (> sliver threshold). Each affected polygon is replaced by a striped remainder
-- (original pattern/attributes preserved) and a walkable-strip cutout fragment
-- (pattern=none); this always happens on geometric intersection. A footway symbol point
-- (road_marking_node) is placed at the midpoint of the crossing line's intersection with
-- the largest-overlap target polygon, oriented along the local crossing-line tangent there
-- (folded toward the road); it is only emitted when that point still lies within the
-- (pre-cutout) target polygon. Other patterns (x, zigzag, chevron, …) are left untouched.

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/highway_road_area.sql'


----------------------------------------------------------------------
-- §1) Filter crossing nodes tagged with crossing:buffer_marking
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_filtered;
CREATE TABLE buffer_marking_filtered AS
SELECT
    c.osm_type,
    c.osm_id,
    c.geom,
    c.layer,
    c.temporary,
    c."crossing:buffer_marking" AS buffer_marking
FROM crossing c
WHERE c."crossing:buffer_marking" IN ('left', 'right', 'both');

CREATE INDEX buffer_marking_filtered_geom_idx
    ON buffer_marking_filtered USING GIST (geom);
CREATE INDEX buffer_marking_filtered_osm_id_idx
    ON buffer_marking_filtered (osm_id);


----------------------------------------------------------------------
-- §2) Road azimuth via shared helper (motorway/road, service fallback)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _node_road_azimuth_input;
CREATE TEMP TABLE _node_road_azimuth_input AS
SELECT osm_id AS node_id, geom
FROM buffer_marking_filtered;

CREATE INDEX _node_road_azimuth_input_geom_idx
    ON _node_road_azimuth_input USING GIST (geom);
CREATE INDEX _node_road_azimuth_input_node_id_idx
    ON _node_road_azimuth_input (node_id);

\i 'processing/sql/helper/node_road_azimuth.sql'

DROP TABLE IF EXISTS buffer_marking_azimuth;
CREATE TABLE buffer_marking_azimuth AS
SELECT
    bmf.osm_type,
    bmf.osm_id,
    bmf.geom,
    bmf.layer,
    bmf.temporary,
    bmf.buffer_marking,
    na.road_azimuth AS road_azimuth,
    -- true when the crossing node sits on a motorway/road centreline (not service-only);
    -- used in §10/§10b to decide clipping and whether Half B is generated.
    EXISTS (
        SELECT 1
        FROM highway hr
        WHERE hr.geom && bmf.geom
          AND ST_Intersects(hr.geom, bmf.geom)
          AND hr.type IN ('road', 'motorway')
    ) AS on_road_highway
FROM buffer_marking_filtered bmf
JOIN _node_road_azimuth na
  ON na.node_id = bmf.osm_id
WHERE na.road_azimuth IS NOT NULL;

CREATE INDEX buffer_marking_azimuth_geom_idx
    ON buffer_marking_azimuth USING GIST (geom);
CREATE INDEX buffer_marking_azimuth_osm_id_idx
    ON buffer_marking_azimuth (osm_id);

DROP TABLE IF EXISTS _node_road_azimuth_input;
DROP TABLE IF EXISTS _node_road_azimuth;


----------------------------------------------------------------------
-- §3) Expand to one row per required side (left/right; both -> two rows)
--     ray_azimuth: direction from the node toward that side's kerb.
--     facing_azimuth: direction the generated area faces back toward the road
--     (opposite of ray_azimuth).
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_sides;
CREATE TABLE buffer_marking_sides AS
SELECT
    bma.osm_type,
    bma.osm_id,
    bma.geom AS node_geom,
    bma.layer,
    bma.temporary,
    bma.road_azimuth,
    bma.on_road_highway,
    side.side,
    (bma.road_azimuth + side.ray_offset) AS ray_azimuth,
    (bma.road_azimuth + side.ray_offset + pi()) AS facing_azimuth
FROM buffer_marking_azimuth bma
CROSS JOIN LATERAL (
    VALUES
        ('right'::text, pi() / 2.0),
        ('left'::text, -pi() / 2.0)
) AS side(side, ray_offset)
WHERE bma.buffer_marking = 'both'
   OR bma.buffer_marking = side.side;

CREATE INDEX buffer_marking_sides_geom_idx
    ON buffer_marking_sides USING GIST (node_geom);
CREATE INDEX buffer_marking_sides_crossing_side_idx
    ON buffer_marking_sides (osm_id, side);


----------------------------------------------------------------------
-- §4) Candidate path/footway crossing segments radiating from each node
--     (mirrors road_marking_crossing.sql §2), scored against each side's ray direction.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_path_segments;
CREATE TABLE buffer_marking_path_segments AS
WITH paths_at_node AS (
    SELECT
        bms.osm_id AS crossing_id,
        bms.side,
        bms.node_geom,
        bms.ray_azimuth,
        h.osm_id AS path_id,
        h.osm_type AS path_osm_type,
        h.geom AS path_geom
    FROM buffer_marking_sides bms
    JOIN highway h
      ON h.geom && bms.node_geom
     AND ST_Intersects(h.geom, bms.node_geom)
     AND h.type = 'path'
     AND h.class = 'crossing'
),
split_parts AS (
    SELECT
        pan.*,
        (d.geom)::geometry(LineString) AS seg_geom
    FROM paths_at_node pan
    CROSS JOIN LATERAL (
        SELECT geom
        FROM (
            SELECT (ST_Dump(
                CASE
                    WHEN ST_Intersects(ST_StartPoint(pan.path_geom), pan.node_geom)
                      OR ST_Intersects(ST_EndPoint(pan.path_geom), pan.node_geom)
                    THEN pan.path_geom
                    ELSE ST_Split(pan.path_geom, pan.node_geom)
                END
            )).geom
        ) parts
        WHERE ST_GeometryType(parts.geom) = 'ST_LineString'
          AND ST_Length(parts.geom) > metres(0.01)
          AND ST_Intersects(parts.geom, pan.node_geom)
    ) d
)
SELECT
    seg.*
FROM (
    SELECT
        sp.crossing_id,
        sp.side,
        sp.path_id,
        sp.path_osm_type,
        sp.ray_azimuth,
        sp.seg_geom,
        CASE
            WHEN ST_Equals(ST_StartPoint(sp.seg_geom), sp.node_geom)
            THEN ST_Azimuth(
                ST_PointN(sp.seg_geom, 1),
                ST_PointN(sp.seg_geom, LEAST(2, ST_NPoints(sp.seg_geom)))
            )
            WHEN ST_Equals(ST_EndPoint(sp.seg_geom), sp.node_geom)
            THEN ST_Azimuth(
                ST_PointN(sp.seg_geom, ST_NPoints(sp.seg_geom)),
                ST_PointN(sp.seg_geom, GREATEST(1, ST_NPoints(sp.seg_geom) - 1))
            )
            ELSE NULL::double precision
        END AS segment_azimuth
    FROM split_parts sp
    WHERE ST_NPoints(sp.seg_geom) >= 2
      AND (
          ST_Equals(ST_StartPoint(sp.seg_geom), sp.node_geom)
          OR ST_Equals(ST_EndPoint(sp.seg_geom), sp.node_geom)
      )
) seg
WHERE seg.segment_azimuth IS NOT NULL;

CREATE INDEX buffer_marking_path_segments_crossing_side_idx
    ON buffer_marking_path_segments (crossing_id, side);
CREATE INDEX buffer_marking_path_segments_geom_idx
    ON buffer_marking_path_segments USING GIST (seg_geom);

DROP TABLE IF EXISTS buffer_marking_path_segments_scored;
CREATE TABLE buffer_marking_path_segments_scored AS
SELECT
    bps.*,
    ABS(ATAN2(
        SIN(bps.segment_azimuth - bps.ray_azimuth),
        COS(bps.segment_azimuth - bps.ray_azimuth)
    )) AS angle_to_ray
FROM buffer_marking_path_segments bps;

CREATE INDEX buffer_marking_path_segments_scored_crossing_side_idx
    ON buffer_marking_path_segments_scored (crossing_id, side);

DROP TABLE IF EXISTS buffer_marking_best_segment;
CREATE TABLE buffer_marking_best_segment AS
SELECT *
FROM (
    SELECT
        bps.*,
        ROW_NUMBER() OVER (
            PARTITION BY bps.crossing_id, bps.side
            ORDER BY bps.angle_to_ray, bps.path_id
        ) AS rn
    FROM buffer_marking_path_segments_scored bps
    WHERE bps.angle_to_ray <= RADIANS(:'buffer_marking_side_match_angle_max'::double precision)
) ranked
WHERE rn = 1;

CREATE INDEX buffer_marking_best_segment_crossing_side_idx
    ON buffer_marking_best_segment (crossing_id, side);


----------------------------------------------------------------------
-- §5) Build the ray per (crossing, side): prefer an existing crossing path segment,
--     otherwise a generic line projected perpendicular to the road (mirrors
--     road_marking_crossing.sql §3 crossing_generic).
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_rays;
CREATE TABLE buffer_marking_rays AS
SELECT
    bms.osm_type,
    bms.osm_id AS crossing_id,
    bms.node_geom,
    bms.layer,
    bms.temporary,
    bms.side,
    bms.road_azimuth,
    bms.facing_azimuth,
    -- Normalize direction so the ray always starts at the node: seg_geom is a raw
    -- ST_Split() fragment and may have the node at either its start or end. Without
    -- this, ST_LineExtend (§6, "forward" only) would sometimes extend past the node
    -- instead of away from it, pulling the reference point (§7) to the wrong side.
    CASE
        WHEN ST_Equals(ST_StartPoint(bs.seg_geom), bms.node_geom)
        THEN bs.seg_geom
        ELSE ST_Reverse(bs.seg_geom)
    END AS ray_geom,
    true AS from_existing_segment
FROM buffer_marking_sides bms
JOIN buffer_marking_best_segment bs
  ON bs.crossing_id = bms.osm_id
 AND bs.side = bms.side

UNION ALL

SELECT
    bms.osm_type,
    bms.osm_id AS crossing_id,
    bms.node_geom,
    bms.layer,
    bms.temporary,
    bms.side,
    bms.road_azimuth,
    bms.facing_azimuth,
    ST_MakeLine(
        bms.node_geom,
        ST_Project(bms.node_geom, metres((rw.width / 2.0) + 1.0), bms.ray_azimuth)
    ) AS ray_geom,
    false AS from_existing_segment
FROM buffer_marking_sides bms
CROSS JOIN LATERAL (
    SELECT COALESCE(
        (
            SELECT MAX(hp.width)
            FROM highway hp
            WHERE hp.type = 'path'
              AND hp.geom && bms.node_geom
              AND ST_Intersects(hp.geom, bms.node_geom)
              AND hp.width IS NOT NULL
        ),
        :'crossing_default_width'::double precision
    ) AS width
) rw
WHERE NOT EXISTS (
    SELECT 1
    FROM buffer_marking_best_segment bs
    WHERE bs.crossing_id = bms.osm_id
      AND bs.side = bms.side
);

CREATE INDEX buffer_marking_rays_geom_idx
    ON buffer_marking_rays USING GIST (ray_geom);
CREATE INDEX buffer_marking_rays_crossing_side_idx
    ON buffer_marking_rays (crossing_id, side);


----------------------------------------------------------------------
-- §6) Kerb-bounded check + extension (mirrors road_marking_crossing.sql §5).
--     The ray's far end (away from the node) is extended by crossing_extend unless it
--     already sits on a barrier_node(barrier=kerb) — then it is already the kerb point.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_rays_extended;
CREATE TABLE buffer_marking_rays_extended AS
SELECT
    br.osm_type,
    br.crossing_id,
    br.node_geom,
    br.layer,
    br.temporary,
    br.side,
    br.road_azimuth,
    br.facing_azimuth,
    dumped.line_geom,
    dumped.is_kerb_bounded,
    CASE
        WHEN dumped.is_kerb_bounded THEN dumped.line_geom
        ELSE ST_LineExtend(dumped.line_geom, metres(:'crossing_extend'::double precision), 0.0)
    END AS geom_extended
FROM buffer_marking_rays br
CROSS JOIN LATERAL (
    SELECT
        (d.geom)::geometry(LineString) AS line_geom,
        EXISTS (
            SELECT 1
            FROM barrier_node bn
            WHERE bn.barrier = 'kerb'
              AND ST_Intersects(bn.geom, ST_EndPoint((d.geom)::geometry(LineString)))
        ) AS is_kerb_bounded
    FROM ST_Dump(br.ray_geom) AS d
    WHERE br.ray_geom IS NOT NULL
      AND NOT ST_IsEmpty(br.ray_geom)
      AND ST_GeometryType(d.geom) = 'ST_LineString'
      AND ST_Length(d.geom) > metres(0.01)
) dumped;

CREATE INDEX buffer_marking_rays_extended_geom_idx
    ON buffer_marking_rays_extended USING GIST (geom_extended);
CREATE INDEX buffer_marking_rays_extended_crossing_side_idx
    ON buffer_marking_rays_extended (crossing_id, side);


----------------------------------------------------------------------
-- §7) Reference point: where the ray meets the road edge (kerb line, or the outer
--     boundary of the highway_area at that location). Mirrors road_marking_crossing.sql
--     §7b clipping against highway_area, restricted to genuine carriageway areas.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_reference_points;
CREATE TABLE buffer_marking_reference_points AS
-- kerb-bounded: the ray's far endpoint already is the kerb point
SELECT
    bre.osm_type,
    bre.crossing_id,
    bre.layer,
    bre.temporary,
    bre.side,
    bre.road_azimuth,
    bre.facing_azimuth,
    ST_EndPoint(bre.line_geom) AS ref_geom
FROM buffer_marking_rays_extended bre
WHERE bre.is_kerb_bounded

UNION ALL

-- generic case: clip the extended ray at the highway_area boundary, take the far end
SELECT
    bre.osm_type,
    bre.crossing_id,
    bre.layer,
    bre.temporary,
    bre.side,
    bre.road_azimuth,
    bre.facing_azimuth,
    CASE
        WHEN ST_Distance(ST_StartPoint((frag).geom), bre.node_geom)
           > ST_Distance(ST_EndPoint((frag).geom), bre.node_geom)
        THEN ST_StartPoint((frag).geom)
        ELSE ST_EndPoint((frag).geom)
    END AS ref_geom
FROM buffer_marking_rays_extended bre
CROSS JOIN LATERAL (
    SELECT ST_Union(ha.geom) AS union_geom
    FROM highway_area ha
    WHERE ha.geom && bre.geom_extended
      AND ST_Intersects(ha.geom, bre.geom_extended)
      AND COALESCE(ha.layer, 0) = COALESCE(bre.layer, 0)
      AND EXISTS (
          SELECT 1
          FROM _highway_road_area rh
          WHERE rh.area_highway = ha."area:highway"
      )
) areas
CROSS JOIN LATERAL ST_Dump(
    ST_Intersection(bre.geom_extended, areas.union_geom)
) AS frag
WHERE NOT bre.is_kerb_bounded
  AND areas.union_geom IS NOT NULL
  AND NOT ST_IsEmpty(areas.union_geom)
  AND (frag).geom IS NOT NULL
  AND NOT ST_IsEmpty((frag).geom)
  AND ST_GeometryType((frag).geom) = 'ST_LineString'
  AND ST_Length((frag).geom) > metres(0.01)
  AND ST_DWithin((frag).geom, bre.node_geom, metres(0.01));

CREATE INDEX buffer_marking_reference_points_geom_idx
    ON buffer_marking_reference_points USING GIST (ref_geom);
CREATE INDEX buffer_marking_reference_points_crossing_side_idx
    ON buffer_marking_reference_points (crossing_id, side);


----------------------------------------------------------------------
-- §8) Half A: trapezoid. Back edge through the reference point, along road_azimuth,
--     length buffer_marking_back_edge_length; front edge offset by buffer_marking_depth
--     toward the road (facing_azimuth), length buffer_marking_front_edge_length.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_half_a;
CREATE TABLE buffer_marking_half_a AS
SELECT
    brp.osm_type,
    brp.crossing_id,
    brp.layer,
    brp.temporary,
    brp.side,
    brp.ref_geom,
    brp.facing_azimuth,
    brp.road_azimuth,
    pts.b1,
    pts.b2,
    (ST_MakePolygon(
        ST_MakeLine(ARRAY[pts.b1, pts.f1, pts.f2, pts.b2, pts.b1])
    ))::geometry(Polygon) AS geom_a
FROM buffer_marking_reference_points brp
CROSS JOIN LATERAL (
    SELECT
        ST_Project(
            brp.ref_geom,
            metres(:'buffer_marking_back_edge_length'::double precision) / 2.0,
            brp.road_azimuth
        ) AS b1,
        ST_Project(
            brp.ref_geom,
            metres(:'buffer_marking_back_edge_length'::double precision) / 2.0,
            brp.road_azimuth + pi()
        ) AS b2,
        ST_Project(
            ST_Project(brp.ref_geom, metres(:'buffer_marking_depth'::double precision), brp.facing_azimuth),
            metres(:'buffer_marking_front_edge_length'::double precision) / 2.0,
            brp.road_azimuth
        ) AS f1,
        ST_Project(
            ST_Project(brp.ref_geom, metres(:'buffer_marking_depth'::double precision), brp.facing_azimuth),
            metres(:'buffer_marking_front_edge_length'::double precision) / 2.0,
            brp.road_azimuth + pi()
        ) AS f2
) pts;

CREATE INDEX buffer_marking_half_a_geom_idx
    ON buffer_marking_half_a USING GIST (geom_a);


----------------------------------------------------------------------
-- §9) Discard candidates whose trapezoid (Half A) overlaps an existing OSM-mapped
--     restriction area (source=osm_feature) by more than buffer_marking_osm_feature_
--     overlap_max_m2 — the buffer marking is already explicitly mapped in that case.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_half_a_accepted;
CREATE TABLE buffer_marking_half_a_accepted AS
SELECT bha.*
FROM buffer_marking_half_a bha
CROSS JOIN LATERAL (
    SELECT ST_Union(rmp.geom) AS union_geom
    FROM road_marking_polygon rmp
    WHERE rmp.geom && bha.geom_a
      AND rmp.source = 'osm_feature'
      AND rmp.road_marking = 'restriction'
      AND COALESCE(rmp.layer, 0) = COALESCE(bha.layer, 0)
      AND ST_Intersects(rmp.geom, bha.geom_a)
) feat
WHERE feat.union_geom IS NULL
   OR ST_Area(ST_Intersection(bha.geom_a, feat.union_geom))
      <= :'buffer_marking_osm_feature_overlap_max_m2'::double precision;

CREATE INDEX buffer_marking_half_a_accepted_geom_idx
    ON buffer_marking_half_a_accepted USING GIST (geom_a);


----------------------------------------------------------------------
-- §9b) Bicycle-lane conflict check: does Half A (at the original kerb/road-edge
--      position) intersect a lane(type=bicycle) that runs roughly parallel to the road
--      (undirected angle to road_azimuth <= buffer_marking_bicycle_azimuth_tolerance)?
--      If several such lanes intersect, the one closest to ref_geom is used.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_bicycle_conflict;
CREATE TABLE buffer_marking_bicycle_conflict AS
SELECT
    bha.*,
    conflict.lane_osm_id AS conflict_lane_osm_id,
    conflict.lane_index AS conflict_lane_index,
    conflict.lane_width AS conflict_lane_width,
    (conflict.lane_osm_id IS NOT NULL) AS has_bicycle_conflict
FROM buffer_marking_half_a_accepted bha
LEFT JOIN LATERAL (
    -- (osm_id, lane_index) is the lanes table's unique key (a way can carry several
    -- lane rows); both are carried through so §9c can re-select this exact lane.
    SELECT
        l.osm_id AS lane_osm_id,
        l.lane_index AS lane_index,
        l.width AS lane_width
    FROM lanes l
    CROSS JOIN LATERAL (
        -- lane azimuth via two closely-spaced interpolated points (mirrors
        -- road_marking_barred_area.sql), then folded to an undirected angle
        -- so a lane running "with" or "against" the road both count as parallel
        SELECT
            ABS(ATAN2(
                SIN(ST_Azimuth(
                    ST_LineInterpolatePoint(l.geom, GREATEST(0.0, LEAST(1.0, 0.5 - 0.01))),
                    ST_LineInterpolatePoint(l.geom, GREATEST(0.0, LEAST(1.0, 0.5 + 0.01)))
                ) - bha.road_azimuth),
                COS(ST_Azimuth(
                    ST_LineInterpolatePoint(l.geom, GREATEST(0.0, LEAST(1.0, 0.5 - 0.01))),
                    ST_LineInterpolatePoint(l.geom, GREATEST(0.0, LEAST(1.0, 0.5 + 0.01)))
                ) - bha.road_azimuth)
            )) AS raw_diff
    ) d
    CROSS JOIN LATERAL (
        SELECT
            CASE WHEN d.raw_diff > pi() / 2.0 THEN pi() - d.raw_diff ELSE d.raw_diff END
                AS undirected_diff
    ) ud
    WHERE l.type = 'bicycle'
      AND l.geom && bha.geom_a
      AND ST_Length(l.geom) > metres(0.02)
      AND ST_Intersects(l.geom, bha.geom_a)
      AND COALESCE(l.layer, 0) = COALESCE(bha.layer, 0)
      AND ud.undirected_diff <= RADIANS(:'buffer_marking_bicycle_azimuth_tolerance'::double precision)
    ORDER BY ST_Distance(l.geom, bha.ref_geom)
    LIMIT 1
) conflict ON true;

CREATE INDEX buffer_marking_bicycle_conflict_geom_idx
    ON buffer_marking_bicycle_conflict USING GIST (geom_a);
CREATE INDEX buffer_marking_bicycle_conflict_crossing_side_idx
    ON buffer_marking_bicycle_conflict (crossing_id, side);


----------------------------------------------------------------------
-- §9c) Relocated Half A: for conflicted candidates, find where a short search line
--      (from the original ref_geom toward the road) crosses the conflicting bicycle
--      lane, then offset the new reference point by lane.width / 2 further toward the
--      road. A fresh trapezoid (identical construction to §8) is built at this point.
--      Candidates without a usable intersection point or NULL lane width simply yield
--      no row here and fall back to the original position (§9f).
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_relocation_candidates;
CREATE TABLE buffer_marking_relocation_candidates AS
SELECT
    bbc.osm_type,
    bbc.crossing_id,
    bbc.layer,
    bbc.temporary,
    bbc.side,
    bbc.facing_azimuth,
    bbc.road_azimuth,
    new_pts.new_ref_geom AS ref_geom,
    new_pts.b1,
    new_pts.b2,
    (ST_MakePolygon(
        ST_MakeLine(ARRAY[new_pts.b1, new_pts.f1, new_pts.f2, new_pts.b2, new_pts.b1])
    ))::geometry(Polygon) AS geom_a
FROM buffer_marking_bicycle_conflict bbc
JOIN lanes l
  ON l.osm_id = bbc.conflict_lane_osm_id
 AND l.lane_index = bbc.conflict_lane_index
CROSS JOIN LATERAL (
    SELECT
        ST_MakeLine(
            bbc.ref_geom,
            ST_Project(
                bbc.ref_geom,
                metres(:'buffer_marking_bicycle_search_length'::double precision),
                bbc.facing_azimuth
            )
        ) AS search_line
) sl
CROSS JOIN LATERAL (
    -- nearest intersection point of the search line with the conflicting lane
    SELECT (dp.geom)::geometry(Point) AS pt
    FROM ST_Dump(ST_Intersection(sl.search_line, l.geom)) dp
    WHERE ST_GeometryType(dp.geom) = 'ST_Point'
    ORDER BY ST_Distance(dp.geom, bbc.ref_geom)
    LIMIT 1
) ip
CROSS JOIN LATERAL (
    SELECT ST_Project(ip.pt, metres(bbc.conflict_lane_width) / 2.0, bbc.facing_azimuth) AS new_ref_geom
) newref
CROSS JOIN LATERAL (
    SELECT
        ST_Project(
            newref.new_ref_geom,
            metres(:'buffer_marking_back_edge_length'::double precision) / 2.0,
            bbc.road_azimuth
        ) AS b1,
        ST_Project(
            newref.new_ref_geom,
            metres(:'buffer_marking_back_edge_length'::double precision) / 2.0,
            bbc.road_azimuth + pi()
        ) AS b2,
        ST_Project(
            ST_Project(newref.new_ref_geom, metres(:'buffer_marking_depth'::double precision), bbc.facing_azimuth),
            metres(:'buffer_marking_front_edge_length'::double precision) / 2.0,
            bbc.road_azimuth
        ) AS f1,
        ST_Project(
            ST_Project(newref.new_ref_geom, metres(:'buffer_marking_depth'::double precision), bbc.facing_azimuth),
            metres(:'buffer_marking_front_edge_length'::double precision) / 2.0,
            bbc.road_azimuth + pi()
        ) AS f2,
        newref.new_ref_geom AS new_ref_geom
) new_pts
WHERE bbc.has_bicycle_conflict
  AND bbc.conflict_lane_width IS NOT NULL;

CREATE INDEX buffer_marking_relocation_candidates_geom_idx
    ON buffer_marking_relocation_candidates USING GIST (geom_a);
CREATE INDEX buffer_marking_relocation_candidates_crossing_side_idx
    ON buffer_marking_relocation_candidates (crossing_id, side);


----------------------------------------------------------------------
-- §9d) OSM-overlap check at the relocated position (same threshold/logic as §9). A
--      significant overlap here means the buffer marking is discarded entirely — no
--      fallback to the original position.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_relocation_discarded;
CREATE TABLE buffer_marking_relocation_discarded AS
SELECT rc.crossing_id, rc.side
FROM buffer_marking_relocation_candidates rc
CROSS JOIN LATERAL (
    SELECT ST_Union(rmp.geom) AS union_geom
    FROM road_marking_polygon rmp
    WHERE rmp.geom && rc.geom_a
      AND rmp.source = 'osm_feature'
      AND rmp.road_marking = 'restriction'
      AND COALESCE(rmp.layer, 0) = COALESCE(rc.layer, 0)
      AND ST_Intersects(rmp.geom, rc.geom_a)
) feat
WHERE feat.union_geom IS NOT NULL
  AND ST_Area(ST_Intersection(rc.geom_a, feat.union_geom))
      > :'buffer_marking_osm_feature_overlap_max_m2'::double precision;

CREATE INDEX buffer_marking_relocation_discarded_crossing_side_idx
    ON buffer_marking_relocation_discarded (crossing_id, side);

DROP TABLE IF EXISTS buffer_marking_relocation_ok_overlap;
CREATE TABLE buffer_marking_relocation_ok_overlap AS
SELECT rc.*
FROM buffer_marking_relocation_candidates rc
WHERE NOT EXISTS (
    SELECT 1
    FROM buffer_marking_relocation_discarded rd
    WHERE rd.crossing_id = rc.crossing_id
      AND rd.side = rc.side
);

CREATE INDEX buffer_marking_relocation_ok_overlap_geom_idx
    ON buffer_marking_relocation_ok_overlap USING GIST (geom_a);
CREATE INDEX buffer_marking_relocation_ok_overlap_crossing_side_idx
    ON buffer_marking_relocation_ok_overlap (crossing_id, side);


----------------------------------------------------------------------
-- §9e) Relocated candidates that survive the OSM-overlap check (§9d) are always used
--      as-is — no additional check against other lanes (bicycle/bus/vehicle) at the
--      relocated position. A detected parallel-cycle-lane conflict (§9b) always leads
--      to relocation, even if the new position happens to be tight against (or overlap
--      with) a neighbouring carriageway lane; there is no fallback to the kerb position
--      in that case.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_relocated_final;
CREATE TABLE buffer_marking_relocated_final AS
SELECT * FROM buffer_marking_relocation_ok_overlap;

CREATE INDEX buffer_marking_relocated_final_geom_idx
    ON buffer_marking_relocated_final USING GIST (geom_a);
CREATE INDEX buffer_marking_relocated_final_crossing_side_idx
    ON buffer_marking_relocated_final (crossing_id, side);


----------------------------------------------------------------------
-- §9f) Candidates that keep the original kerb/road-edge position: no bicycle-lane
--      conflict, or no usable relocation (no intersection point with the conflicting
--      lane, or its width is unknown) — and not discarded for OSM overlap at the
--      relocated position.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_half_a_original;
CREATE TABLE buffer_marking_half_a_original AS
SELECT bha.*
FROM buffer_marking_half_a_accepted bha
WHERE NOT EXISTS (
    SELECT 1
    FROM buffer_marking_relocated_final rf
    WHERE rf.crossing_id = bha.crossing_id
      AND rf.side = bha.side
)
AND NOT EXISTS (
    SELECT 1
    FROM buffer_marking_relocation_discarded rd
    WHERE rd.crossing_id = bha.crossing_id
      AND rd.side = bha.side
);

CREATE INDEX buffer_marking_half_a_original_geom_idx
    ON buffer_marking_half_a_original USING GIST (geom_a);


----------------------------------------------------------------------
-- §10) highway_area clipping for the original-position branch: when the crossing node
--      lies on a motorway/road highway, Half B is added and the union is clipped to all
--      carriageway area(s) touched by Half A. Service-only crossings get Half A alone,
--      unclipped.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_original_area_check;
CREATE TABLE buffer_marking_original_area_check AS
SELECT
    bha.*,
    bms.on_road_highway,
    areas.union_geom AS highway_area_union
FROM buffer_marking_half_a_original bha
JOIN buffer_marking_sides bms
  ON bms.osm_id = bha.crossing_id
 AND bms.side = bha.side
CROSS JOIN LATERAL (
    SELECT ST_Union(ha.geom) AS union_geom
    FROM highway_area ha
    WHERE ha.geom && bha.geom_a
      AND ST_Intersects(ha.geom, bha.geom_a)
      AND COALESCE(ha.layer, 0) = COALESCE(bha.layer, 0)
      AND EXISTS (SELECT 1 FROM _highway_road_area rh WHERE rh.area_highway = ha."area:highway")
) areas;

CREATE INDEX buffer_marking_original_area_check_geom_idx
    ON buffer_marking_original_area_check USING GIST (geom_a);

DROP TABLE IF EXISTS buffer_marking_polygons_original;
CREATE TABLE buffer_marking_polygons_original AS
-- branch F: crossing on motorway/road -> Half A + Half B, unioned and clipped to highway_area.
-- The Half B cut plane is shifted 0.1 m toward the road so it overlaps Half A
-- slightly and ST_Union does not leave hairline gaps.
SELECT
    oac.osm_type,
    oac.crossing_id,
    oac.layer,
    CASE
        WHEN oac.temporary = 'yes' THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    MOD(ROUND(DEGREES(oac.road_azimuth))::integer - 45 + 3600, 360)::real AS direction,
    cleaned.geom
FROM buffer_marking_original_area_check oac
CROSS JOIN LATERAL (
    SELECT
        ST_Project(oac.b1, metres(0.1), oac.facing_azimuth) AS cut_b1,
        ST_Project(oac.b2, metres(0.1), oac.facing_azimuth) AS cut_b2
) cut
CROSS JOIN LATERAL (
    -- half-plane covering the side of the cut line opposite the trapezoid
    SELECT
        ST_Intersection(
            ST_Buffer(oac.ref_geom, metres(:'buffer_marking_back_edge_length'::double precision) / 2.0, 16),
            ST_MakePolygon(ST_MakeLine(ARRAY[
                cut.cut_b1,
                cut.cut_b2,
                ST_Project(
                    cut.cut_b2,
                    metres(:'buffer_marking_back_edge_length'::double precision / 2.0 + 1.0),
                    oac.facing_azimuth + pi()
                ),
                ST_Project(
                    cut.cut_b1,
                    metres(:'buffer_marking_back_edge_length'::double precision / 2.0 + 1.0),
                    oac.facing_azimuth + pi()
                ),
                cut.cut_b1
            ]))
        ) AS geom_b
) half_b
CROSS JOIN LATERAL (
    SELECT ST_Buffer(ST_Union(oac.geom_a, half_b.geom_b), 0) AS unioned
) merged
CROSS JOIN LATERAL (
    SELECT ST_Intersection(merged.unioned, oac.highway_area_union) AS clipped
) clipped_geom
CROSS JOIN LATERAL (
    SELECT ST_Multi(clipped_geom.clipped)::geometry(MultiPolygon) AS geom
) cleaned
WHERE oac.on_road_highway
  AND oac.highway_area_union IS NOT NULL
  AND NOT ST_IsEmpty(oac.highway_area_union)
  AND merged.unioned IS NOT NULL
  AND NOT ST_IsEmpty(merged.unioned)
  AND clipped_geom.clipped IS NOT NULL
  AND NOT ST_IsEmpty(clipped_geom.clipped)

UNION ALL

-- branch G: service-only crossing (no motorway/road at node) -> Half A alone, unclipped.
SELECT
    oac.osm_type,
    oac.crossing_id,
    oac.layer,
    CASE
        WHEN oac.temporary = 'yes' THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    MOD(ROUND(DEGREES(oac.road_azimuth))::integer - 45 + 3600, 360)::real AS direction,
    oac.geom_a::geometry(Polygon) AS geom
FROM buffer_marking_original_area_check oac
WHERE NOT oac.on_road_highway;

CREATE INDEX buffer_marking_polygons_original_geom_idx
    ON buffer_marking_polygons_original USING GIST (geom);


----------------------------------------------------------------------
-- §10b) highway_area clipping for the relocated branch: only Half A is ever used here
--      (never Half B). When the crossing node lies on motorway/road, Half A is clipped
--      to all carriageway area(s) touched by Half A; service-only crossings stay unclipped.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_relocated_area_check;
CREATE TABLE buffer_marking_relocated_area_check AS
SELECT
    rf.*,
    bms.on_road_highway,
    areas.union_geom AS highway_area_union
FROM buffer_marking_relocated_final rf
JOIN buffer_marking_sides bms
  ON bms.osm_id = rf.crossing_id
 AND bms.side = rf.side
CROSS JOIN LATERAL (
    SELECT ST_Union(ha.geom) AS union_geom
    FROM highway_area ha
    WHERE ha.geom && rf.geom_a
      AND ST_Intersects(ha.geom, rf.geom_a)
      AND COALESCE(ha.layer, 0) = COALESCE(rf.layer, 0)
      AND EXISTS (SELECT 1 FROM _highway_road_area rh WHERE rh.area_highway = ha."area:highway")
) areas;

CREATE INDEX buffer_marking_relocated_area_check_geom_idx
    ON buffer_marking_relocated_area_check USING GIST (geom_a);

DROP TABLE IF EXISTS buffer_marking_polygons_relocated;
CREATE TABLE buffer_marking_polygons_relocated AS
-- branch I: crossing on motorway/road -> Half A clipped to highway_area.
SELECT
    rac.osm_type,
    rac.crossing_id,
    rac.layer,
    CASE
        WHEN rac.temporary = 'yes' THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    MOD(ROUND(DEGREES(rac.road_azimuth))::integer - 45 + 3600, 360)::real AS direction,
    cleaned.geom
FROM buffer_marking_relocated_area_check rac
CROSS JOIN LATERAL (
    SELECT ST_Intersection(rac.geom_a, rac.highway_area_union) AS clipped
) clipped_geom
CROSS JOIN LATERAL (
    SELECT ST_Multi(clipped_geom.clipped)::geometry(MultiPolygon) AS geom
) cleaned
WHERE rac.on_road_highway
  AND rac.highway_area_union IS NOT NULL
  AND NOT ST_IsEmpty(rac.highway_area_union)
  AND clipped_geom.clipped IS NOT NULL
  AND NOT ST_IsEmpty(clipped_geom.clipped)

UNION ALL

-- branch J: service-only crossing -> Half A alone, unclipped.
SELECT
    rac.osm_type,
    rac.crossing_id,
    rac.layer,
    CASE
        WHEN rac.temporary = 'yes' THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    MOD(ROUND(DEGREES(rac.road_azimuth))::integer - 45 + 3600, 360)::real AS direction,
    rac.geom_a::geometry(Polygon) AS geom
FROM buffer_marking_relocated_area_check rac
WHERE NOT rac.on_road_highway;

CREATE INDEX buffer_marking_polygons_relocated_geom_idx
    ON buffer_marking_polygons_relocated USING GIST (geom);


----------------------------------------------------------------------
-- §10c) Combine the original-position and relocated-position branches into the final
--      set of buffer marking polygons.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_polygons;
CREATE TABLE buffer_marking_polygons AS
SELECT * FROM buffer_marking_polygons_original
UNION ALL
SELECT * FROM buffer_marking_polygons_relocated;

CREATE INDEX buffer_marking_polygons_geom_idx
    ON buffer_marking_polygons USING GIST (geom);


----------------------------------------------------------------------
-- §11) INSERT buffer marking polygons (stripes) into road_marking_polygon. The footway
--      cutout (tunnel through the crossing line, symbol point) is applied afterwards, in
--      §13-§16, against the final merged set of restriction polygons — see there.
----------------------------------------------------------------------

INSERT INTO road_marking_polygon (
    source, road_marking, stroke, dasharray, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
)
SELECT
    'crossing_attribute'::text,
    'restriction'::text,
    NULL::text,
    NULL::text,
    'stripes'::text,
    NULL::text,
    NULL::text,
    NULL::real,
    NULL::real,
    bmp.colour,
    bmp.direction,
    'crossing'::text,
    'buffer_marking'::text,
    bmp.layer,
    bmp.osm_type,
    bmp.crossing_id,
    bmp.geom
FROM buffer_marking_polygons bmp
WHERE bmp.geom IS NOT NULL
  AND NOT ST_IsEmpty(bmp.geom);


----------------------------------------------------------------------
-- §12) Merge overlapping restriction/barred_area polygons of compatible pattern (equal,
--      or either NULL — NULL acts as a wildcard), equal layer and equal colour. Connected
--      components (transitive overlap) are unioned into a single polygon; attributes
--      are taken from the largest individual member; source becomes 'feature_merge'
--      when a merged group mixes osm_feature and crossing_attribute polygons.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_merge_candidates;
CREATE TABLE buffer_marking_merge_candidates AS
SELECT
    row_number() OVER ()::bigint AS poly_id,
    ctid AS orig_ctid,
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
    osm_type,
    osm_id,
    geom
FROM road_marking_polygon
WHERE road_marking IN ('restriction', 'barred_area')
  AND pattern IS DISTINCT FROM 'none'
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);

CREATE INDEX buffer_marking_merge_candidates_geom_idx
    ON buffer_marking_merge_candidates USING GIST (geom);
CREATE INDEX buffer_marking_merge_candidates_poly_id_idx
    ON buffer_marking_merge_candidates (poly_id);
CREATE INDEX buffer_marking_merge_candidates_style_idx
    ON buffer_marking_merge_candidates (layer, colour, pattern);

DROP TABLE IF EXISTS buffer_marking_merge_groups;
CREATE TABLE buffer_marking_merge_groups AS
WITH RECURSIVE
merge_pairs AS (
    SELECT
        a.poly_id AS id_a,
        b.poly_id AS id_b
    FROM buffer_marking_merge_candidates a
    INNER JOIN buffer_marking_merge_candidates b
        ON a.poly_id < b.poly_id
       AND COALESCE(a.layer, 0) = COALESCE(b.layer, 0)
       AND a.colour IS NOT DISTINCT FROM b.colour
       AND (
           a.pattern IS NOT DISTINCT FROM b.pattern
           OR a.pattern IS NULL
           OR b.pattern IS NULL
       )
       AND a.geom && b.geom
       AND ST_Intersects(a.geom, b.geom)
),
merge_edges AS (
    SELECT id_a AS node, id_b AS neighbor FROM merge_pairs
    UNION ALL
    SELECT id_b, id_a FROM merge_pairs
),
walk AS (
    SELECT poly_id AS node, poly_id AS root
    FROM buffer_marking_merge_candidates
    UNION
    SELECT e.neighbor, w.root
    FROM walk w
    INNER JOIN merge_edges e ON w.node = e.node
),
comp AS (
    SELECT node, MIN(root) AS cluster_id
    FROM walk
    GROUP BY node
)
SELECT
    c.cluster_id,
    m.poly_id,
    m.orig_ctid,
    m.source,
    m.road_marking,
    m.stroke,
    m.dasharray,
    m.pattern,
    m.arrow,
    m.symbol,
    m.width,
    m.length,
    m.colour,
    m.direction,
    m.type,
    m.class,
    m.layer,
    m.osm_type,
    m.osm_id,
    m.geom,
    ST_Area(m.geom) AS area
FROM buffer_marking_merge_candidates m
INNER JOIN comp c ON c.node = m.poly_id;

CREATE INDEX buffer_marking_merge_groups_cluster_idx
    ON buffer_marking_merge_groups (cluster_id);

-- Only clusters with more than one member require merging.
DROP TABLE IF EXISTS buffer_marking_merge_multi;
CREATE TABLE buffer_marking_merge_multi AS
SELECT cluster_id
FROM buffer_marking_merge_groups
GROUP BY cluster_id
HAVING COUNT(*) > 1;

CREATE INDEX buffer_marking_merge_multi_idx
    ON buffer_marking_merge_multi (cluster_id);

DROP TABLE IF EXISTS buffer_marking_merge_result;
CREATE TABLE buffer_marking_merge_result AS
WITH attr_winners AS (
    SELECT DISTINCT ON (g.cluster_id)
        g.cluster_id,
        g.source,
        g.road_marking,
        g.stroke,
        g.dasharray,
        g.pattern,
        g.arrow,
        g.symbol,
        g.width,
        g.length,
        g.colour,
        g.direction,
        g.type,
        g.class,
        g.layer,
        g.osm_type,
        g.osm_id
    FROM buffer_marking_merge_groups g
    INNER JOIN buffer_marking_merge_multi mm ON mm.cluster_id = g.cluster_id
    ORDER BY g.cluster_id, g.area DESC, g.poly_id
),
mixed_source AS (
    SELECT
        g.cluster_id,
        (
            bool_or(g.source = 'osm_feature')
            AND bool_or(g.source = 'crossing_attribute')
        ) AS is_mixed
    FROM buffer_marking_merge_groups g
    INNER JOIN buffer_marking_merge_multi mm ON mm.cluster_id = g.cluster_id
    GROUP BY g.cluster_id
),
merged_geom AS (
    SELECT
        g.cluster_id,
        ST_Buffer(ST_UnaryUnion(ST_Collect(g.geom)), 0) AS geom
    FROM buffer_marking_merge_groups g
    INNER JOIN buffer_marking_merge_multi mm ON mm.cluster_id = g.cluster_id
    GROUP BY g.cluster_id
)
SELECT
    aw.cluster_id,
    CASE WHEN ms.is_mixed THEN 'feature_merge'::text ELSE aw.source END AS source,
    aw.road_marking,
    aw.stroke,
    aw.dasharray,
    aw.pattern,
    aw.arrow,
    aw.symbol,
    aw.width,
    aw.length,
    aw.colour,
    aw.direction,
    aw.type,
    aw.class,
    aw.layer,
    aw.osm_type,
    aw.osm_id,
    (dp.geom)::geometry(Polygon) AS geom
FROM attr_winners aw
INNER JOIN mixed_source ms ON ms.cluster_id = aw.cluster_id
INNER JOIN merged_geom mg ON mg.cluster_id = aw.cluster_id
CROSS JOIN LATERAL ST_Dump(mg.geom) AS dp
WHERE mg.geom IS NOT NULL
  AND NOT ST_IsEmpty(mg.geom)
  AND ST_GeometryType(dp.geom) = 'ST_Polygon';

----------------------------------------------------------------------
-- §12b) Punch feature_polygon areas and non-merged road_marking polygons out of
--      generated restriction areas: crossing_attribute buffer markings and merged
--      results whose cluster includes at least one crossing_attribute member. Road
--      marking polygons from the same merge cluster are never subtracted from each
--      other; all other intersecting road_marking_polygon rows (e.g. zigzag) and all
--      intersecting feature_polygon rows on the same layer are cut out.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_punch_clusters;
CREATE TABLE buffer_marking_punch_clusters AS
SELECT g.cluster_id
FROM buffer_marking_merge_groups g
WHERE g.source = 'crossing_attribute'
GROUP BY g.cluster_id;

CREATE INDEX buffer_marking_punch_clusters_idx
    ON buffer_marking_punch_clusters (cluster_id);

DROP TABLE IF EXISTS buffer_marking_merge_result_final;
CREATE TABLE buffer_marking_merge_result_final AS
-- merged clusters with at least one crossing_attribute member: punch holes
SELECT
    mr.cluster_id,
    mr.source,
    mr.road_marking,
    mr.stroke,
    mr.dasharray,
    mr.pattern,
    mr.arrow,
    mr.symbol,
    mr.width,
    mr.length,
    mr.colour,
    mr.direction,
    mr.type,
    mr.class,
    mr.layer,
    mr.osm_type,
    mr.osm_id,
    (dp.geom)::geometry(Polygon) AS geom
FROM buffer_marking_merge_result mr
INNER JOIN buffer_marking_punch_clusters pc
  ON pc.cluster_id = mr.cluster_id
CROSS JOIN LATERAL (
    SELECT ST_Union(cut.geom) AS union_geom
    FROM (
        SELECT fp.geom
        FROM feature_polygon fp
        WHERE fp.geom && mr.geom
          AND ST_Intersects(fp.geom, mr.geom)
          AND COALESCE(fp.layer, 0) = COALESCE(mr.layer, 0)

        UNION ALL

        SELECT rmp.geom
        FROM road_marking_polygon rmp
        WHERE rmp.geom && mr.geom
          AND ST_Intersects(rmp.geom, mr.geom)
          AND COALESCE(rmp.layer, 0) = COALESCE(mr.layer, 0)
          AND NOT EXISTS (
              SELECT 1
              FROM buffer_marking_merge_groups g
              WHERE g.cluster_id = mr.cluster_id
                AND g.orig_ctid = rmp.ctid
          )
    ) cut
) cutout
CROSS JOIN LATERAL (
    SELECT ST_Difference(
        mr.geom,
        COALESCE(
            cutout.union_geom,
            ST_SetSRID('POLYGON EMPTY'::geometry, ST_SRID(mr.geom))
        )
    ) AS punched
) diff
CROSS JOIN LATERAL ST_Dump(diff.punched) AS dp
WHERE diff.punched IS NOT NULL
  AND NOT ST_IsEmpty(diff.punched)
  AND ST_GeometryType(dp.geom) = 'ST_Polygon'
  AND ST_Area(dp.geom) > 0.01

UNION ALL

-- merged clusters without any crossing_attribute member: unchanged
SELECT
    mr.cluster_id,
    mr.source,
    mr.road_marking,
    mr.stroke,
    mr.dasharray,
    mr.pattern,
    mr.arrow,
    mr.symbol,
    mr.width,
    mr.length,
    mr.colour,
    mr.direction,
    mr.type,
    mr.class,
    mr.layer,
    mr.osm_type,
    mr.osm_id,
    mr.geom
FROM buffer_marking_merge_result mr
WHERE NOT EXISTS (
    SELECT 1
    FROM buffer_marking_punch_clusters pc
    WHERE pc.cluster_id = mr.cluster_id
);

CREATE INDEX buffer_marking_merge_result_final_geom_idx
    ON buffer_marking_merge_result_final USING GIST (geom);

DROP TABLE IF EXISTS buffer_marking_punch_singles;
CREATE TABLE buffer_marking_punch_singles AS
SELECT
    g.orig_ctid AS target_ctid,
    g.source,
    g.road_marking,
    g.stroke,
    g.dasharray,
    g.pattern,
    g.arrow,
    g.symbol,
    g.width,
    g.length,
    g.colour,
    g.direction,
    g.type,
    g.class,
    g.layer,
    g.osm_type,
    g.osm_id,
    (dp.geom)::geometry(Polygon) AS geom
FROM buffer_marking_merge_groups g
LEFT JOIN buffer_marking_merge_multi mm
  ON mm.cluster_id = g.cluster_id
CROSS JOIN LATERAL (
    SELECT ST_Union(cut.geom) AS union_geom
    FROM (
        SELECT fp.geom
        FROM feature_polygon fp
        WHERE fp.geom && g.geom
          AND ST_Intersects(fp.geom, g.geom)
          AND COALESCE(fp.layer, 0) = COALESCE(g.layer, 0)

        UNION ALL

        SELECT rmp.geom
        FROM road_marking_polygon rmp
        WHERE rmp.geom && g.geom
          AND ST_Intersects(rmp.geom, g.geom)
          AND COALESCE(rmp.layer, 0) = COALESCE(g.layer, 0)
          AND rmp.ctid <> g.orig_ctid
          AND NOT EXISTS (
              SELECT 1
              FROM buffer_marking_merge_groups gm
              WHERE gm.cluster_id = g.cluster_id
                AND gm.orig_ctid = rmp.ctid
          )
    ) cut
) cutout
CROSS JOIN LATERAL (
    SELECT ST_Difference(
        g.geom,
        COALESCE(
            cutout.union_geom,
            ST_SetSRID('POLYGON EMPTY'::geometry, ST_SRID(g.geom))
        )
    ) AS punched
) diff
CROSS JOIN LATERAL ST_Dump(diff.punched) AS dp
WHERE mm.cluster_id IS NULL
  AND g.source = 'crossing_attribute'
  AND g.class = 'buffer_marking'
  AND diff.punched IS NOT NULL
  AND NOT ST_IsEmpty(diff.punched)
  AND ST_GeometryType(dp.geom) = 'ST_Polygon'
  AND ST_Area(dp.geom) > 0.01;

CREATE INDEX buffer_marking_punch_singles_target_ctid_idx
    ON buffer_marking_punch_singles (target_ctid);
CREATE INDEX buffer_marking_punch_singles_geom_idx
    ON buffer_marking_punch_singles USING GIST (geom);

DELETE FROM road_marking_polygon rmp
USING buffer_marking_merge_groups g,
      buffer_marking_merge_multi mm
WHERE rmp.ctid = g.orig_ctid
  AND g.cluster_id = mm.cluster_id;

INSERT INTO road_marking_polygon (
    source, road_marking, stroke, dasharray, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
)
SELECT
    source, road_marking, stroke, dasharray, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
FROM buffer_marking_merge_result_final;

DELETE FROM road_marking_polygon rmp
USING buffer_marking_punch_singles ps
WHERE rmp.ctid = ps.target_ctid;

INSERT INTO road_marking_polygon (
    source, road_marking, stroke, dasharray, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
)
SELECT
    source, road_marking, stroke, dasharray, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
FROM buffer_marking_punch_singles;


----------------------------------------------------------------------
-- §13) Footway cutout tunnels: one per (crossing_id, side), built from the crossing line
--      (buffer_marking_rays_extended.geom_extended), buffered by half the crossing way's
--      mapped width (or the fallback default) with square end caps. Square caps avoid
--      hairline gaps where a flat-capped buffer meets a restriction polygon boundary at
--      an oblique angle.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_final_tunnels;
CREATE TABLE buffer_marking_final_tunnels AS
SELECT
    bre.osm_type,
    bre.crossing_id,
    bre.side,
    bre.layer,
    bre.facing_azimuth,
    bre.geom_extended,
    ST_Buffer(bre.geom_extended, metres(hw.half_width), 'endcap=square') AS tunnel_geom,
    CASE
        WHEN bre.temporary = 'yes' THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour
FROM buffer_marking_rays_extended bre
LEFT JOIN buffer_marking_best_segment bs
  ON bs.crossing_id = bre.crossing_id
 AND bs.side = bre.side
CROSS JOIN LATERAL (
    -- explicitly OSM-mapped width of the matched crossing way (width/width:carriageway/
    -- est_width tag only, NULL -> fallback below). Deliberately not highway.width, which
    -- for path/class=crossing ways is filled with a computed "crossing rendering" default
    -- (crossing_width_default_footway = 5 / _zebra = 4, see lanes.lua) even when no width
    -- was actually mapped in OSM -- that default is unrelated to the footway cutout width.
    SELECT MAX(h.width_mapped) AS path_width
    FROM highway h
    WHERE bs.path_id IS NOT NULL
      AND h.osm_id = bs.path_id
      AND h.width_mapped IS NOT NULL
) pw
CROSS JOIN LATERAL (
    SELECT COALESCE(pw.path_width, :'buffer_marking_footway_cutout_default_width'::double precision) / 2.0
        AS half_width
) hw;

CREATE INDEX buffer_marking_final_tunnels_tunnel_geom_idx
    ON buffer_marking_final_tunnels USING GIST (tunnel_geom);
CREATE INDEX buffer_marking_final_tunnels_crossing_side_idx
    ON buffer_marking_final_tunnels (crossing_id, side);


----------------------------------------------------------------------
-- §14) Match each tunnel against every final restriction or barred_area polygon (pattern
--      stripes or NULL only; post-merge, any source: osm_feature, crossing_attribute or
--      feature_merge) it actually intersects — not restricted to a polygon generated for
--      the same crossing_id. This also guarantees that neighbouring polygons touched by
--      the same tunnel are cut exactly the same way (see plan note), since overlapping
--      ones were already unioned into a single row by §12 before this step runs at all.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_cutout_matches;
CREATE TABLE buffer_marking_cutout_matches AS
SELECT
    rmp.ctid AS orig_ctid,
    t.crossing_id,
    t.side,
    t.tunnel_geom,
    t.geom_extended,
    t.facing_azimuth,
    ST_Area(ST_Intersection(rmp.geom, t.tunnel_geom)) AS overlap_area
FROM road_marking_polygon rmp
JOIN buffer_marking_final_tunnels t
  ON rmp.geom && t.tunnel_geom
 AND ST_Intersects(rmp.geom, t.tunnel_geom)
WHERE rmp.road_marking IN ('restriction', 'barred_area')
  AND (rmp.pattern = 'stripes' OR rmp.pattern IS NULL)
  AND ST_Area(ST_Intersection(rmp.geom, t.tunnel_geom)) > 0.01;

CREATE INDEX buffer_marking_cutout_matches_ctid_idx
    ON buffer_marking_cutout_matches (orig_ctid);
CREATE INDEX buffer_marking_cutout_matches_crossing_side_idx
    ON buffer_marking_cutout_matches (crossing_id, side);


----------------------------------------------------------------------
-- §15) Cut all matching tunnels out of each affected polygon (unioned per orig_ctid, so a
--      polygon touched by several tunnels is only cut once), replacing the original row
--      with a remainder fragment (all original attributes/pattern preserved) and a cutout
--      fragment (pattern=none, all other attributes copied unchanged).
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_cutout_tunnel_union;
CREATE TABLE buffer_marking_cutout_tunnel_union AS
SELECT
    cm.orig_ctid,
    ST_UnaryUnion(ST_Collect(cm.tunnel_geom)) AS tunnel_union
FROM buffer_marking_cutout_matches cm
GROUP BY cm.orig_ctid;

CREATE INDEX buffer_marking_cutout_tunnel_union_ctid_idx
    ON buffer_marking_cutout_tunnel_union (orig_ctid);

DROP TABLE IF EXISTS buffer_marking_cutout_split;
CREATE TABLE buffer_marking_cutout_split AS
SELECT
    rmp.ctid AS orig_ctid,
    rmp.source, rmp.road_marking, rmp.stroke, rmp.dasharray, rmp.pattern, rmp.arrow,
    rmp.symbol, rmp.width, rmp.length, rmp.colour, rmp.direction, rmp.type, rmp.class,
    rmp.layer, rmp.osm_type, rmp.osm_id,
    rmp.geom AS orig_geom,
    ST_Intersection(rmp.geom, tu.tunnel_union) AS cutout_geom,
    ST_Difference(rmp.geom, tu.tunnel_union) AS remainder_geom
FROM buffer_marking_cutout_tunnel_union tu
JOIN road_marking_polygon rmp ON rmp.ctid = tu.orig_ctid;

CREATE INDEX buffer_marking_cutout_split_ctid_idx
    ON buffer_marking_cutout_split (orig_ctid);

DROP TABLE IF EXISTS buffer_marking_cutout_polygons;
CREATE TABLE buffer_marking_cutout_polygons AS
SELECT
    cs.source, cs.road_marking, cs.osm_type, cs.osm_id, cs.layer, cs.stroke, cs.dasharray,
    cs.arrow, cs.symbol, cs.width, cs.length, cs.colour, cs.direction, cs.type, cs.class,
    (dp.geom)::geometry(Polygon) AS geom
FROM buffer_marking_cutout_split cs
CROSS JOIN LATERAL ST_Dump(cs.cutout_geom) AS dp
WHERE (dp.geom) IS NOT NULL
  AND NOT ST_IsEmpty(dp.geom)
  AND ST_GeometryType(dp.geom) = 'ST_Polygon'
  AND ST_Area(dp.geom) > 0.01;

CREATE INDEX buffer_marking_cutout_polygons_geom_idx
    ON buffer_marking_cutout_polygons USING GIST (geom);

DROP TABLE IF EXISTS buffer_marking_remainder_polygons;
CREATE TABLE buffer_marking_remainder_polygons AS
SELECT
    cs.source, cs.road_marking, cs.osm_type, cs.osm_id, cs.layer, cs.stroke, cs.dasharray,
    cs.pattern, cs.arrow, cs.symbol, cs.width, cs.length, cs.colour, cs.direction, cs.type,
    cs.class,
    (dp.geom)::geometry(Polygon) AS geom
FROM buffer_marking_cutout_split cs
CROSS JOIN LATERAL ST_Dump(cs.remainder_geom) AS dp
WHERE (dp.geom) IS NOT NULL
  AND NOT ST_IsEmpty(dp.geom)
  AND ST_GeometryType(dp.geom) = 'ST_Polygon'
  AND ST_Area(dp.geom) > 0.01;

CREATE INDEX buffer_marking_remainder_polygons_geom_idx
    ON buffer_marking_remainder_polygons USING GIST (geom);

DELETE FROM road_marking_polygon rmp
USING buffer_marking_cutout_tunnel_union tu
WHERE rmp.ctid = tu.orig_ctid;

INSERT INTO road_marking_polygon (
    source, road_marking, stroke, dasharray, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
)
SELECT
    source, road_marking, stroke, dasharray, 'none'::text, arrow,
    symbol, width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
FROM buffer_marking_cutout_polygons
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)

UNION ALL

SELECT
    source, road_marking, stroke, dasharray, pattern, arrow,
    symbol, width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
FROM buffer_marking_remainder_polygons
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);


----------------------------------------------------------------------
-- §16) Footway symbol points: one per (crossing_id, side) that produced at least one
--      cutout match, placed at the midpoint of the crossing line's intersection with the
--      best-matching (largest-overlap) target polygon -- "the middle of the restriction
--      area" along the crossing line, per the requirement. Direction samples the local
--      tangent of the crossing line there, folded toward facing_azimuth so the symbol
--      always points toward the road/crossing node. Only emitted when this point still
--      lies within the (original, pre-cutout) target polygon; the cutout itself (§15)
--      always happens regardless.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_symbol_targets;
CREATE TABLE buffer_marking_symbol_targets AS
SELECT DISTINCT ON (cm.crossing_id, cm.side)
    cm.crossing_id,
    cm.side,
    cm.geom_extended,
    cm.facing_azimuth,
    cs.orig_geom AS target_geom
FROM buffer_marking_cutout_matches cm
-- the matched polygon row was already deleted/replaced by §15 by the time this runs,
-- so its pre-cutout geometry must come from the split intermediate (keyed by the same
-- orig_ctid), not from a fresh ctid lookup against the now-changed road_marking_polygon
JOIN buffer_marking_cutout_split cs ON cs.orig_ctid = cm.orig_ctid
ORDER BY cm.crossing_id, cm.side, cm.overlap_area DESC;

DROP TABLE IF EXISTS buffer_marking_symbol_points;
CREATE TABLE buffer_marking_symbol_points AS
SELECT
    bre.osm_type,
    bre.crossing_id,
    bre.layer,
    CASE
        WHEN bre.temporary = 'yes' THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    MOD(ROUND(DEGREES(oriented.oriented_azimuth))::integer + 3600, 360)::real AS symbol_direction,
    mid.symbol_point AS geom
FROM buffer_marking_symbol_targets st
JOIN buffer_marking_rays_extended bre
  ON bre.crossing_id = st.crossing_id
 AND bre.side = st.side
CROSS JOIN LATERAL (
    -- midpoint (by length) of the crossing line's clipped intersection with the target
    -- polygon; the intersection can be a (Multi)LineString or, in edge cases, a mixed
    -- GeometryCollection (e.g. a tangent point plus a line) -- dump and keep the longest
    -- LineString part only, then take its midpoint by length
    SELECT ST_LineInterpolatePoint(longest.geom, 0.5) AS symbol_point
    FROM (
        SELECT dp.geom
        FROM ST_Dump(ST_Intersection(st.geom_extended, st.target_geom)) dp
        WHERE ST_GeometryType(dp.geom) = 'ST_LineString'
        ORDER BY ST_Length(dp.geom) DESC
        LIMIT 1
    ) longest
) mid
CROSS JOIN LATERAL (
    SELECT ST_LineLocatePoint(st.geom_extended, mid.symbol_point) AS frac
) loc
CROSS JOIN LATERAL (
    -- local tangent of the crossing line near the symbol point (mirrors the bicycle-lane
    -- azimuth pattern in §9b)
    SELECT ST_Azimuth(
        ST_LineInterpolatePoint(st.geom_extended, GREATEST(0.0, LEAST(1.0, loc.frac - 0.01))),
        ST_LineInterpolatePoint(st.geom_extended, GREATEST(0.0, LEAST(1.0, loc.frac + 0.01)))
    ) AS raw_azimuth
) az
CROSS JOIN LATERAL (
    -- fold so the symbol always faces toward the road/crossing node (facing_azimuth)
    SELECT CASE
        WHEN ABS(ATAN2(
            SIN(az.raw_azimuth - st.facing_azimuth),
            COS(az.raw_azimuth - st.facing_azimuth)
        )) <= pi() / 2.0
        THEN az.raw_azimuth
        ELSE az.raw_azimuth + pi()
    END AS oriented_azimuth
) oriented
WHERE mid.symbol_point IS NOT NULL
  AND NOT ST_IsEmpty(mid.symbol_point)
  AND ST_Intersects(st.target_geom, mid.symbol_point);

INSERT INTO road_marking_node (
    source, road_marking, stroke, dasharray, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, osm_type, osm_id, geom
)
SELECT
    'crossing_attribute'::text,
    'symbol'::text,
    NULL::text,
    NULL::text,
    NULL::text,
    NULL::text,
    'footway'::text,
    :'buffer_marking_footway_symbol_width'::real,
    :'buffer_marking_footway_symbol_length'::real,
    sp.colour,
    sp.symbol_direction,
    'crossing'::text,
    NULL::text,
    sp.layer,
    sp.osm_type,
    sp.crossing_id,
    sp.geom
FROM buffer_marking_symbol_points sp
WHERE sp.geom IS NOT NULL
  AND NOT ST_IsEmpty(sp.geom);


----------------------------------------------------------------------
-- §17) Zebra/ladder stripe gaps at buffer markings: for crossings tagged
--      crossing:buffer_marking, clip the zebra centerline (from crossing_marking_lines_clipped)
--      against all final restriction polygons it intersects, regenerate stripe polygons
--      from the clipped line fragment(s), and replace the existing zebra_stripe rows.
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_zebra_crossings;
CREATE TABLE buffer_marking_zebra_crossings AS
SELECT
    cml.source,
    cml.osm_type,
    cml.osm_id,
    cml.stroke,
    cml.width,
    cml.layer,
    cml.crossing_id,
    cml.geom AS orig_centerline,
    cml.is_temporary,
    c.road_azimuth
FROM crossing_marking_lines_clipped cml
JOIN crossing c
  ON c.osm_id = cml.crossing_id
WHERE c."crossing:buffer_marking" IS NOT NULL
  AND cml.road_marking = 'crossing'
  AND cml.stroke IN ('zebra', 'ladder')
  AND cml.geom IS NOT NULL
  AND NOT ST_IsEmpty(cml.geom)
  AND ST_GeometryType(cml.geom) = 'ST_LineString'
  AND cml.width IS NOT NULL
  AND cml.width > 0.01;

CREATE INDEX buffer_marking_zebra_crossings_osm_idx
    ON buffer_marking_zebra_crossings (osm_type, osm_id);

DROP TABLE IF EXISTS buffer_marking_zebra_clipped_lines;
CREATE TABLE buffer_marking_zebra_clipped_lines AS
SELECT
    z.source,
    z.osm_type,
    z.osm_id,
    z.stroke,
    z.width,
    z.layer,
    z.crossing_id,
    z.is_temporary,
    z.road_azimuth,
    (dp.geom)::geometry(LineString) AS crossing_geom
FROM buffer_marking_zebra_crossings z
CROSS JOIN LATERAL (
    SELECT ST_Buffer(ST_Union(rmp.geom), 0) AS union_geom
    FROM road_marking_polygon rmp
    WHERE rmp.road_marking = 'restriction'
      AND rmp.geom && z.orig_centerline
      AND ST_Intersects(rmp.geom, z.orig_centerline)
      AND COALESCE(rmp.layer, 0) = COALESCE(z.layer, 0)
) restr
CROSS JOIN LATERAL ST_Dump(
    CASE
        WHEN restr.union_geom IS NULL OR ST_IsEmpty(restr.union_geom)
        THEN z.orig_centerline
        ELSE ST_Difference(z.orig_centerline, restr.union_geom)
    END
) dp
WHERE (dp.geom) IS NOT NULL
  AND NOT ST_IsEmpty((dp.geom))
  AND ST_GeometryType((dp.geom)) = 'ST_LineString'
  AND ST_Length((dp.geom)) >= metres(:'crossing_stripe_width'::double precision);

DROP TABLE IF EXISTS _crossing_stripe_input;
CREATE TEMP TABLE _crossing_stripe_input AS
SELECT
    source,
    osm_type,
    osm_id,
    stroke,
    width,
    layer,
    crossing_id,
    crossing_geom,
    is_temporary,
    road_azimuth
FROM buffer_marking_zebra_clipped_lines;

\i 'processing/sql/helper/crossing_stripe_polygons.sql'

DROP TABLE IF EXISTS buffer_marking_zebra_stripe_merged;
CREATE TABLE buffer_marking_zebra_stripe_merged AS
SELECT
    sp.source,
    sp.road_marking,
    sp.osm_type,
    sp.osm_id,
    sp.stroke,
    sp.pattern,
    sp.arrow,
    sp.symbol,
    MAX(sp.width) AS width,
    ROUND(SUM(sp.length)::numeric, 1)::real AS length,
    sp.colour,
    sp.direction,
    sp.type,
    sp.class,
    sp.layer,
    sp.dasharray,
    ST_Multi(ST_Union(sp.geom))::geometry(MultiPolygon) AS geom
FROM _crossing_stripe_polygons sp
GROUP BY
    sp.source,
    sp.road_marking,
    sp.osm_type,
    sp.osm_id,
    sp.stroke,
    sp.pattern,
    sp.arrow,
    sp.symbol,
    sp.colour,
    sp.direction,
    sp.type,
    sp.class,
    sp.layer,
    sp.dasharray
HAVING ST_Union(sp.geom) IS NOT NULL
   AND NOT ST_IsEmpty(ST_Union(sp.geom));

DROP TABLE IF EXISTS _crossing_stripe_input;
DROP TABLE IF EXISTS _crossing_stripe_polygons;

DELETE FROM road_marking_polygon rmp
USING buffer_marking_zebra_crossings z
WHERE rmp.road_marking = 'zebra_stripe'
  AND rmp.osm_type IS NOT DISTINCT FROM z.osm_type
  AND rmp.osm_id = z.osm_id;

INSERT INTO road_marking_polygon (
    source, road_marking, osm_type, osm_id, stroke, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, dasharray, geom
)
SELECT
    source, road_marking, osm_type, osm_id, stroke, pattern, arrow, symbol,
    width, length, colour, direction, type, class, layer, dasharray, geom
FROM buffer_marking_zebra_stripe_merged
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);


----------------------------------------------------------------------
-- §18) Cleanup intermediate tables
----------------------------------------------------------------------

DROP TABLE IF EXISTS buffer_marking_zebra_stripe_merged;
DROP TABLE IF EXISTS buffer_marking_zebra_clipped_lines;
DROP TABLE IF EXISTS buffer_marking_zebra_crossings;
DROP TABLE IF EXISTS buffer_marking_symbol_points;
DROP TABLE IF EXISTS buffer_marking_symbol_targets;
DROP TABLE IF EXISTS buffer_marking_remainder_polygons;
DROP TABLE IF EXISTS buffer_marking_cutout_polygons;
DROP TABLE IF EXISTS buffer_marking_cutout_split;
DROP TABLE IF EXISTS buffer_marking_cutout_tunnel_union;
DROP TABLE IF EXISTS buffer_marking_cutout_matches;
DROP TABLE IF EXISTS buffer_marking_final_tunnels;
DROP TABLE IF EXISTS buffer_marking_punch_singles;
DROP TABLE IF EXISTS buffer_marking_merge_result_final;
DROP TABLE IF EXISTS buffer_marking_punch_clusters;
DROP TABLE IF EXISTS buffer_marking_merge_result;
DROP TABLE IF EXISTS buffer_marking_merge_multi;
DROP TABLE IF EXISTS buffer_marking_merge_groups;
DROP TABLE IF EXISTS buffer_marking_merge_candidates;
DROP TABLE IF EXISTS buffer_marking_polygons;
DROP TABLE IF EXISTS buffer_marking_polygons_relocated;
DROP TABLE IF EXISTS buffer_marking_polygons_original;
DROP TABLE IF EXISTS buffer_marking_relocated_area_check;
DROP TABLE IF EXISTS buffer_marking_original_area_check;
DROP TABLE IF EXISTS buffer_marking_half_a_original;
DROP TABLE IF EXISTS buffer_marking_relocated_final;
DROP TABLE IF EXISTS buffer_marking_relocation_ok_overlap;
DROP TABLE IF EXISTS buffer_marking_relocation_discarded;
DROP TABLE IF EXISTS buffer_marking_relocation_candidates;
DROP TABLE IF EXISTS buffer_marking_bicycle_conflict;
DROP TABLE IF EXISTS buffer_marking_half_a_accepted;
DROP TABLE IF EXISTS buffer_marking_half_a;
DROP TABLE IF EXISTS buffer_marking_reference_points;
DROP TABLE IF EXISTS buffer_marking_rays_extended;
DROP TABLE IF EXISTS buffer_marking_rays;
DROP TABLE IF EXISTS buffer_marking_best_segment;
DROP TABLE IF EXISTS buffer_marking_path_segments_scored;
DROP TABLE IF EXISTS buffer_marking_path_segments;
DROP TABLE IF EXISTS buffer_marking_sides;
DROP TABLE IF EXISTS buffer_marking_azimuth;
DROP TABLE IF EXISTS buffer_marking_filtered;
