-- Lane construction and virtual kerbs.  All metre operations happen in UTM.
SET search_path TO :"schema", public;

DROP TABLE IF EXISTS parking_lanes CASCADE;
CREATE TABLE parking_lanes AS
SELECT n.*, CASE WHEN side='left' THEN ((width_m - c_self - c_other)/2)+c_self
                ELSE -((width_m - c_self - c_other)/2)-c_self END AS offset_m
FROM normalized_lanes n
CROSS JOIN LATERAL (
  SELECT CASE WHEN n.parking IN ('on_kerb','shoulder','street_side') THEN 0 WHEN n.parking='half_on_kerb' THEN n.parking_width/2 ELSE n.parking_width END AS c_self,
         CASE WHEN n.side='left' THEN CASE WHEN COALESCE(n.tags->>'parking:right',n.tags->>'parking:both') IS NULL OR COALESCE(n.tags->>'parking:right',n.tags->>'parking:both') IN ('no','separate') THEN 0 WHEN COALESCE(n.tags->>'parking:right',n.tags->>'parking:both') IN ('on_kerb','shoulder','street_side') THEN 0 WHEN COALESCE(n.tags->>'parking:right:orientation',n.tags->>'parking:both:orientation')='diagonal' THEN 4.5 WHEN COALESCE(n.tags->>'parking:right:orientation',n.tags->>'parking:both:orientation')='perpendicular' THEN 5 ELSE 2 END
              ELSE CASE WHEN COALESCE(n.tags->>'parking:left',n.tags->>'parking:both') IS NULL OR COALESCE(n.tags->>'parking:left',n.tags->>'parking:both') IN ('no','separate') THEN 0 WHEN COALESCE(n.tags->>'parking:left',n.tags->>'parking:both') IN ('on_kerb','shoulder','street_side') THEN 0 WHEN COALESCE(n.tags->>'parking:left:orientation',n.tags->>'parking:both:orientation')='diagonal' THEN 4.5 WHEN COALESCE(n.tags->>'parking:left:orientation',n.tags->>'parking:both:orientation')='perpendicular' THEN 5 ELSE 2 END END AS c_other
) c
WHERE parking NOT IN ('no','separate');

-- Explicitly keep the source identity through every dump/split operation.
DROP TABLE IF EXISTS parking_lane_fragments;
CREATE TABLE parking_lane_fragments AS
SELECT l.*, row_number() OVER (PARTITION BY osm_type,osm_id,side ORDER BY ST_AsEWKB((d).geom)) AS fragment_index,
       (d).geom AS fragment_geom
FROM parking_lanes l
CROSS JOIN LATERAL ST_Dump(ST_OffsetCurve(l.geom_utm, l.offset_m::double precision)) d
WHERE ST_IsValid((d).geom) AND ST_Length((d).geom) > 0.01;
ALTER TABLE parking_lane_fragments DROP COLUMN geom_utm;
ALTER TABLE parking_lane_fragments RENAME COLUMN fragment_geom TO geom_utm;
UPDATE parking_lane_fragments SET geom_utm = ST_Reverse(geom_utm) WHERE side='left';
ALTER TABLE parking_lane_fragments ADD COLUMN source_key text;
UPDATE parking_lane_fragments SET source_key = osm_type || '/' || osm_id || '/' || side;
CREATE INDEX parking_lane_fragments_geom_idx ON parking_lane_fragments USING gist(geom_utm);
CREATE INDEX parking_lane_fragments_source_idx ON parking_lane_fragments(source_key);
ANALYZE parking_lane_fragments;

DROP TABLE IF EXISTS virtual_kerbs;
CREATE TABLE virtual_kerbs AS
SELECT source_key, osm_type, osm_id, side, geom_utm FROM parking_lane_fragments;
CREATE INDEX virtual_kerbs_geom_idx ON virtual_kerbs USING gist(geom_utm);

INSERT INTO diagnostics(stage,osm_type,osm_id,code,detail)
SELECT 'lanes',osm_type,osm_id,'zero_length',ST_Length(geom_utm)::text
FROM parking_lane_fragments WHERE ST_Length(geom_utm) <= 0.01;
