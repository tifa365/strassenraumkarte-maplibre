-- Obstruction cuts are intentionally performed before the final capacity pass.
SET search_path TO :"schema", public;

DROP TABLE IF EXISTS parking_obstructions;
CREATE TABLE parking_obstructions AS
SELECT 'crossing'::text AS kind, NULL::text AS side, NULL::text AS road_name, ST_Transform(ST_SetSRID(geom,3857),25833) AS geom_utm,
       CASE WHEN tags->>'crossing' IN ('zebra','traffic_signals') OR tags->>'crossing_ref'='zebra' THEN 4.5
            WHEN tags->>'crossing'='marked' THEN 2 ELSE 0 END::double precision AS radius_m
FROM raw_nodes WHERE tags->>'highway'='crossing' OR tags->>'crossing' IS NOT NULL
UNION ALL
SELECT 'crossing_protected',CASE WHEN COALESCE(tags->>'crossing:kerb_extension',tags->>'crossing:buffer_marking',tags->>'crossing:buffer_protection') IN ('left','right') THEN COALESCE(tags->>'crossing:kerb_extension',tags->>'crossing:buffer_marking',tags->>'crossing:buffer_protection') END,NULL,ST_Transform(ST_SetSRID(geom,3857),25833),3 FROM raw_nodes
WHERE tags->>'crossing:kerb_extension' IN ('left','right','both') OR tags->>'crossing:buffer_marking' IN ('left','right','both') OR tags->>'crossing:buffer_protection' IN ('left','right','both')
UNION ALL
SELECT 'signal',CASE tags->>'traffic_signals:direction' WHEN 'forward' THEN 'right' WHEN 'backward' THEN 'left' END,NULL,ST_Transform(ST_SetSRID(geom,3857),25833),0 FROM raw_nodes WHERE tags->>'highway'='traffic_signals'
UNION ALL
SELECT 'turning',NULL,NULL,ST_Transform(ST_SetSRID(geom,3857),25833),CASE WHEN tags->>'highway'='turning_loop' THEN 15 ELSE 10 END
FROM raw_nodes WHERE tags->>'highway' IN ('turning_circle','turning_loop')
UNION ALL
SELECT 'bus_stop',NULL,r.name,ST_Transform(ST_SetSRID(n.geom,3857),25833),15
FROM raw_nodes n LEFT JOIN LATERAL (SELECT name FROM source_roads r ORDER BY r.geom_utm <-> ST_Transform(ST_SetSRID(n.geom,3857),25833) LIMIT 1) r ON true
WHERE n.tags->>'highway'='bus_stop'
UNION ALL
SELECT 'obstacle',NULL,NULL,ST_Transform(ST_SetSRID(geom,3857),25833),2 FROM raw_nodes
WHERE tags->>'obstacle:parking'='yes' OR tags->>'amenity' IN ('bicycle_parking','motorcycle_parking','bicycle_rental','mobility_hub')
UNION ALL
SELECT 'obstacle_area',NULL,NULL,ST_Transform(ST_SetSRID(geom,3857),25833),1.6 FROM raw_ways
WHERE tags->>'obstacle:parking'='yes' OR tags->>'leisure'='parklet' OR tags->>'traffic_calming'='kerb_extension'
   OR tags->>'amenity' IN ('bicycle_parking','motorcycle_parking','bicycle_rental','mobility_hub');
CREATE INDEX parking_obstructions_geom_idx ON parking_obstructions USING gist(geom_utm);

DROP TABLE IF EXISTS parking_lane_cut;
CREATE TABLE parking_lane_cut AS
SELECT f.*, (d).geom AS cut_geom, row_number() OVER (PARTITION BY f.source_key ORDER BY ST_AsEWKB((d).geom)) AS cut_index
FROM parking_lane_fragments f
LEFT JOIN LATERAL (
    SELECT ST_UnaryUnion(ST_Collect(ST_Buffer(o.geom_utm,o.radius_m))) AS geom
    FROM parking_obstructions o
    WHERE o.geom_utm && ST_Expand(f.geom_utm,20)
      AND ST_DWithin(o.geom_utm,f.geom_utm,20)
      AND (o.side IS NULL OR o.side=f.side)
      AND (o.kind <> 'bus_stop' OR o.road_name IS NULL OR o.road_name=f.name)
) b ON true
CROSS JOIN LATERAL ST_Dump(
  ST_CollectionExtract(CASE WHEN b.geom IS NULL THEN f.geom_utm ELSE ST_Difference(f.geom_utm,b.geom) END,2)
) d
WHERE ST_Length((d).geom) > 0.01;
ALTER TABLE parking_lane_cut DROP COLUMN geom_utm;
ALTER TABLE parking_lane_cut RENAME COLUMN cut_geom TO geom_utm;
CREATE INDEX parking_lane_cut_geom_idx ON parking_lane_cut USING gist(geom_utm);

-- Intersections and driveways: keep the road network's original width rules.
DROP TABLE IF EXISTS driveway_cuts;
CREATE TABLE driveway_cuts AS
SELECT row_number() OVER () AS cut_id, ST_Buffer(ST_Intersection(a.geom_utm,b.geom_utm),GREATEST(a.width_m/2,2)) AS geom_utm
FROM source_roads a JOIN source_roads b ON a.osm_id <> b.osm_id
WHERE a.highway='service' AND a.tags->>'service'='driveway' AND b.highway IN ('primary','secondary','tertiary','residential','unclassified','living_street','road','pedestrian')
  AND a.geom_utm && ST_Expand(b.geom_utm,30) AND ST_Intersects(a.geom_utm,b.geom_utm);
CREATE INDEX driveway_cuts_geom_idx ON driveway_cuts USING gist(geom_utm);

DROP TABLE IF EXISTS parking_lane_cut2;
CREATE TABLE parking_lane_cut2 AS
SELECT c.*, (d).geom AS cut_geom
FROM parking_lane_cut c LEFT JOIN LATERAL (
  SELECT ST_UnaryUnion(ST_Collect(x.geom_utm)) AS geom_utm
  FROM driveway_cuts x
  WHERE x.geom_utm && ST_Expand(c.geom_utm,20) AND ST_DWithin(x.geom_utm,c.geom_utm,20)
) x ON true
CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(CASE WHEN x.geom_utm IS NULL THEN c.geom_utm ELSE ST_Difference(c.geom_utm,x.geom_utm) END,2)) d
WHERE ST_Length((d).geom)>0.01;
ALTER TABLE parking_lane_cut2 DROP COLUMN geom_utm;
ALTER TABLE parking_lane_cut2 RENAME COLUMN cut_geom TO geom_utm;
CREATE INDEX parking_lane_cut2_geom_idx ON parking_lane_cut2 USING gist(geom_utm);
ANALYZE parking_lane_cut2;

INSERT INTO diagnostics(stage,code,detail)
SELECT 'obstructions','crossing_cuts',count(*)::text FROM parking_lane_fragments f
WHERE EXISTS (SELECT 1 FROM parking_lane_cut c WHERE c.source_key=f.source_key AND ST_Length(c.geom_utm)<ST_Length(f.geom_utm));
