-- web_landuse_area.sql — ellipsoidal polygon area for draw ordering.
-- The QGIS "landuse" layer sorts features by $area descending, so smaller
-- polygons (e.g. forest) paint over larger overlapping ones (e.g. park).
-- MapLibre has no feature-order control other than a sort key, so the vector
-- tile carries the area and the style sets fill-sort-key = -area.

ALTER TABLE landuse
    ADD COLUMN IF NOT EXISTS area real;

UPDATE landuse
SET area = ST_Area(ST_Transform(geom, 4326)::geography)
WHERE area IS NULL;
