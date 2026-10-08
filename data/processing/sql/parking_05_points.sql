-- Capacity and deterministic vehicle points.
SET search_path TO :"schema", public;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DROP TABLE IF EXISTS parking_lines CASCADE;
CREATE TABLE parking_lines AS
WITH inferred AS (
 SELECT source_key,osm_type,osm_id,side,parking,orientation,parking_width AS width_m,
        mapped_capacity,condition_class,vehicle_designated,vehicle_excluded,markings,markings_type,
        tags,highway,name,oneway,geom_utm,'inferred'::text AS source_type
 FROM parking_lane_final
), separate AS (
 SELECT ('separate/'||osm_type||'/'||osm_id) AS source_key,osm_type,osm_id,side,parking,orientation,width_m,mapped_capacity,
        condition_class,vehicle_designated,vehicle_excluded,markings,markings_type,NULL::jsonb AS tags,
        NULL::text AS highway,NULL::text AS name,NULL::text AS oneway,geom_utm,source_type
 FROM separate_parking_lines
), all_lines AS (SELECT * FROM inferred UNION ALL SELECT * FROM separate),
 vehicle_dims AS (
 SELECT a.*,ST_Length(geom_utm) AS length_m,
        (vehicle_designated ~ '(^|;)bus($|;)') AS is_bus,
        CASE WHEN vehicle_designated ~ '(^|;)bus($|;)' THEN 12.0 ELSE 4.4 END AS vehicle_length,
        CASE WHEN vehicle_designated ~ '(^|;)bus($|;)' THEN 2.5 ELSE 1.8 END AS vehicle_width,
        CASE WHEN vehicle_designated ~ '(^|;)bus($|;)' THEN CASE orientation WHEN 'parallel' THEN 12.0 WHEN 'diagonal' THEN 5.0 ELSE 4.0 END
             ELSE CASE orientation WHEN 'parallel' THEN 5.2 WHEN 'diagonal' THEN 3.1 ELSE 2.5 END END AS vehicle_distance,
        CASE WHEN vehicle_designated ~ '(^|;)bus($|;)' THEN sqrt(2.5*0.5*2.5)+sqrt(12*0.5*12)
             ELSE sqrt(1.8*0.5*1.8)+sqrt(4.4*0.5*4.4) END AS diagonal_width
 FROM all_lines a
), lengths AS (
 SELECT v.*,
        CASE WHEN mapped_capacity IS NOT NULL THEN mapped_capacity ELSE
          floor((length_m + (vehicle_distance - CASE orientation WHEN 'parallel' THEN vehicle_length WHEN 'diagonal' THEN diagonal_width ELSE vehicle_width END)) / NULLIF(vehicle_distance,0)) END AS calculated_capacity
 FROM vehicle_dims v
), redistributed AS (
 SELECT l.*, CASE WHEN mapped_capacity IS NOT NULL THEN
          round(mapped_capacity * length_m / NULLIF(sum(length_m) OVER (PARTITION BY source_key,side,source_type),0))
        ELSE calculated_capacity END::integer AS capacity
 FROM lengths l
)
SELECT row_number() OVER (ORDER BY source_key,side,source_type,ST_AsEWKB(geom_utm)) AS line_id,*,
       degrees(ST_Azimuth(ST_StartPoint(geom_utm),ST_EndPoint(geom_utm))) AS angle
FROM redistributed
WHERE length_m >= CASE WHEN vehicle_designated ~ '(^|;)bus($|;)' THEN
                         CASE orientation WHEN 'parallel' THEN 12 ELSE 2.5 END
                       ELSE CASE orientation WHEN 'parallel' THEN 4.4 ELSE 1.8 END END;
DELETE FROM parking_lines WHERE capacity IS NULL OR capacity < 1;
CREATE INDEX parking_lines_geom_idx ON parking_lines USING gist(geom_utm);
CREATE INDEX parking_lines_source_idx ON parking_lines(source_key,side,source_type);
ANALYZE parking_lines;

DROP TABLE IF EXISTS parking_points;
CREATE TABLE parking_points (
 space_id text PRIMARY KEY, osm_type text, osm_id bigint, source_key text,
 side text, parking text, orientation text, angle double precision,
 highway text, highway_name text, highway_oneway text, vehicle_designated text, vehicle_excluded text,
 condition_class text, markings text, markings_type text, width_m numeric,
 source_type text, capacity integer, point_index integer,
 model text, colour text, geom geometry(Point,3857)
);

