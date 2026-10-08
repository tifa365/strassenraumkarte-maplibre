-- Separately mapped roadside parking.  Off-street lots are deliberately not
-- expanded; only objects explicitly positioned on the street are eligible.
SET search_path TO :"schema", public;

DROP TABLE IF EXISTS separate_parking_lines;
CREATE TABLE separate_parking_lines (
  osm_type text NOT NULL, osm_id bigint NOT NULL, source_type text NOT NULL,
  side text, parking text, orientation text, width_m numeric, mapped_capacity numeric,
  condition_class text, vehicle_designated text, vehicle_excluded text, markings text, markings_type text,
  geom_utm geometry(LineString,25833) NOT NULL
);

-- A mapped parking_space node is one space.  Other explicitly roadside nodes
-- are represented by a line so that the normal overlap cut can remove inferred
-- parking at the same location.
INSERT INTO separate_parking_lines
SELECT 'node',n.osm_id,'separate_node',NULL,
       COALESCE(n.tags->>'parking','street_side'),
       CASE WHEN COALESCE(n.tags->>'parking:orientation',n.tags->>'orientation') IN ('parallel','diagonal','perpendicular') THEN COALESCE(n.tags->>'parking:orientation',n.tags->>'orientation') ELSE 'parallel' END,
       COALESCE(parking_number(n.tags->>'width'),2),1,
       parking_condition_class(n.tags,'separate'), parking_vehicle_designated(n.tags,'separate'), parking_vehicle_excluded(n.tags,'separate'), n.tags->>'markings', n.tags->>'markings:type',
       ST_MakeLine(
         ST_Translate(p,cos(az+pi()/2)*-1.25,sin(az+pi()/2)*-1.25),
         ST_Translate(p,cos(az+pi()/2)*1.25,sin(az+pi()/2)*1.25))
FROM raw_nodes n
CROSS JOIN LATERAL (SELECT ST_Transform(ST_SetSRID(n.geom,3857),25833) AS p) q
CROSS JOIN LATERAL (SELECT r.geom_utm,ST_ClosestPoint(r.geom_utm,q.p) AS cp,
                           ST_Azimuth(ST_StartPoint(r.geom_utm),ST_EndPoint(r.geom_utm)) AS az
                    FROM source_roads r
                    WHERE r.geom_utm && ST_Expand(q.p,20) AND ST_DWithin(r.geom_utm,q.p,20)
                    ORDER BY r.geom_utm <-> q.p LIMIT 1) road
WHERE n.tags->>'amenity'='parking_space'
   OR n.tags->>'parking:position' IN ('lane','street_side','kerb_extension')
   OR n.tags->>'parking'='street_side';

