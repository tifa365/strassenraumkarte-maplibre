-- Materialize QGIS's LinePatternFill hatching of restriction/barred-area
-- road_marking_polygon features (MapLibre has no line-pattern fills).
-- QGIS rules (road_marking_polygon layer):
--   stripes (any pattern except zigzag, x, crosshatch, chessboard, none):
--     0.25 m lines every 0.75 m at lineAngle -direction + 90
--   crosshatch: 0.25 m lines every 1.25 m at -direction + 90 and at -direction
-- lineAngle is in degrees counter-clockwise from the x axis. Lines are
-- clipped to the polygon (clip_mode during_render). zigzag and x patterns are
-- generated as road_marking_way lines elsewhere; chessboard is not ported.

DROP TABLE IF EXISTS road_marking_hatch;

CREATE TABLE road_marking_hatch AS
WITH polygons AS (
    SELECT osm_id, COALESCE(layer, 0) AS layer, colour, geom,
        CASE WHEN pattern = 'crosshatch' THEN metres(1.25) ELSE metres(0.75) END AS spacing,
        unnest(CASE WHEN pattern = 'crosshatch'
                    THEN ARRAY[90 - direction, -direction]
                    ELSE ARRAY[90 - direction] END) AS angle_deg
    FROM road_marking_polygon
    WHERE road_marking IN ('restriction', 'barred_area')
      AND (pattern IS NULL OR pattern NOT IN ('zigzag', 'x', 'chessboard', 'none'))
      AND direction IS NOT NULL
), frames AS (
    SELECT polygons.*, cos(radians(angle_deg)) AS dx, sin(radians(angle_deg)) AS dy,
        ST_X(ST_Centroid(geom)) AS cx, ST_Y(ST_Centroid(geom)) AS cy,
        -- half the bounding-box diagonal: every hatch line through the polygon is shorter
        ST_Distance(ST_PointN(ST_Boundary(ST_Envelope(geom)), 1), ST_PointN(ST_Boundary(ST_Envelope(geom)), 3)) / 2 AS reach
    FROM polygons
), lines AS (
    SELECT frames.osm_id, frames.layer, frames.colour, frames.geom AS polygon,
        ST_MakeLine(
            ST_SetSRID(ST_MakePoint(cx - dy * k * spacing - dx * reach, cy + dx * k * spacing - dy * reach), 3857),
            ST_SetSRID(ST_MakePoint(cx - dy * k * spacing + dx * reach, cy + dx * k * spacing + dy * reach), 3857)
        ) AS line
    FROM frames
    CROSS JOIN LATERAL generate_series(-ceil(reach / spacing)::integer, ceil(reach / spacing)::integer) AS k
)
SELECT row_number() OVER ()::bigint AS hatch_id, osm_id, layer, colour,
    ST_Multi(ST_CollectionExtract(ST_Intersection(line, polygon), 2))::geometry(MultiLineString, 3857) AS geom
FROM lines
WHERE ST_Intersects(line, polygon)
  AND NOT ST_IsEmpty(ST_CollectionExtract(ST_Intersection(line, polygon), 2));

ALTER TABLE road_marking_hatch ADD PRIMARY KEY (hatch_id);
CREATE INDEX road_marking_hatch_geom_idx ON road_marking_hatch USING gist (geom);
ANALYZE road_marking_hatch;
