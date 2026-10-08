-- web_landuse_texture.sql — visible part of every textured landuse polygon.
--
-- QGIS's "landuse" layer draws feature by feature, ordered by $area (smaller
-- polygons on top), and each feature's symbol is its opaque fill plus its
-- texture. A smaller polygon's fill therefore covers the texture of a larger
-- one below it, so every pixel shows exactly one texture: the topmost
-- polygon's. MapLibre draws a whole layer at a time (all fills, then all
-- textures), so overlapping polygons stacked their textures (88 % of Berlin's
-- grass lies inside parks: the grass texture came out twice as strong) and a
-- park's texture showed through the parking lots and buildings' yards drawn on
-- top of it. The style's texture layers read this table instead: each textured
-- polygon minus all smaller overlapping landuse polygons.

DROP TABLE IF EXISTS landuse_texture;

CREATE TABLE landuse_texture AS
SELECT l.osm_id, l.class,
    ST_Multi(ST_CollectionExtract(
        CASE WHEN above.geom IS NULL THEN l.geom
             ELSE ST_Difference(ST_MakeValid(l.geom), above.geom) END, 3
    ))::geometry(MultiPolygon, 3857) AS geom
FROM landuse AS l
LEFT JOIN LATERAL (
    SELECT ST_Union(ST_MakeValid(s.geom)) AS geom
    FROM landuse AS s
    WHERE s.geom && l.geom
      AND s.area < l.area
      AND ST_Intersects(s.geom, l.geom)
) AS above ON true
WHERE l.class IN (
    -- the classes of the style's landuse-*-texture layers
    'allotments', 'bbq', 'biergarten', 'cemetery', 'dog_park', 'flowerbed', 'garden', 'grass',
    'greenery', 'park', 'recreation_ground', 'tree_pit', 'village_green',
    'forest', 'grassland', 'heath', 'meadow', 'orchard', 'plant_nursery', 'scrub', 'shrub',
    'shrubbery', 'trees', 'tundra', 'vineyard', 'wood',
    'basin', 'beach', 'dune', 'salt_pond', 'sand',
    'bare_rock', 'gravel', 'landfill', 'quarry', 'railway', 'rock', 'scree',
    'blockfield', 'shingle',
    'glacier', 'reef', 'shoal', 'swimming_pool', 'mud',
    'woodchips'
);

DELETE FROM landuse_texture WHERE geom IS NULL OR ST_IsEmpty(geom);
ALTER TABLE landuse_texture ADD COLUMN texture_id bigserial PRIMARY KEY;
CREATE INDEX landuse_texture_geom_idx ON landuse_texture USING gist (geom);
ANALYZE landuse_texture;
