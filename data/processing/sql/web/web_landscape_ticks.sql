-- QGIS landscape_way MarkerLine (embankment, cliff, earth_bank only; the
-- layer's other classes have no symbol). Every value is data-defined in
-- ground metres, halved for ways shorter than 20 map units ($length is planar,
-- the project ellipsoid is NONE):
--   triangle size 1.6 m (0.8), interval 2.4 m (1.2), first marker 0.8 m (0.4),
--   line offset 0.6 m (0.3) to the left of the way, marker angle 180.
-- A QGIS equilateral_triangle of size s has circumradius s/2 and points to
-- the marker's "up"; rotated with the line and turned by 180 it points away
-- from the way, so the apex is on the outer side and the base faces the way.
-- The marker angle is averaged over +-2 map units of line (QGIS: 4 mm).
-- The line itself is 0.6 m (0.3 m) wide, so the tiles carry the planar length.
ALTER TABLE landscape_way ADD COLUMN IF NOT EXISTS planar_length real;
UPDATE landscape_way SET planar_length = ST_Length(geom);

DROP TABLE IF EXISTS landscape_ticks;
CREATE TABLE landscape_ticks AS
WITH parts AS (
 SELECT osm_id,COALESCE(dump.path[1],1)::integer part_index,dump.geom::geometry(LineString,3857) line_geom,ST_Length(dump.geom) len,
  metres(CASE WHEN ST_Length(landscape_way.geom)<20 THEN 0.5 ELSE 1 END) k
 FROM landscape_way CROSS JOIN LATERAL ST_Dump(geom) dump
 WHERE class IN ('embankment','cliff','earth_bank') AND ST_Length(dump.geom)>0
), m AS (
 SELECT parts.*,i,0.8*k+i*2.4*k d
 FROM parts CROSS JOIN LATERAL generate_series(0,floor((len-0.8*k)/(2.4*k)+1e-9)::integer)i
 WHERE len>=0.8*k
), o AS (
 SELECT m.*,ST_LineInterpolatePoint(line_geom,LEAST(1,d/len))::geometry(Point,3857) p,
  (ST_X(b)-ST_X(a))/ST_Distance(a,b) tx,(ST_Y(b)-ST_Y(a))/ST_Distance(a,b) ty
 FROM m CROSS JOIN LATERAL(SELECT ST_LineInterpolatePoint(line_geom,GREATEST(0,d-2)/len)::geometry(Point,3857)a,ST_LineInterpolatePoint(line_geom,LEAST(len,d+2)/len)::geometry(Point,3857)b)x WHERE ST_Distance(a,b)>0
), c AS (
 -- centre 0.6 m to the left (left normal = (-ty, tx)); circumradius r = 0.8 m
 SELECT o.*,ST_X(p)-ty*0.6*k cx,ST_Y(p)+tx*0.6*k cy,0.8*k r FROM o
)
SELECT row_number() over()::bigint tick_id,osm_id,part_index,i marker_index,
 ST_MakePolygon(ST_MakeLine(ARRAY[
 ST_SetSRID(ST_MakePoint(cx-ty*r,cy+tx*r),3857),
 ST_SetSRID(ST_MakePoint(cx+ty*r*.5+tx*r*.8660254,cy-tx*r*.5+ty*r*.8660254),3857),
 ST_SetSRID(ST_MakePoint(cx+ty*r*.5-tx*r*.8660254,cy-tx*r*.5-ty*r*.8660254),3857),
 ST_SetSRID(ST_MakePoint(cx-ty*r,cy+tx*r),3857)]))::geometry(Polygon,3857) geom FROM c;
ALTER TABLE landscape_ticks ADD PRIMARY KEY(tick_id);
CREATE INDEX landscape_ticks_geom_idx ON landscape_ticks USING gist(geom);
ANALYZE landscape_ticks;
