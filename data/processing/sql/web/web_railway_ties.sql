-- Materialize QGIS railway HashLine ties ("railway tie" layer): one
-- perpendicular 0.3 m bar every 0.9 m, 2.6 map units long, square caps, no
-- ties in tunnels. (The project's gauge-based length is a data-defined
-- "lineDistance", which a HashLine does not read -- its key is "hashLength" --
-- so QGIS draws the static 2.6 map units; checked against a z19 render.)
-- Disused/abandoned/construction tracks use the lighter colour (disused flag).

DROP TABLE IF EXISTS railway_ties;

CREATE TABLE railway_ties AS
WITH parts AS (
    SELECT railway_way.osm_id, COALESCE(railway_way.layer, 0) AS layer,
        railway_way.railway IN ('abandoned', 'construction', 'disused') AS disused,
        metres(0.9) AS interval_m,
        2.6 + metres(0.3) AS tie_length_m,
        metres(0.3) AS tie_width_m,
        COALESCE(dump.path[1], 1)::integer AS part_index,
        dump.geom::geometry(LineString, 3857) AS line_geom, ST_Length(dump.geom) AS line_length
    FROM railway_way CROSS JOIN LATERAL ST_Dump(railway_way.geom) AS dump
    WHERE ST_Length(dump.geom) > 0
      AND railway_way.tunnel IS DISTINCT FROM 'yes'
), markers AS (
    SELECT parts.*, marker_index, marker_index * interval_m AS distance_along,
        ST_LineInterpolatePoint(line_geom, marker_index * interval_m / line_length)::geometry(Point,3857) AS point
    FROM parts CROSS JOIN LATERAL generate_series(0, floor((line_length-1e-9)/interval_m)::integer) AS marker_index
), oriented AS (
    SELECT markers.*, (ST_X(p2)-ST_X(p1))/ST_Distance(p1,p2) AS tx, (ST_Y(p2)-ST_Y(p1))/ST_Distance(p1,p2) AS ty
    FROM markers CROSS JOIN LATERAL (
        SELECT ST_LineInterpolatePoint(line_geom,GREATEST(0,distance_along-2)/line_length)::geometry(Point,3857) AS p1,
               ST_LineInterpolatePoint(line_geom,LEAST(line_length,distance_along+2)/line_length)::geometry(Point,3857) AS p2
    ) angle WHERE ST_Distance(p1,p2)>0
)
SELECT row_number() OVER (ORDER BY osm_id,part_index,marker_index)::bigint AS tie_id,
    osm_id,layer,disused,part_index,marker_index,
    ST_MakePolygon(ST_MakeLine(ARRAY[
      ST_SetSRID(ST_MakePoint(ST_X(point)+ty*tie_length_m/2-tx*tie_width_m/2,ST_Y(point)-tx*tie_length_m/2-ty*tie_width_m/2),3857),
      ST_SetSRID(ST_MakePoint(ST_X(point)-ty*tie_length_m/2-tx*tie_width_m/2,ST_Y(point)+tx*tie_length_m/2-ty*tie_width_m/2),3857),
      ST_SetSRID(ST_MakePoint(ST_X(point)-ty*tie_length_m/2+tx*tie_width_m/2,ST_Y(point)+tx*tie_length_m/2+ty*tie_width_m/2),3857),
      ST_SetSRID(ST_MakePoint(ST_X(point)+ty*tie_length_m/2+tx*tie_width_m/2,ST_Y(point)-tx*tie_length_m/2+ty*tie_width_m/2),3857),
      ST_SetSRID(ST_MakePoint(ST_X(point)+ty*tie_length_m/2-tx*tie_width_m/2,ST_Y(point)-tx*tie_length_m/2-ty*tie_width_m/2),3857)
    ]))::geometry(Polygon,3857) AS geom
FROM oriented;
ALTER TABLE railway_ties ADD PRIMARY KEY (tie_id);
CREATE INDEX railway_ties_geom_idx ON railway_ties USING gist (geom);
ANALYZE railway_ties;
