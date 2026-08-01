-- Transform road markingrestriction polygons into line patterns in road_marking_way
--
-- pattern=x: OBB diagonals (clipped to polygon) + ST_Boundary of original polygon
-- pattern=zigzag: lines between front and back OBB edges (clipped to polygon) + side edges
--                 zigzag step size per polygon: 2 * side edge length (but max. 7 m)
--
-- Depends on: road_marking_polygon.direction for zigzag (highway_area_direction.sql)

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'


-- ---------------------------------------------------------------------------
-- pattern=x — OBB diagonals + polygon boundary
-- ---------------------------------------------------------------------------

WITH x_polygons AS (
    SELECT
        osm_id,
        geom,
        stroke,
        colour,
        layer
    FROM road_marking_polygon
    WHERE road_marking = 'restriction'
      AND pattern = 'x'
      AND geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_Area(geom) > 0.01
),
x_envelope AS (
    SELECT
        p.osm_id,
        p.geom,
        p.stroke,
        p.colour,
        p.layer,
        ST_PointN(ST_ExteriorRing(ST_OrientedEnvelope(p.geom)), 1) AS p1,
        ST_PointN(ST_ExteriorRing(ST_OrientedEnvelope(p.geom)), 2) AS p2,
        ST_PointN(ST_ExteriorRing(ST_OrientedEnvelope(p.geom)), 3) AS p3,
        ST_PointN(ST_ExteriorRing(ST_OrientedEnvelope(p.geom)), 4) AS p4
    FROM x_polygons p
),
x_lines AS (
    SELECT
        e.osm_id,
        e.geom,
        e.stroke,
        e.colour,
        e.layer,
        CASE d.diag_idx
            WHEN 1 THEN ST_MakeLine(e.p1, e.p3)
            WHEN 2 THEN ST_MakeLine(e.p2, e.p4)
        END AS line_geom
    FROM x_envelope e
    CROSS JOIN LATERAL (
        VALUES (1), (2)
    ) AS d(diag_idx)
    UNION ALL
    SELECT
        p.osm_id,
        p.geom,
        p.stroke,
        p.colour,
        p.layer,
        ST_Boundary(p.geom) AS line_geom
    FROM x_polygons p
),
x_clipped AS (
    SELECT
        l.osm_id,
        l.stroke,
        l.colour,
        l.layer,
        ST_LineMerge(
            ST_Intersection(
                l.line_geom,
                l.geom
            )
        ) AS clipped_geom
    FROM x_lines l
    WHERE l.line_geom IS NOT NULL
      AND NOT ST_IsEmpty(l.line_geom)
),
x_parts AS (
    SELECT
        c.osm_id,
        c.stroke,
        c.colour,
        c.layer,
        (ST_Dump(
            CASE
                WHEN ST_GeometryType(c.clipped_geom) IN ('ST_LineString', 'ST_MultiLineString')
                THEN c.clipped_geom
                ELSE ST_CollectionExtract(c.clipped_geom, 2)
            END
        )).geom AS geom
    FROM x_clipped c
    WHERE c.clipped_geom IS NOT NULL
      AND NOT ST_IsEmpty(c.clipped_geom)
)
INSERT INTO road_marking_way (
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
    geom
)
SELECT
    'road_marking_restriction_x'::text,
    'restriction'::text,
    'W'::text,
    m.osm_id,
    COALESCE(m.stroke, 'solid'),
    'x'::text,
    NULL::text,
    NULL::text,
    :'narrow_stroke_width'::real,
    NULL::real,
    m.colour,
    NULL::real,
    NULL::text,
    NULL::text,
    m.layer,
    m.geom
FROM x_parts m
WHERE m.geom IS NOT NULL
  AND NOT ST_IsEmpty(m.geom)
  AND ST_GeometryType(m.geom) = 'ST_LineString'
  AND ST_Length(m.geom) > metres(0.1);


-- ---------------------------------------------------------------------------
-- pattern=zigzag — side caps + alternating front/back connected lines  |VVV|
-- ---------------------------------------------------------------------------

