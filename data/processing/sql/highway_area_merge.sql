-- highway_area_merge.sql — merge centerline highway_areas into highway_area (OSM polygons).
-- Depends on: highway_areas (highway_area_centerline_junctions.sql).
-- OSM highway_area rows already have source = osm_feature from import (osm_import.lua).

INSERT INTO highway_area (
    osm_type,
    osm_id,
    source,
    "area:highway",
    surface,
    "sett:length",
    type,
    class,
    markings,
    direction,
    temporary,
    symbol,
    tunnel,
    hierarchy,
    layer,
    geom
)
SELECT
    ha.osm_type,
    ha.osm_id,
    'centerline'::text AS source,
    ha.highway,
    ha.surface,
    ha."sett:length",
    ha.type,
    NULL::text AS class,
    NULL::text AS markings,
    NULL::real AS direction,
    NULL::text AS temporary,
    NULL::text AS symbol,
    ha.tunnel,
    ha.hierarchy,
    ha.layer,
    dumped.geom
FROM highway_areas ha
CROSS JOIN LATERAL ST_Dump(ha.geom) AS dumped(path, geom)
WHERE dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_Polygon';

DROP TABLE IF EXISTS highway_areas;

DROP INDEX IF EXISTS highway_area_geom_idx;
CREATE INDEX highway_area_geom_idx ON highway_area USING GIST (geom);
