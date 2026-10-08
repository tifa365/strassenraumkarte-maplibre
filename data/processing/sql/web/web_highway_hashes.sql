-- Materialize QGIS HashLine symbols for steps and access aisles.
-- Hashes are perpendicular to each source-line part. QGIS values (path (way,
-- fill) rules "steps" and "access_aisle"):
--   steps: every 0.6 m, 1.8 map units long, stroke 0.06 m #979c90
--   access aisles: every 1.0 m, 2 map units long, stroke 0.5 m #ffffea
-- The project's length expressions are data-defined "lineDistance", which a
-- HashLine does not read (its key is "hashLength"), so QGIS draws the static
-- lengths in map units (confirmed for railway ties on a z19 render).
-- Strokes have square caps, so each hash is stroke width longer than its length.

DROP TABLE IF EXISTS highway_hashes;

CREATE TABLE highway_hashes AS
WITH parts AS (
    SELECT
        highway.segment_id, COALESCE(highway.layer, 0) AS layer,
        CASE WHEN highway.highway = 'steps' THEN 'steps' ELSE 'access_aisle' END AS kind,
        metres(CASE WHEN highway.highway = 'steps' THEN 0.6 ELSE 1.0 END) AS interval_m,
        CASE WHEN highway.highway = 'steps' THEN 1.8 ELSE 2.0 END
            + metres(CASE WHEN highway.highway = 'steps' THEN 0.06 ELSE 0.5 END) AS hash_length_m,
        metres(CASE WHEN highway.highway = 'steps' THEN 0.06 ELSE 0.5 END) AS hash_width_m,
        COALESCE(dump.path[1], 1)::integer AS part_index,
        dump.geom::geometry(LineString, 3857) AS line_geom,
        ST_Length(dump.geom) AS line_length
    FROM highway
    CROSS JOIN LATERAL ST_Dump(highway.geom) AS dump
    WHERE (highway.highway = 'steps' OR highway.class = 'access_aisle')
      AND COALESCE(highway.tunnel, '') <> 'yes'
      AND ST_Length(dump.geom) > 0
), markers AS (
    SELECT parts.*, marker_index, marker_index * interval_m AS distance_along,
        ST_LineInterpolatePoint(line_geom, marker_index * interval_m / line_length)::geometry(Point,3857) AS point
    FROM parts
    CROSS JOIN LATERAL generate_series(0, floor((line_length - 1e-9) / interval_m)::integer) AS marker_index
), oriented AS (
    SELECT markers.*,
        (ST_X(p2)-ST_X(p1))/ST_Distance(p1,p2) AS tx,
        (ST_Y(p2)-ST_Y(p1))/ST_Distance(p1,p2) AS ty
    FROM markers
    CROSS JOIN LATERAL (
        SELECT ST_LineInterpolatePoint(line_geom, GREATEST(0,distance_along-0.5)/line_length)::geometry(Point,3857) AS p1,
               ST_LineInterpolatePoint(line_geom, LEAST(line_length,distance_along+0.5)/line_length)::geometry(Point,3857) AS p2
    ) angle
    WHERE ST_Distance(p1,p2)>0
)
SELECT row_number() OVER (ORDER BY segment_id,part_index,marker_index)::bigint AS hash_id,
    segment_id, layer, kind, part_index, marker_index,
    ST_MakePolygon(ST_MakeLine(ARRAY[
        ST_SetSRID(ST_MakePoint(ST_X(point)+ty*hash_length_m/2-tx*hash_width_m/2,ST_Y(point)-tx*hash_length_m/2-ty*hash_width_m/2),3857),
        ST_SetSRID(ST_MakePoint(ST_X(point)-ty*hash_length_m/2-tx*hash_width_m/2,ST_Y(point)+tx*hash_length_m/2-ty*hash_width_m/2),3857),
        ST_SetSRID(ST_MakePoint(ST_X(point)-ty*hash_length_m/2+tx*hash_width_m/2,ST_Y(point)+tx*hash_length_m/2+ty*hash_width_m/2),3857),
        ST_SetSRID(ST_MakePoint(ST_X(point)+ty*hash_length_m/2+tx*hash_width_m/2,ST_Y(point)-tx*hash_length_m/2+ty*hash_width_m/2),3857),
        ST_SetSRID(ST_MakePoint(ST_X(point)+ty*hash_length_m/2-tx*hash_width_m/2,ST_Y(point)-tx*hash_length_m/2-ty*hash_width_m/2),3857)
    ]))::geometry(Polygon,3857) AS geom
FROM oriented;

ALTER TABLE highway_hashes ADD PRIMARY KEY (hash_id);
CREATE INDEX highway_hashes_geom_idx ON highway_hashes USING gist (geom);
ANALYZE highway_hashes;
