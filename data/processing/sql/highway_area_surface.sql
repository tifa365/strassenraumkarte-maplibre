-- Derive surface for OSM highway_area polygons that lack a surface tag.
-- For each area (source = osm_feature, surface IS NULL), take highway centerlines
-- of the same class (highway = "area:highway") that intersect the polygon,
-- clip them to the area, and assign the length-weighted dominant surface.
--
-- Depends on: highway_area (highway_area_merge.sql); highway (highway_preparation.sql).

WITH candidates AS (
    SELECT
        ha.ctid AS ha_ctid,
        ha."area:highway" AS area_highway,
        ha.geom
    FROM highway_area ha
    WHERE ha.source = 'osm_feature'
      AND ha.surface IS NULL
      AND ha."area:highway" IS NOT NULL
      AND ha.geom IS NOT NULL
      AND NOT ST_IsEmpty(ha.geom)
),
clipped AS (
    SELECT
        c.ha_ctid,
        h.surface,
        ST_Length(
            ST_CollectionExtract(ST_Intersection(h.geom, c.geom), 2)
        ) AS clip_length
    FROM candidates c
    INNER JOIN highway h
        ON h.highway = c.area_highway
       AND h.surface IS NOT NULL
       AND h.geom IS NOT NULL
       AND NOT ST_IsEmpty(h.geom)
       AND c.geom && h.geom
       AND ST_Intersects(c.geom, h.geom)
),
surface_weights AS (
    SELECT
        ha_ctid,
        surface,
        SUM(clip_length) AS total_length
    FROM clipped
    WHERE clip_length > 0
    GROUP BY ha_ctid, surface
),
dominant_surface AS (
    SELECT DISTINCT ON (ha_ctid)
        ha_ctid,
        surface
    FROM surface_weights
    ORDER BY
        ha_ctid,
        total_length DESC,
        surface
)
UPDATE highway_area ha
SET surface = d.surface
FROM dominant_surface d
WHERE ha.ctid = d.ha_ctid;