-- Convert roadside parking polygons by retaining boundary segments parallel to
-- the nearest road.  Features without such a segment remain diagnostics.
-- Eligibility and the median/lane_centre exclusion mirror street_parking.py's
-- processSeparateParkingAreas: amenity=parking alone (an ordinary off-street
-- lot) is NOT eligible; it additionally needs one of the roadside `parking`
-- values, matching the plan's "do not expand into off-street car parks" rule.
WITH polys AS (
 SELECT w.osm_id,w.tags,ST_MakePolygon(ST_AddPoint(ST_Transform(ST_SetSRID(w.geom,3857),25833),ST_StartPoint(ST_Transform(ST_SetSRID(w.geom,3857),25833)))) AS poly
 FROM raw_ways w WHERE w.is_area AND ST_IsClosed(w.geom)
   AND w.tags->>'amenity'='parking'
   AND w.tags->>'parking' IN ('street_side','lane','on_kerb','half_on_kerb','shoulder')
   AND COALESCE(w.tags->>'location','') NOT IN ('lane_centre','median')
), edges AS (
 -- ST_Boundary(polygon) is one closed ring LineString; ST_Dump on it yields
 -- that whole ring as a single (degenerate, start=end) "edge", not its
 -- individual sides. Walk consecutive ST_DumpPoints instead so each side of
 -- the ring becomes its own edge with a well-defined azimuth.
 SELECT p.osm_id, p.tags, p.poly, e.edge,
        ST_Azimuth(ST_StartPoint(e.edge),ST_EndPoint(e.edge)) AS edge_az
 FROM polys p CROSS JOIN LATERAL (
   SELECT ST_MakeLine(pt,next_pt) AS edge
   FROM (
     SELECT (dp).geom AS pt, lead((dp).geom) OVER (ORDER BY (dp).path) AS next_pt
     FROM ST_DumpPoints(ST_Boundary(p.poly)) dp
   ) s
   WHERE next_pt IS NOT NULL
 ) e
), nearest AS (
 SELECT e.*,r.highway,r.name,r.oneway,
        ST_Azimuth(ST_StartPoint(r.geom_utm),ST_EndPoint(r.geom_utm)) AS road_az
 FROM edges e LEFT JOIN LATERAL (SELECT * FROM source_roads r ORDER BY r.geom_utm <-> e.edge LIMIT 1) r ON true
), selected AS (
 SELECT *,LEAST(abs(atan2(sin(edge_az-road_az),cos(edge_az-road_az))),
                pi()-abs(atan2(sin(edge_az-road_az),cos(edge_az-road_az)))) * 180/pi() AS diff
 FROM nearest WHERE ST_Length(edge)>1.7
), outer_edges AS (
 -- The reference implementation's "outer" line selection (edge direction
 -- within 25 degrees of the nearest road, or an explicit orientation tag).
 SELECT osm_id, tags, poly, edge FROM selected WHERE diff<=25 OR tags->>'orientation' IS NOT NULL
), dissolved AS (
 -- Dissolve touching/near-parallel outer edges of the same polygon into as
 -- few pieces as possible before splitting into points, mirroring the
 -- reference's per-id dissolve + multiparttosingleparts. Without this, a lot
 -- with two connected qualifying boundary segments would otherwise be
 -- treated as two independent parking lines instead of one.
 -- When every boundary edge qualifies (common for small/round lots), the
 -- merge reforms the whole closed ring, whose start point equals its end
 -- point; ST_Azimuth on that is undefined downstream, silently dropping the
 -- piece entirely. Open such rings by dropping the duplicated closing vertex.
 SELECT osm_id,
        CASE WHEN ST_IsClosed(merged) THEN ST_RemovePoint(merged,ST_NPoints(merged)-1) ELSE merged END AS edge
 FROM (SELECT osm_id, (ST_Dump(ST_LineMerge(ST_Collect(edge)))).geom AS merged
       FROM outer_edges GROUP BY osm_id) m
), pieces AS (
 SELECT d.osm_id, o.tags, o.poly, d.edge
 FROM dissolved d
 JOIN (SELECT DISTINCT osm_id, tags, poly FROM outer_edges) o USING (osm_id)
 WHERE ST_Length(d.edge) > 1.7
), repaired AS (
 -- The merged piece's own azimuth can differ slightly from any single source
 -- edge; re-match it to the nearest road so the parallel/perpendicular/
 -- diagonal fallback below still reflects the final geometry.
 SELECT p.*, r.road_az,
        LEAST(abs(atan2(sin(ST_Azimuth(ST_StartPoint(p.edge),ST_EndPoint(p.edge))-r.road_az),cos(ST_Azimuth(ST_StartPoint(p.edge),ST_EndPoint(p.edge))-r.road_az))),
              pi()-abs(atan2(sin(ST_Azimuth(ST_StartPoint(p.edge),ST_EndPoint(p.edge))-r.road_az),cos(ST_Azimuth(ST_StartPoint(p.edge),ST_EndPoint(p.edge))-r.road_az)))) * 180/pi() AS diff
 FROM pieces p
 LEFT JOIN LATERAL (SELECT ST_Azimuth(ST_StartPoint(r.geom_utm),ST_EndPoint(r.geom_utm)) AS road_az
                    FROM source_roads r ORDER BY r.geom_utm <-> p.edge LIMIT 1) r ON true
)
INSERT INTO separate_parking_lines
SELECT 'way',osm_id,'separate_area',NULL,COALESCE(tags->>'parking','street_side'),
       CASE WHEN tags->>'orientation' IN ('parallel','diagonal','perpendicular') THEN tags->>'orientation'
            ELSE CASE WHEN diff<=25 THEN 'parallel' WHEN COALESCE(parking_number(tags->>'width'),0)>=4.75 THEN 'perpendicular' ELSE 'diagonal' END END,
       COALESCE(parking_number(tags->>'width'),CASE WHEN diff<=25 THEN 2 WHEN parking_number(tags->>'width')>=4.75 THEN 5 ELSE 4.5 END),
       CASE WHEN tags->>'capacity' IS NULL AND tags->>'orientation' IS NULL THEN floor(ST_Area(poly)/12) ELSE parking_number(tags->>'capacity') END,
       parking_condition_class(tags,'separate'),parking_vehicle_designated(tags,'separate'),parking_vehicle_excluded(tags,'separate'),tags->>'markings',tags->>'markings:type',edge
FROM repaired;

DROP TABLE IF EXISTS unconvertible_separate_parking;
CREATE TABLE unconvertible_separate_parking AS
SELECT w.osm_type,w.osm_id,w.tags,'no_parallel_boundary'::text AS reason,w.geom
FROM raw_ways w
WHERE w.is_area AND w.tags->>'amenity'='parking'
  AND w.tags->>'parking' IN ('street_side','lane','on_kerb','half_on_kerb','shoulder')
  AND COALESCE(w.tags->>'location','') NOT IN ('lane_centre','median')
  AND NOT EXISTS (SELECT 1 FROM separate_parking_lines s WHERE s.osm_id=w.osm_id AND s.source_type='separate_area');
CREATE INDEX separate_parking_lines_geom_idx ON separate_parking_lines USING gist(geom_utm);
CREATE INDEX unconvertible_separate_geom_idx ON unconvertible_separate_parking USING gist(geom);
ANALYZE separate_parking_lines;
INSERT INTO diagnostics(stage,osm_type,osm_id,code,detail)
SELECT 'separate',osm_type,osm_id,'unconvertible_polygon',reason FROM unconvertible_separate_parking;

-- Remove inferred parking covered by separately mapped roadside spaces.
DROP TABLE IF EXISTS parking_lane_final;
CREATE TABLE parking_lane_final AS
SELECT c.*,(d).geom AS cut_geom
FROM parking_lane_cut2 c
LEFT JOIN LATERAL (SELECT ST_UnaryUnion(ST_Collect(ST_Buffer(s.geom_utm,2))) AS geom
                   FROM separate_parking_lines s
                   WHERE s.geom_utm && ST_Expand(c.geom_utm,3) AND ST_DWithin(s.geom_utm,c.geom_utm,3)) x ON true
CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(CASE WHEN x.geom IS NULL THEN c.geom_utm ELSE ST_Difference(c.geom_utm,x.geom) END,2)) d
WHERE ST_Length((d).geom)>0.01;
ALTER TABLE parking_lane_final DROP COLUMN geom_utm;
ALTER TABLE parking_lane_final RENAME COLUMN cut_geom TO geom_utm;
CREATE INDEX parking_lane_final_geom_idx ON parking_lane_final USING gist(geom_utm);
