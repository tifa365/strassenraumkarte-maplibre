-- road_marking_colour.sql — surface colour polygons for lanes and area:highway
-- Requires: lanes_clipped (road_marking_lanes_prepare.sql), highway_area (highway_area_merge.sql)
-- Output: road_marking_polygon (road_marking = surface_colour)
-- Clipped at crossings by road_marking_crossing.sql §7.5c (foreign zones only for same osm_id)

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'


----------------------------------------------------------------------
-- §1) Lane centreline colours → merge → buffered polygons (lane_colour)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _markings_raw;
CREATE TEMP TABLE _markings_raw AS
SELECT
    'lane_colour'::text AS road_marking,
    lc.osm_id,
    NULL::text AS type,
    NULL::text AS side,
    NULL::text AS stroke,
    lc.width::numeric AS width,
    NULL::text AS arrow,
    lc.colour,
    lc.layer,
    NULL::text AS preset_dasharray,
    lc.width AS lane_width,
    lc.geom
FROM lanes_clipped lc
WHERE lc.colour IS NOT NULL
  AND lc.colour NOT IN ('no', 'none')
  AND lc.geom IS NOT NULL
  AND NOT ST_IsEmpty(lc.geom)
  AND ST_GeometryType(lc.geom) = 'ST_LineString'
  AND lc.width IS NOT NULL
  AND lc.width > 2.0 * :'lane_colour_edge_inset'::double precision;

CREATE INDEX _markings_raw_idx ON _markings_raw (road_marking, osm_id);

DELETE FROM _markings_raw
WHERE geom IS NULL
   OR ST_IsEmpty(geom)
   OR ST_GeometryType(geom) <> 'ST_LineString';

\i 'processing/sql/helper/road_marking_merge_connected_markings.sql'

INSERT INTO road_marking_polygon (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    'lane_colour'::text,
    'surface_colour'::text,
    'W'::text,
    m.osm_id,
    NULL::text,
    NULL::text,
    NULL::text,
    NULL::text,
    m.width::real,
    NULL::real,
    m.colour,
    NULL::real,
    m.type,
    lc.class,
    m.layer,
    NULL::text,
    ST_Buffer(
        m.geom,
        metres(m.width / 2.0 - :'lane_colour_edge_inset'::double precision),
        'endcap=flat join=round'
    ) AS geom
FROM _markings_merged m
LEFT JOIN LATERAL (
    SELECT lc2.class
    FROM lanes_clipped lc2
    WHERE lc2.osm_id = m.osm_id
      AND lc2.colour IS NOT DISTINCT FROM m.colour
      AND lc2.width IS NOT DISTINCT FROM m.width
      AND lc2.layer IS NOT DISTINCT FROM m.layer
    ORDER BY ST_Length(lc2.geom) DESC
    LIMIT 1
) lc ON true
WHERE m.road_marking = 'lane_colour'
  AND m.geom IS NOT NULL
  AND NOT ST_IsEmpty(m.geom)
  AND ST_GeometryType(m.geom) = 'ST_LineString'
  AND m.width IS NOT NULL
  AND m.width > 2.0 * :'lane_colour_edge_inset'::double precision
  AND ST_Area(
      ST_Buffer(
          m.geom,
          metres(m.width / 2.0 - :'lane_colour_edge_inset'::double precision),
          'endcap=flat join=round'
      )
  ) > 0.01;

DROP TABLE IF EXISTS _markings_raw;
DROP TABLE IF EXISTS _markings_raw_seg;
DROP TABLE IF EXISTS _markings_endpoints;
DROP TABLE IF EXISTS _markings_merged;


----------------------------------------------------------------------
-- §2) area:highway polygons with surface:colour (source = highway_area_colour)
----------------------------------------------------------------------

INSERT INTO road_marking_polygon (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    'highway_area_colour'::text,
    'surface_colour'::text,
    ha.osm_type,
    ha.osm_id,
    NULL::text,
    NULL::text,
    NULL::text,
    NULL::text,
    NULL::real,
    NULL::real,
    ha."surface:colour",
    NULL::real,
    ha."area:highway",
    NULL::text,
    ha.layer,
    NULL::text,
    ha.geom
FROM highway_area ha
WHERE ha."surface:colour" IS NOT NULL
  AND ha."surface:colour" NOT IN ('no', 'none')
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
  AND ST_GeometryType(ha.geom) IN ('ST_Polygon', 'ST_MultiPolygon')
  AND ST_Area(ha.geom) > 0.01;
