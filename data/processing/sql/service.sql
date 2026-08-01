-- dissolves service ways for better rendering
-- groups by class (OSM service=* tag, filled in osm_import.lua) plus width and layer

DROP TABLE IF EXISTS highway_service;

CREATE TABLE highway_service AS
SELECT
    class, width, layer,
    (ST_Dump(ST_LineMerge(ST_Union(geom)))).geom AS geom
FROM highway
WHERE highway = 'service'
GROUP BY class, width, layer;

CREATE INDEX highway_service_geom_idx ON highway_service USING GIST (geom);
