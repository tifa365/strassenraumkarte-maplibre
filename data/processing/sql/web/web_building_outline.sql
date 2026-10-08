-- web_building_outline.sql — merged outlines of touching buildings.
--
-- QGIS gives every building part a soft drop shadow (a blurred, offset copy
-- of the polygon). MapLibre draws it as a blurred line along the outline
-- (scripts/effects.py); drawn per part, the walls shared by adjacent parts
-- leave dark dots where they meet the outer wall. This table holds the union
-- of each group of touching parts, so the shadow follows only outer walls
-- (and courtyards).

DROP TABLE IF EXISTS building_outline;

CREATE TABLE building_outline AS
WITH clusters AS (
    SELECT geom, ST_ClusterDBSCAN(geom, 0, 1) OVER () AS cid
    FROM building_parts_dissolved_height
)
SELECT row_number() OVER ()::bigint AS outline_id, geom
FROM (
    SELECT (ST_Dump(ST_Union(geom))).geom::geometry(Polygon, 3857) AS geom
    FROM clusters
    GROUP BY cid
) AS merged;

ALTER TABLE building_outline ADD PRIMARY KEY (outline_id);
CREATE INDEX building_outline_geom_idx ON building_outline USING gist (geom);
ANALYZE building_outline;
