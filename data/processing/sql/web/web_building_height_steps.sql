-- web_building_height_steps.sql — walls where a taller building part meets a lower one.
--
-- QGIS draws building_parts_dissolved_height ordered by height, each part with a
-- drop shadow (offset 1 map unit towards 40°) under its fill, so a taller part's
-- shadow falls onto the roofs of lower neighbours. The MapLibre shadow follows
-- only the merged outer outline (web_building_outline.sql); this table holds
-- the shared walls between parts of different height, one row per straight
-- edge, oriented with the lower part on the left (where MapLibre's negative
-- line-offset goes). `facing` is the cosine between the direction into the
-- lower part and the shadow bearing: 1 when the lower part lies north-east of
-- the wall (full shadow), -1 when it lies south-west (only the blur reaches it).
-- scripts/effects.py draws a blurred band into the lower part from these lines.

DROP TABLE IF EXISTS building_height_step;

-- building.sql leaves the table unindexed; the self-join below needs it
CREATE INDEX IF NOT EXISTS building_parts_dissolved_height_geom_idx
    ON building_parts_dissolved_height USING gist (geom);
ANALYZE building_parts_dissolved_height;

CREATE TABLE building_height_step AS
WITH walls AS (
    SELECT lower.geom AS lower_geom,
           (ST_Dump(ST_LineMerge(ST_CollectionExtract(ST_Intersection(upper.geom, lower.geom), 2)))).geom AS geom
    FROM building_parts_dissolved_height AS upper
    JOIN building_parts_dissolved_height AS lower
      ON upper.geom && lower.geom
     AND upper.height > lower.height
     AND ST_Touches(upper.geom, lower.geom)
),
edges AS (
    SELECT lower_geom, (ST_DumpSegments(geom)).geom AS geom
    FROM walls
),
directed AS (
    SELECT lower_geom, geom,
           ST_X(ST_EndPoint(geom)) - ST_X(ST_StartPoint(geom)) AS dx,
           ST_Y(ST_EndPoint(geom)) - ST_Y(ST_StartPoint(geom)) AS dy,
           ST_Length(geom) AS len
    FROM edges
    WHERE ST_Length(geom) > 0
),
oriented AS (
    SELECT CASE WHEN left_inside THEN geom ELSE ST_Reverse(geom) END AS geom,
           CASE WHEN left_inside THEN 1 ELSE -1 END * (-dy / len) AS nx,  -- unit normal into the lower part
           CASE WHEN left_inside THEN 1 ELSE -1 END * (dx / len) AS ny
    FROM (
        SELECT geom, dx, dy, len,
               ST_Intersects(lower_geom, ST_Translate(ST_LineInterpolatePoint(geom, 0.5),
                                                      -dy / len * metres(0.05), dx / len * metres(0.05))) AS left_inside
        FROM directed
    ) AS tested
)
SELECT row_number() OVER ()::bigint AS step_id,
       round((nx * sin(radians(40)) + ny * cos(radians(40)))::numeric, 2)::real AS facing,
       geom::geometry(LineString, 3857) AS geom
FROM oriented;

ALTER TABLE building_height_step ADD PRIMARY KEY (step_id);
CREATE INDEX building_height_step_geom_idx ON building_height_step USING gist (geom);
ANALYZE building_height_step;