WITH polygons AS (
    SELECT
        osm_id,
        geom,
        direction,
        stroke,
        colour,
        layer
    FROM road_marking_polygon
    WHERE road_marking = 'restriction'
      AND pattern = 'zigzag'
      AND direction IS NOT NULL
      AND geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_Area(geom) > 0.01
),
envelope AS (
    SELECT
        p.osm_id,
        p.geom,
        p.direction,
        p.stroke,
        p.colour,
        p.layer,
        ST_OrientedEnvelope(p.geom) AS envelope
    FROM polygons p
),
envelope_ring AS (
    SELECT
        e.osm_id,
        e.geom,
        e.direction,
        e.stroke,
        e.colour,
        e.layer,
        ST_PointN(ST_ExteriorRing(e.envelope), 1) AS p1,
        ST_PointN(ST_ExteriorRing(e.envelope), 2) AS p2,
        ST_PointN(ST_ExteriorRing(e.envelope), 3) AS p3,
        ST_PointN(ST_ExteriorRing(e.envelope), 4) AS p4
    FROM envelope e
),
edges AS (
    SELECT
        er.osm_id,
        er.geom,
        er.direction,
        er.stroke,
        er.colour,
        er.layer,
        v.edge_idx,
        v.edge_line,
        ROUND(DEGREES(ST_Azimuth(v.p_from, v.p_to)))::INTEGER AS edge_azimuth_deg
    FROM envelope_ring er
    CROSS JOIN LATERAL (
        VALUES
            (0, er.p1, er.p2, ST_MakeLine(er.p1, er.p2)),
            (1, er.p2, er.p3, ST_MakeLine(er.p2, er.p3)),
            (2, er.p3, er.p4, ST_MakeLine(er.p3, er.p4)),
            (3, er.p4, er.p1, ST_MakeLine(er.p4, er.p1))
    ) AS v(edge_idx, p_from, p_to, edge_line)
),
edges_scored AS (
    SELECT
        e.*,
        LEAST(
            ABS(e.edge_azimuth_deg - ROUND(e.direction::numeric)::INTEGER),
            360 - ABS(e.edge_azimuth_deg - ROUND(e.direction::numeric)::INTEGER)
        )::double precision AS direction_diff_deg
    FROM edges e
),
side_edge AS (
    SELECT DISTINCT ON (osm_id)
        osm_id,
        geom,
        direction,
        stroke,
        colour,
        layer,
        edge_idx AS side_idx
    FROM edges_scored
    ORDER BY osm_id, direction_diff_deg, edge_idx
),
front_back AS (
    SELECT
        se.osm_id,
        se.geom,
        se.direction,
        se.stroke,
        se.colour,
        se.layer,
        se.side_idx,
        ST_Reverse(
            (array_agg(ed.edge_line ORDER BY ed.edge_idx)
                FILTER (WHERE ed.edge_idx = (se.side_idx + 3) % 4))[1]
        ) AS front_line,
        (array_agg(ed.edge_line ORDER BY ed.edge_idx)
            FILTER (WHERE ed.edge_idx = (se.side_idx + 1) % 4))[1] AS back_line,
        (array_agg(ed.edge_line ORDER BY ed.edge_idx)
            FILTER (WHERE ed.edge_idx = se.side_idx))[1] AS side_start_line,
        (array_agg(ed.edge_line ORDER BY ed.edge_idx)
            FILTER (WHERE ed.edge_idx = (se.side_idx + 2) % 4))[1] AS side_end_line
    FROM side_edge se
    JOIN edges ed ON ed.osm_id = se.osm_id
    GROUP BY
        se.osm_id,
        se.geom,
        se.direction,
        se.stroke,
        se.colour,
        se.layer,
        se.side_idx
),
obb_corners AS (
    SELECT
        fb.*,
        ST_StartPoint(fb.front_line) AS front_start,
        ST_EndPoint(fb.front_line) AS front_end,
        ST_StartPoint(fb.back_line) AS back_start,
        ST_EndPoint(fb.back_line) AS back_end,
        CASE
            WHEN ST_DWithin(ST_StartPoint(fb.side_start_line), ST_StartPoint(fb.front_line), metres(1e-6))
            THEN fb.side_start_line
            ELSE ST_Reverse(fb.side_start_line)
        END AS side_start_oriented,
        CASE
            WHEN ST_DWithin(ST_StartPoint(fb.side_end_line), ST_EndPoint(fb.back_line), metres(1e-6))
            THEN fb.side_end_line
            ELSE ST_Reverse(fb.side_end_line)
        END AS side_end_oriented,
        ST_Length(fb.front_line) AS front_len,
        ST_Length(fb.back_line) AS back_len,
        ST_Length(fb.side_start_line) AS side_len,
        LEAST(2 * ST_Length(fb.side_start_line), metres(7.0))::double precision AS zigzag_segment_m,
        GREATEST(
            2,
            (
                CEIL(
                    ST_Length(fb.front_line)
                    / LEAST(
                        2 * GREATEST(ST_Length(fb.side_start_line), metres(0.01)),
                        metres(7.0)
                    )
                ) * 2
            )::INTEGER
        ) AS n_seg,
        ST_Boundary(fb.geom) AS poly_boundary
    FROM front_back fb
    WHERE ST_Length(fb.front_line) > metres(0.1)
      AND ST_Length(fb.back_line) > metres(0.1)
),
zigzag_interior AS (
    SELECT
        oc.osm_id,
        gs.i,
        oc.poly_boundary,
        CASE
            WHEN gs.i % 2 = 1 THEN
                ST_LineInterpolatePoint(oc.front_line, gs.i::double precision / oc.n_seg)
            ELSE
                ST_LineInterpolatePoint(oc.back_line, gs.i::double precision / oc.n_seg)
        END AS pt_raw
    FROM obb_corners oc
    CROSS JOIN LATERAL generate_series(1, oc.n_seg - 1) AS gs(i)
),
zigzag_interior_snapped AS (
    SELECT
        zi.osm_id,
        zi.i,
        CASE
            WHEN d.dist >= metres(:'zigzag_snap_min_m'::double precision)
             AND d.dist <= metres(:'zigzag_snap_max_m'::double precision)
            THEN ST_ClosestPoint(zi.poly_boundary, zi.pt_raw)
            ELSE zi.pt_raw
        END AS pt
    FROM zigzag_interior zi
    CROSS JOIN LATERAL (
        SELECT ST_Distance(zi.pt_raw, zi.poly_boundary) AS dist
    ) d
),
interior_agg AS (
    SELECT
        osm_id,
        array_agg(pt ORDER BY i) AS interior_pts
    FROM zigzag_interior_snapped
    GROUP BY osm_id
),
outline_core_raw AS (
    SELECT
        oc.osm_id,
        oc.geom,
        oc.stroke,
        oc.colour,
        oc.layer,
        oc.side_start_oriented,
        oc.side_end_oriented,
        ST_MakeLine(
            ARRAY[
                oc.front_start,
                oc.back_start
            ]::geometry[]
            || COALESCE(ia.interior_pts, ARRAY[]::geometry[])
            || ARRAY[
                oc.back_end,
                oc.front_end
            ]::geometry[]
        ) AS core_geom
    FROM obb_corners oc
    LEFT JOIN interior_agg ia ON ia.osm_id = oc.osm_id
),
outline_side_lines AS (
    SELECT
        r.osm_id,
        r.geom,
        r.stroke,
        r.colour,
        r.layer,
        r.side_start_oriented AS line_geom
    FROM outline_core_raw r
    WHERE r.side_start_oriented IS NOT NULL
      AND NOT ST_IsEmpty(r.side_start_oriented)
    UNION ALL
    SELECT
        r.osm_id,
        r.geom,
        r.stroke,
        r.colour,
        r.layer,
        r.side_end_oriented AS line_geom
    FROM outline_core_raw r
    WHERE r.side_end_oriented IS NOT NULL
      AND NOT ST_IsEmpty(r.side_end_oriented)
),
outline_core_clipped AS (
    SELECT
        r.osm_id,
        r.stroke,
        r.colour,
        r.layer,
        ST_LineMerge(
            ST_Intersection(
                ST_LineMerge(r.core_geom),
                r.geom
            )
        ) AS clipped_geom
    FROM outline_core_raw r
    WHERE r.core_geom IS NOT NULL
      AND NOT ST_IsEmpty(r.core_geom)
),
outline_side_clipped AS (
    SELECT
        s.osm_id,
        s.stroke,
        s.colour,
        s.layer,
        ST_LineMerge(
            ST_Intersection(
                s.line_geom,
                ST_Buffer(s.geom, metres(:'zigzag_side_clip_buffer_m'::double precision))
            )
        ) AS clipped_geom
    FROM outline_side_lines s
),
outline_merged AS (
    SELECT osm_id, stroke, colour, layer, clipped_geom
    FROM outline_core_clipped
    WHERE clipped_geom IS NOT NULL
      AND NOT ST_IsEmpty(clipped_geom)
    UNION ALL
    SELECT osm_id, stroke, colour, layer, clipped_geom
    FROM outline_side_clipped
    WHERE clipped_geom IS NOT NULL
      AND NOT ST_IsEmpty(clipped_geom)
),
outline_parts AS (
    SELECT
        c.osm_id,
        c.stroke,
        c.colour,
        c.layer,
        (ST_Dump(
            CASE
                WHEN ST_GeometryType(c.clipped_geom) IN ('ST_LineString', 'ST_MultiLineString')
                THEN c.clipped_geom
                ELSE ST_CollectionExtract(c.clipped_geom, 2)
            END
        )).geom AS geom
    FROM outline_merged c
)
INSERT INTO road_marking_way (
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
    geom
)
SELECT
    'road_marking_restriction_zigzag'::text,
    'restriction'::text,
    'W'::text,
    m.osm_id,
    COALESCE(m.stroke, 'solid'),
    'zigzag'::text,
    NULL::text,
    NULL::text,
    :'narrow_stroke_width'::real,
    NULL::real,
    m.colour,
    NULL::real,
    NULL::text,
    NULL::text,
    m.layer,
    m.geom
FROM outline_parts m
WHERE m.geom IS NOT NULL
  AND NOT ST_IsEmpty(m.geom)
  AND ST_GeometryType(m.geom) = 'ST_LineString'
  AND ST_Length(m.geom) > metres(0.1);
