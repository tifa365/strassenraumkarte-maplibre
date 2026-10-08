-- web_highway_area_outline.sql — merged carriageway outlines per bridge/tunnel layer.
--
-- QGIS darkens the carriageway edges with an innerShadow on the z14..z20
-- "blur" layers. The effect runs on the whole rendered layer, so edges where
-- two highway_area polygons touch are not shaded. MapLibre draws the shade as
-- blurred lines along polygon rings (web/style.json highway-area-edge-shade*),
-- which would shade every such seam; this table holds the union of the QGIS
-- layers' polygons per layer value (strata as in build_maplibre_strata.py:
-- <= -2, -1, 0, 1, 2, >= 3), so only the outer edges remain.
--
-- The connected network merges into very large polygons (over a million
-- vertices), so the table stores their rings as lines split into pieces of
-- at most 256 vertices, which keeps tiles cheap and adds no seams. Rings are
-- forced clockwise (exterior) / counter-clockwise (holes) first: the road
-- then lies right of every line, where MapLibre's positive line-offset goes.

DROP TABLE IF EXISTS highway_area_outline;

CREATE TABLE highway_area_outline AS
WITH roads AS (
    SELECT LEAST(GREATEST(COALESCE(layer, 0), -2), 3) AS layer, geom
    FROM highway_area
    WHERE "area:highway" IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link',
                             'residential', 'unclassified', 'road', 'bus_bay', 'turning_circle', 'turning_loop')
       OR ("area:highway" = 'parking' AND class IN ('primary', 'primary_link', 'secondary', 'secondary_link',
                                                    'tertiary', 'tertiary_link', 'residential', 'unclassified',
                                                    'road', 'bus_bay', 'turning_circle', 'turning_loop'))
),
clusters AS (
    SELECT layer, geom, ST_ClusterDBSCAN(geom, 0, 1) OVER (PARTITION BY layer) AS cid
    FROM roads
),
merged AS (
    SELECT layer, ST_ForcePolygonCW((ST_Dump(ST_Union(geom))).geom) AS geom
    FROM clusters
    GROUP BY layer, cid
),
rings AS (
    SELECT layer, (ST_Dump(ST_Boundary(geom))).geom AS geom
    FROM merged
)
SELECT row_number() OVER ()::bigint AS outline_id, layer, piece::geometry(LineString, 3857) AS geom
FROM rings, ST_Subdivide(geom, 256) AS piece;

ALTER TABLE highway_area_outline ADD PRIMARY KEY (outline_id);
CREATE INDEX highway_area_outline_geom_idx ON highway_area_outline USING gist (geom);
ANALYZE highway_area_outline;
