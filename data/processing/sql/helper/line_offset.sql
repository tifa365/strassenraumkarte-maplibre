----------------------------------------------------------------------
-- helper/line_offset.sql
--
-- Reusable line offset function based on per-vertex shifting along the
-- local normal vector (robust alternative to ST_OffsetCurve).
--
-- base_offset / transition are ground metres; metres() converts to CRS
-- map units (Web Mercator scale under EPSG:3857). Callers must pass
-- ground metres — do not wrap arguments with metres() again.
----------------------------------------------------------------------

\i 'processing/sql/helper/metres.sql'

CREATE OR REPLACE FUNCTION line_offset(
    geom geometry(LineString),
    base_offset double precision,
    transition double precision DEFAULT 0.0
)
RETURNS geometry(LineString)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
WITH
scaled AS (
    SELECT
        metres(base_offset) AS base_offset,
        metres(transition) AS transition
),
base AS (
    -- Reject fully-degenerate (zero/near-zero-length) lines up front: a
    -- 2-point line with (near-)identical endpoints has zero length, but
    -- ST_RemoveRepeatedPoints refuses to collapse it below 2 points (that
    -- would be an invalid LineString), so NPoints alone never catches it.
    -- For lines that do have real length, ST_RemoveRepeatedPoints still
    -- strips any *interior* repeated/near-duplicate vertices, which would
    -- otherwise make the corresponding v1/v2 unit-vector division below
    -- divide by zero (a repeated first/last point similarly zeroes the
    -- endpoint tangent's dx/dy).
    SELECT
        ST_RemoveRepeatedPoints(geom, 0.001) AS line_geom
    WHERE geom IS NOT NULL
      AND ST_Length(geom) > 0.001
      AND ST_NPoints(ST_RemoveRepeatedPoints(geom, 0.001)) >= 2
),
points AS (
    SELECT
        (dp).path[1] AS pt_idx,
        (dp).geom    AS pt_geom,
        line_geom
    FROM base
    CROSS JOIN LATERAL ST_DumpPoints(line_geom) AS dp
),
points_nb AS (
    SELECT
        p.*,
        LAG(pt_geom)  OVER (ORDER BY pt_idx) AS prev_pt,
        LEAD(pt_geom) OVER (ORDER BY pt_idx) AS next_pt
    FROM points p
),
tangents AS (
    SELECT
        *,
        CASE
            -- first point
            WHEN prev_pt IS NULL THEN
                (
                    WITH v AS (
                        SELECT
                            ST_X(next_pt) - ST_X(pt_geom) AS dx,
                            ST_Y(next_pt) - ST_Y(pt_geom) AS dy
                    )
                    SELECT ST_MakePoint(
                        dx / sqrt(dx*dx + dy*dy),
                        dy / sqrt(dx*dx + dy*dy)
                    )
                    FROM v
                )
            -- last point
            WHEN next_pt IS NULL THEN
                (
                    WITH v AS (
                        SELECT
                            ST_X(pt_geom) - ST_X(prev_pt) AS dx,
                            ST_Y(pt_geom) - ST_Y(prev_pt) AS dy
                    )
                    SELECT ST_MakePoint(
                        dx / sqrt(dx*dx + dy*dy),
                        dy / sqrt(dx*dx + dy*dy)
                    )
                    FROM v
                )
            -- inner point
            ELSE
                (
                    WITH
                    v1 AS (
                        SELECT
                            ST_X(pt_geom) - ST_X(prev_pt) AS dx,
                            ST_Y(pt_geom) - ST_Y(prev_pt) AS dy
                    ),
                    v2 AS (
                        SELECT
                            ST_X(next_pt) - ST_X(pt_geom) AS dx,
                            ST_Y(next_pt) - ST_Y(pt_geom) AS dy
                    ),
                    u1 AS (
                        SELECT
                            dx / sqrt(dx*dx + dy*dy) AS ux,
                            dy / sqrt(dx*dx + dy*dy) AS uy
                        FROM v1
                    ),
                    u2 AS (
                        SELECT
                            dx / sqrt(dx*dx + dy*dy) AS ux,
                            dy / sqrt(dx*dx + dy*dy) AS uy
                        FROM v2
                    ),
                    s AS (
                        SELECT
                            u1.ux + u2.ux AS dx,
                            u1.uy + u2.uy AS dy
                        FROM u1, u2
                    )
                    SELECT
                        CASE
                            WHEN sqrt(dx*dx + dy*dy) < 1e-12 THEN
                                ST_MakePoint(u2.ux, u2.uy)
                            ELSE
                                ST_MakePoint(
                                    dx / sqrt(dx*dx + dy*dy),
                                    dy / sqrt(dx*dx + dy*dy)
                                )
                        END
                    FROM s, u2
                )
        END AS tangent
    FROM points_nb
),
normals AS (
    SELECT
        *,
        ST_MakePoint(
            ST_Y(tangent),
           -ST_X(tangent)
        ) AS normal
    FROM tangents
),
located AS (
    SELECT
        *,
        ST_LineLocatePoint(line_geom, pt_geom) AS s
    FROM normals
),
shifted AS (
    SELECT
        pt_idx,
        ST_Translate(
            pt_geom,
            ((SELECT base_offset FROM scaled) + s * (SELECT transition FROM scaled)) * ST_X(normal),
            ((SELECT base_offset FROM scaled) + s * (SELECT transition FROM scaled)) * ST_Y(normal)
        ) AS new_pt_geom
    FROM located
)
SELECT
    ST_SetSRID(
        ST_MakeLine(new_pt_geom ORDER BY pt_idx),
        ST_SRID((SELECT line_geom FROM base))
    )::geometry(LineString)
FROM shifted;
$$;


----------------------------------------------------------------------
-- Same as line_offset, but optionally keep start and/or end vertices
-- unshifted (offset 0) so topology at junctions can be preserved.
----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION line_offset_pin_ends(
    geom geometry(LineString),
    base_offset double precision,
    transition double precision DEFAULT 0.0,
    pin_start boolean DEFAULT false,
    pin_end boolean DEFAULT false
)
RETURNS geometry(LineString)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
WITH
scaled AS (
    SELECT
        metres(base_offset) AS base_offset,
        metres(transition) AS transition
),
base AS (
    -- Reject fully-degenerate (zero/near-zero-length) lines up front: a
    -- 2-point line with (near-)identical endpoints has zero length, but
    -- ST_RemoveRepeatedPoints refuses to collapse it below 2 points (that
    -- would be an invalid LineString), so NPoints alone never catches it.
    -- For lines that do have real length, ST_RemoveRepeatedPoints still
    -- strips any *interior* repeated/near-duplicate vertices, which would
    -- otherwise make the corresponding v1/v2 unit-vector division below
    -- divide by zero (a repeated first/last point similarly zeroes the
    -- endpoint tangent's dx/dy).
    SELECT
        ST_RemoveRepeatedPoints(geom, 0.001) AS line_geom
    WHERE geom IS NOT NULL
      AND ST_Length(geom) > 0.001
      AND ST_NPoints(ST_RemoveRepeatedPoints(geom, 0.001)) >= 2
),
points AS (
    SELECT
        (dp).path[1] AS pt_idx,
        (dp).geom    AS pt_geom,
        line_geom,
        ST_NPoints(line_geom) AS n_pts
    FROM base
    CROSS JOIN LATERAL ST_DumpPoints(line_geom) AS dp
),
points_nb AS (
    SELECT
        p.*,
        LAG(pt_geom)  OVER (ORDER BY pt_idx) AS prev_pt,
        LEAD(pt_geom) OVER (ORDER BY pt_idx) AS next_pt
    FROM points p
),
tangents AS (
    SELECT
        *,
        CASE
            WHEN prev_pt IS NULL THEN
                (
                    WITH v AS (
                        SELECT
                            ST_X(next_pt) - ST_X(pt_geom) AS dx,
                            ST_Y(next_pt) - ST_Y(pt_geom) AS dy
                    )
                    SELECT ST_MakePoint(
                        dx / sqrt(dx*dx + dy*dy),
                        dy / sqrt(dx*dx + dy*dy)
                    )
                    FROM v
                )
            WHEN next_pt IS NULL THEN
                (
                    WITH v AS (
                        SELECT
                            ST_X(pt_geom) - ST_X(prev_pt) AS dx,
                            ST_Y(pt_geom) - ST_Y(prev_pt) AS dy
                    )
                    SELECT ST_MakePoint(
                        dx / sqrt(dx*dx + dy*dy),
                        dy / sqrt(dx*dx + dy*dy)
                    )
                    FROM v
                )
            ELSE
                (
                    WITH
                    v1 AS (
                        SELECT
                            ST_X(pt_geom) - ST_X(prev_pt) AS dx,
                            ST_Y(pt_geom) - ST_Y(prev_pt) AS dy
                    ),
                    v2 AS (
                        SELECT
                            ST_X(next_pt) - ST_X(pt_geom) AS dx,
                            ST_Y(next_pt) - ST_Y(pt_geom) AS dy
                    ),
                    u1 AS (
                        SELECT
                            dx / sqrt(dx*dx + dy*dy) AS ux,
                            dy / sqrt(dx*dx + dy*dy) AS uy
                        FROM v1
                    ),
                    u2 AS (
                        SELECT
                            dx / sqrt(dx*dx + dy*dy) AS ux,
                            dy / sqrt(dx*dx + dy*dy) AS uy
                        FROM v2
                    ),
                    s AS (
                        SELECT
                            u1.ux + u2.ux AS dx,
                            u1.uy + u2.uy AS dy
                        FROM u1, u2
                    )
                    SELECT
                        CASE
                            WHEN sqrt(dx*dx + dy*dy) < 1e-12 THEN
                                ST_MakePoint(u2.ux, u2.uy)
                            ELSE
                                ST_MakePoint(
                                    dx / sqrt(dx*dx + dy*dy),
                                    dy / sqrt(dx*dx + dy*dy)
                                )
                        END
                    FROM s, u2
                )
        END AS tangent
    FROM points_nb
),
normals AS (
    SELECT
        *,
        ST_MakePoint(
            ST_Y(tangent),
           -ST_X(tangent)
        ) AS normal
    FROM tangents
),
located AS (
    SELECT
        *,
        ST_LineLocatePoint(line_geom, pt_geom) AS s
    FROM normals
),
shifted AS (
    SELECT
        pt_idx,
        ST_Translate(
            pt_geom,
            CASE
                WHEN pin_start AND pt_idx = 1 THEN 0.0
                WHEN pin_end AND pt_idx = n_pts THEN 0.0
                ELSE ((SELECT base_offset FROM scaled) + s * (SELECT transition FROM scaled))
            END * ST_X(normal),
            CASE
                WHEN pin_start AND pt_idx = 1 THEN 0.0
                WHEN pin_end AND pt_idx = n_pts THEN 0.0
                ELSE ((SELECT base_offset FROM scaled) + s * (SELECT transition FROM scaled))
            END * ST_Y(normal)
        ) AS new_pt_geom
    FROM located
)
SELECT
    ST_SetSRID(
        ST_MakeLine(new_pt_geom ORDER BY pt_idx),
        ST_SRID((SELECT line_geom FROM base))
    )::geometry(LineString)
FROM shifted;
$$;

