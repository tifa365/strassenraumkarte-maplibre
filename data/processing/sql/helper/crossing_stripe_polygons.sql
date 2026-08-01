-- crossing_stripe_polygons.sql — Build zebra/ladder stripe polygons along crossing centerlines.
--
-- Input (must exist): _crossing_stripe_input with columns
--   source, osm_type, osm_id, stroke, width, layer, crossing_id,
--   crossing_geom (LineString), is_temporary (boolean), road_azimuth (integer, nullable)
--
-- Output: _crossing_stripe_polygons (same column layout as road_marking_crossing.sql §7.6b INSERT)

DROP TABLE IF EXISTS _crossing_stripe_polygons;
CREATE TEMP TABLE _crossing_stripe_polygons AS
WITH striped_crossings AS (
    SELECT
        inp.source,
        inp.osm_type,
        inp.osm_id,
        inp.stroke,
        inp.width,
        inp.layer,
        inp.crossing_id,
        inp.crossing_geom,
        ST_LineExtend(inp.crossing_geom, metres(inp.width), metres(inp.width)) AS crossing_geom_for_clip,
        inp.is_temporary,
        inp.road_azimuth
    FROM _crossing_stripe_input inp
    WHERE inp.crossing_geom IS NOT NULL
      AND NOT ST_IsEmpty(inp.crossing_geom)
      AND ST_GeometryType(inp.crossing_geom) = 'ST_LineString'
      AND inp.width IS NOT NULL
      AND inp.width > 0.01
      AND ST_Length(inp.crossing_geom) >= metres(:'crossing_stripe_width'::double precision)
),
stripe_k AS (
    SELECT
        sc.*,
        ST_Length(sc.crossing_geom) AS line_len,
        GREATEST(
            1,
            FLOOR(
                (ST_Length(sc.crossing_geom) - metres(:'crossing_stripe_width'::double precision))
                / metres(:'crossing_stripe_spacing'::double precision)
            )::integer + 1
        ) AS n_stripes
    FROM striped_crossings sc
),
stripe_i AS (
    SELECT
        k.*,
        gs.i AS stripe_idx
    FROM stripe_k k
    CROSS JOIN LATERAL generate_series(0, k.n_stripes - 1) AS gs(i)
),
stripe_pos AS (
    SELECT
        i.*,
        (
            (i.line_len - (
                (i.n_stripes - 1) * metres(:'crossing_stripe_spacing'::double precision)
                + metres(:'crossing_stripe_width'::double precision)
            )) / 2.0
            + (metres(:'crossing_stripe_width'::double precision) / 2.0)
            + i.stripe_idx * metres(:'crossing_stripe_spacing'::double precision)
        ) AS center_d,
        (
            (
                (i.line_len - (
                    (i.n_stripes - 1) * metres(:'crossing_stripe_spacing'::double precision)
                    + metres(:'crossing_stripe_width'::double precision)
                )) / 2.0
                + (metres(:'crossing_stripe_width'::double precision) / 2.0)
                + i.stripe_idx * metres(:'crossing_stripe_spacing'::double precision)
            )
            / NULLIF(i.line_len, 0)
        ) AS frac_along
    FROM stripe_i i
),
stripe_pts AS (
    SELECT
        p.*,
        GREATEST(0.0, LEAST(1.0, p.frac_along)) AS frac_clamped,
        ST_LineInterpolatePoint(
            p.crossing_geom,
            GREATEST(0.0, LEAST(1.0, p.frac_along))
        )::geometry(Point) AS pt
    FROM stripe_pos p
    WHERE p.line_len > 0
),
stripe_tangent AS (
    SELECT
        sp.*,
        ST_Azimuth(
            ST_LineInterpolatePoint(
                sp.crossing_geom,
                GREATEST(0.00002, sp.frac_clamped - 0.00001)
            ),
            ST_LineInterpolatePoint(
                sp.crossing_geom,
                LEAST(0.99998, sp.frac_clamped + 0.00001)
            )
        ) AS tangent
    FROM stripe_pts sp
),
stripe_oriented AS (
    SELECT
        st.*,
        CASE
            WHEN st.road_azimuth IS NOT NULL
            THEN RADIANS(st.road_azimuth::double precision)
            ELSE st.tangent + pi() / 2.0
        END AS stripe_az,
        metres(st.width + :'crossing_stripe_length_extra'::double precision) / 2.0 AS half_len
    FROM stripe_tangent st
    WHERE st.tangent IS NOT NULL
),
stripe_raw AS (
    SELECT
        so.*,
        ST_Buffer(
            ST_MakeLine(
                ST_Project(so.pt, so.half_len, so.stripe_az + pi()),
                ST_Project(so.pt, so.half_len, so.stripe_az)
            ),
            metres(:'crossing_stripe_width'::double precision) / 2.0,
            'endcap=flat join=mitre'
        ) AS stripe_geom_raw,
        ST_Buffer(
            so.crossing_geom_for_clip,
            metres(so.width) / 2.0,
            'endcap=flat join=round'
        ) AS clip_zone
    FROM stripe_oriented so
),
stripe_clipped AS (
    SELECT
        r.source,
        r.osm_type,
        r.osm_id,
        r.stroke,
        r.width,
        r.line_len,
        r.layer,
        CASE
            WHEN r.is_temporary
            THEN :'road_marking_temporary_colour'::text
            ELSE :'road_marking_default_colour'::text
        END AS colour,
        (dp.geom)::geometry(Polygon) AS geom
    FROM stripe_raw r
    CROSS JOIN LATERAL ST_Dump(
        ST_Intersection(r.stripe_geom_raw, r.clip_zone)
    ) AS dp
    WHERE r.stripe_geom_raw IS NOT NULL
      AND NOT ST_IsEmpty(r.stripe_geom_raw)
      AND r.clip_zone IS NOT NULL
      AND NOT ST_IsEmpty(r.clip_zone)
      AND (dp.geom) IS NOT NULL
      AND NOT ST_IsEmpty((dp.geom))
      AND ST_GeometryType((dp.geom)) = 'ST_Polygon'
      AND ST_Area((dp.geom)) > 0.01
),
stripe_merged AS (
    SELECT
        sc.source,
        sc.osm_type,
        sc.osm_id,
        sc.stroke,
        sc.width::real AS width,
        ROUND(sc.line_len::numeric, 1)::real AS length,
        sc.layer,
        sc.colour,
        ST_Collect(sc.geom)::geometry(MultiPolygon) AS geom
    FROM stripe_clipped sc
    GROUP BY
        sc.source,
        sc.osm_type,
        sc.osm_id,
        sc.stroke,
        sc.width,
        sc.line_len,
        sc.layer,
        sc.colour
    HAVING COUNT(*) > 0
)
SELECT
    sm.source,
    'zebra_stripe'::text AS road_marking,
    sm.osm_type,
    sm.osm_id,
    NULL::text AS stroke,
    NULL::text AS pattern,
    NULL::text AS arrow,
    NULL::text AS symbol,
    sm.width,
    sm.length,
    sm.colour,
    NULL::real AS direction,
    'crossing'::text AS type,
    sm.stroke AS class,
    sm.layer,
    format(
        '%s;%s',
        (:'crossing_stripe_width'::double precision),
        (:'crossing_stripe_spacing'::double precision - :'crossing_stripe_width'::double precision)
    ) AS dasharray,
    sm.geom
FROM stripe_merged sm;