-- The spacing and start offsets are the formulas used by the pinned reference.
WITH base_params AS (
 SELECT l.*, CASE WHEN vehicle_designated ~ '(^|;)bus($|;)' THEN CASE orientation WHEN 'parallel' THEN 12.0 WHEN 'diagonal' THEN 5.0 ELSE 4.0 END
                  WHEN orientation='diagonal' THEN 3.1 WHEN orientation='perpendicular' THEN 2.5 ELSE 5.2 END AS spacing,
        CASE WHEN vehicle_designated ~ '(^|;)bus($|;)' THEN 6 + ((length_m - 12*capacity)/2)
             WHEN capacity < 2 THEN length_m/2
             WHEN mapped_capacity IS NULL THEN (length_m - (CASE orientation WHEN 'diagonal' THEN 3.1 WHEN 'perpendicular' THEN 2.5 ELSE 5.2 END)*(capacity-1))/2
             WHEN orientation='diagonal' THEN 1.55
             WHEN orientation='perpendicular' THEN CASE WHEN length_m < 2.5*capacity THEN .9 ELSE 1.25 END
             ELSE CASE WHEN length_m < 5.2*capacity-.8 THEN 2.2 ELSE 2.6 END END AS start_offset,
        CASE WHEN orientation='diagonal' THEN 2.1 WHEN orientation='perpendicular' THEN 2.2 ELSE 1 END AS centre_offset
 FROM parking_lines l
), params AS (
 SELECT b.*,
        CASE WHEN b.capacity < 2 THEN b.length_m
             WHEN b.is_bus THEN b.spacing
             WHEN b.mapped_capacity IS NULL THEN b.spacing
             WHEN b.length_m < CASE b.orientation WHEN 'diagonal' THEN 3.1*b.capacity WHEN 'perpendicular' THEN 2.5*b.capacity ELSE 5.2*b.capacity-.8 END
               THEN (b.length_m + CASE b.orientation WHEN 'parallel' THEN .8 WHEN 'perpendicular' THEN .5 ELSE 0 END
                     - 2*b.start_offset) / NULLIF(b.capacity-1,0)
             ELSE (b.length_m - 2*b.start_offset) / NULLIF(b.capacity-1,0)
        END AS chain_spacing
 FROM base_params b
), chain AS (
 SELECT p.source_key,p.line_id,g.i,
        ST_LineInterpolatePoint(p.geom_utm,LEAST(1,GREATEST(0,(p.start_offset+p.chain_spacing*g.i)/NULLIF(p.length_m,0)))) AS base_point
 FROM params p CROSS JOIN LATERAL generate_series(0,GREATEST(p.capacity-1,0)) g(i)
), tangent AS (
 SELECT p.*,c.i,c.base_point,
        degrees(ST_Azimuth(
          ST_LineInterpolatePoint(p.geom_utm,GREATEST(0,LEAST(1,(p.start_offset+p.chain_spacing*c.i)/NULLIF(p.length_m,0)-0.001))),
          ST_LineInterpolatePoint(p.geom_utm,GREATEST(0,LEAST(1,(p.start_offset+p.chain_spacing*c.i)/NULLIF(p.length_m,0)+0.001))))) AS point_angle
 FROM params p JOIN chain c ON c.source_key=p.source_key AND c.line_id=p.line_id
 WHERE p.angle IS NOT NULL AND c.base_point IS NOT NULL AND p.length_m > 0
), translated AS (
 SELECT t.*,ST_Translate(t.base_point,
      -cos(radians(t.point_angle))*t.centre_offset * CASE WHEN t.parking IN ('on_kerb','street_side','shoulder') AND t.source_type<>'separate_area' THEN -1 ELSE 1 END
      + CASE WHEN t.orientation='diagonal' THEN sin(radians(t.point_angle))*CASE WHEN t.oneway='yes' AND t.side='left' THEN 1.2 ELSE -1.2 END * CASE WHEN t.parking IN ('on_kerb','street_side','shoulder') AND t.source_type<>'separate_area' THEN -1 ELSE 1 END ELSE 0 END,
      sin(radians(t.point_angle))*t.centre_offset * CASE WHEN t.parking IN ('on_kerb','street_side','shoulder') AND t.source_type<>'separate_area' THEN -1 ELSE 1 END
      + CASE WHEN t.orientation='diagonal' THEN cos(radians(t.point_angle))*CASE WHEN t.oneway='yes' AND t.side='left' THEN 1.2 ELSE -1.2 END * CASE WHEN t.parking IN ('on_kerb','street_side','shoulder') AND t.source_type<>'separate_area' THEN -1 ELSE 1 END ELSE 0 END) AS point_utm
 FROM tangent t
)
INSERT INTO parking_points
 SELECT encode(digest(source_key||'|'||COALESCE(side,'')||'|'||encode(ST_AsEWKB(point_utm),'hex')||'|'||i::text,'sha256'),'hex'),
       osm_type,osm_id,source_key,side,parking,orientation,point_angle,highway,name,oneway,
       vehicle_designated,vehicle_excluded,condition_class,markings,markings_type,width_m,source_type,capacity,i,
       CASE WHEN vehicle_designated ~ '(^|;)bus($|;)' THEN 'bus-simple01'
            WHEN vehicle_designated ~ '(^|;)hgv($|;)' THEN 'hgv-simple01'
            WHEN vehicle_designated ~ '(^|;)taxi($|;)' THEN 'car-taxi'
            ELSE ('car-simple0'||(1 + get_byte(digest(source_key||i::text,'sha256'),0)%3)) END,
       CASE WHEN vehicle_designated ~ '(^|;)taxi($|;)' THEN 'yellow' ELSE CASE (get_byte(digest(source_key||'|'||i::text||'|appearance-v1','sha256'),1)%6)
            WHEN 0 THEN 'black' WHEN 1 THEN 'dark_blue' WHEN 2 THEN 'gray'
            WHEN 3 THEN 'green' WHEN 4 THEN 'red' ELSE 'silver' END END,
       ST_Transform(point_utm,3857)
FROM translated
WHERE point_utm IS NOT NULL;
CREATE INDEX parking_points_geom_idx ON parking_points USING gist(geom);
CREATE INDEX parking_points_order_idx ON parking_points(space_id);
ANALYZE parking_points;

INSERT INTO diagnostics(stage,code,detail)
SELECT 'points','space_count',count(*)::text FROM parking_points;
