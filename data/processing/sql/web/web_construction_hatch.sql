-- Materialize QGIS's "construction" layer hatching (LinePatternFill; MapLibre
-- has no line-pattern fills): lines every 2.2 m at 67 degrees (counter-
-- clockwise from the x axis), clipped to landuse=construction polygons. The
-- style draws them 1 m wide in #ff5300 at alpha 0.35 and the polygon outline
-- 0.4 m at alpha 0.65, both under the layer opacity 0.5.

DROP TABLE IF EXISTS construction_hatch;

CREATE TABLE construction_hatch AS
WITH frames AS (
    SELECT osm_id, geom, metres(2.2) AS spacing,
        cos(radians(67)) AS dx, sin(radians(67)) AS dy,
        ST_X(ST_Centroid(geom)) AS cx, ST_Y(ST_Centroid(geom)) AS cy,
        -- half the bounding-box diagonal: every hatch line through the polygon is shorter
        ST_Distance(ST_PointN(ST_Boundary(ST_Envelope(geom)), 1), ST_PointN(ST_Boundary(ST_Envelope(geom)), 3)) / 2 AS reach
    FROM landuse
    WHERE class = 'construction'
), lines AS (
    SELECT frames.osm_id, frames.geom AS polygon,
        ST_MakeLine(
            ST_SetSRID(ST_MakePoint(cx - dy * k * spacing - dx * reach, cy + dx * k * spacing - dy * reach), 3857),
            ST_SetSRID(ST_MakePoint(cx - dy * k * spacing + dx * reach, cy + dx * k * spacing + dy * reach), 3857)
        ) AS line
    FROM frames
    CROSS JOIN LATERAL generate_series(-ceil(reach / spacing)::integer, ceil(reach / spacing)::integer) AS k
)
SELECT row_number() OVER ()::bigint AS hatch_id, osm_id,
    ST_Multi(ST_CollectionExtract(ST_Intersection(line, polygon), 2))::geometry(MultiLineString, 3857) AS geom
FROM lines
WHERE ST_Intersects(line, polygon)
  AND NOT ST_IsEmpty(ST_CollectionExtract(ST_Intersection(line, polygon), 2));

ALTER TABLE construction_hatch ADD PRIMARY KEY (hatch_id);
CREATE INDEX construction_hatch_geom_idx ON construction_hatch USING gist (geom);
ANALYZE construction_hatch;
