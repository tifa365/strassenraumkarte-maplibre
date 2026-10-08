-- Supaplex street-parking port: source normalization (EPSG:25833).
SET search_path TO :"schema", public;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS diagnostics (
    diagnostic_id bigserial PRIMARY KEY, stage text NOT NULL, osm_type text,
    osm_id bigint, code text NOT NULL, detail text, created_at timestamptz DEFAULT now()
);
CREATE TABLE IF NOT EXISTS stage_runs (
    stage text PRIMARY KEY, status text NOT NULL, started_at timestamptz,
    completed_at timestamptz, row_count bigint, elapsed_seconds numeric
);

CREATE OR REPLACE FUNCTION parking_get_side(t jsonb, side text, key text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO :"schema", public AS $$
    SELECT COALESCE(t ->> ('parking:' || side || ':' || key),
                    t ->> ('parking:both:' || key))
$$;

CREATE OR REPLACE FUNCTION parking_number(v text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path TO :"schema", public AS $$
DECLARE n numeric;
BEGIN
    IF v IS NULL OR btrim(v) = '' THEN RETURN NULL; END IF;
    BEGIN n := regexp_replace(replace(v, ',', '.'), '[^0-9.+-].*$', '')::numeric;
    EXCEPTION WHEN invalid_text_representation THEN RETURN NULL; END;
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION parking_conditional_has(v text, wanted text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE($1 ~ ('(^|;[[:space:]]*)' || $2 || '[[:space:]]*@'), false)
$$;

CREATE OR REPLACE FUNCTION parking_condition_class(t jsonb, side text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path TO :"schema", public AS $$
DECLARE fee text := COALESCE(parking_get_side(t,side,'fee'),'');
        fee_c text := COALESCE(parking_get_side(t,side,'fee:conditional'),'');
        access text := COALESCE(parking_get_side(t,side,'access'), t->>'motor_vehicle', t->>'vehicle', t->>'access','');
        access_c text := COALESCE(parking_get_side(t,side,'access:conditional'),'');
        maxstay text := COALESCE(parking_get_side(t,side,'maxstay'),'');
        maxstay_c text := COALESCE(parking_get_side(t,side,'maxstay:conditional'),'');
        restriction text := COALESCE(parking_get_side(t,side,'restriction'),'');
        restriction_c text := COALESCE(parking_get_side(t,side,'restriction:conditional'),'');
        zone text := COALESCE(parking_get_side(t,side,'zone'),'');
        result text := '';
        v text; c text;
        designated text := ''; excluded text := '';
        k text;
BEGIN
    FOREACH k IN ARRAY ARRAY['motorcar','disabled','bus','taxi','psv','hgv','goods','car_sharing','emergency','motorhome'] LOOP
        v := parking_get_side(t,side,k);
        IF v IN ('yes','designated') OR parking_get_side(t,side,'restriction:'||k) = 'none' THEN
            designated := concat_ws(';',NULLIF(designated,''),k);
        ELSIF v = 'no' THEN excluded := concat_ws(';',NULLIF(excluded,''),k); END IF;
    END LOOP;
    IF (fee='yes' OR parking_conditional_has(fee_c,'yes')) AND zone NOT IN ('','no','none') THEN result := 'mixed';
    ELSIF (access='private' OR parking_conditional_has(access_c,'private')) AND zone NOT IN ('','no','none') THEN result := 'residents';
    ELSIF (fee='yes' OR parking_conditional_has(fee_c,'yes')) AND access IN ('','yes','permissive','designated') AND zone IN ('','no','none') THEN result := 'paid';
    ELSIF (fee='no' OR parking_conditional_has(fee_c,'no')) AND maxstay IN ('','no','none') AND zone IN ('','no','none') THEN result := 'free'; END IF;
    IF restriction='loading_only' OR parking_conditional_has(restriction_c,'loading_only') THEN result := concat_ws(';',NULLIF(result,''),'loading'); END IF;
    IF restriction='charging_only' OR parking_conditional_has(restriction_c,'charging_only') THEN result := concat_ws(';',NULLIF(result,''),'charging'); END IF;
    IF maxstay <> '' AND maxstay NOT IN ('no','none') OR maxstay_c <> '' THEN result := concat_ws(';',NULLIF(result,''),'time_limited'); END IF;
    IF designated <> '' AND (access='no' OR parking_conditional_has(access_c,'no')) THEN
        IF designated ~ '(^|;)disabled($|;)' THEN result := concat_ws(';',NULLIF(result,''),'disabled');
        ELSIF designated ~ '(^|;)taxi($|;)' THEN result := concat_ws(';',NULLIF(result,''),'taxi');
        ELSIF designated ~ '(^|;)car_sharing($|;)' THEN result := concat_ws(';',NULLIF(result,''),'car_sharing');
        ELSE result := concat_ws(';',NULLIF(result,''),'vehicle_restriction'); END IF;
    END IF;
    IF access NOT IN ('','yes','destination','designated','permissive') AND result !~ '(residents|paid|loading|charging|vehicle_restriction)' THEN result := concat_ws(';',NULLIF(result,''),'access_restriction'); END IF;
    IF restriction='no_parking' OR parking_conditional_has(restriction_c,'no_parking') THEN result := concat_ws(';',NULLIF(result,''),'no_parking'); END IF;
    IF restriction='no_standing' OR parking_conditional_has(restriction_c,'no_standing') THEN result := concat_ws(';',NULLIF(result,''),'no_standing'); END IF;
    IF restriction='no_stopping' OR parking_conditional_has(restriction_c,'no_stopping') THEN result := concat_ws(';',NULLIF(result,''),'no_stopping'); END IF;
    RETURN NULLIF(result,'');
END $$;

CREATE OR REPLACE FUNCTION parking_vehicle_designated(t jsonb, side text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path TO :"schema", public AS $$
DECLARE k text; v text; result text := '';
BEGIN
  FOREACH k IN ARRAY ARRAY['motorcar','disabled','bus','taxi','psv','hgv','goods','car_sharing','emergency','motorhome'] LOOP
    v := parking_get_side(t,side,k);
    IF v IN ('yes','designated') OR parking_get_side(t,side,'restriction:'||k)='none'
       OR parking_conditional_has(parking_get_side(t,side,k||':conditional'),'yes')
       OR parking_conditional_has(parking_get_side(t,side,k||':conditional'),'designated') THEN
      result := concat_ws(';',NULLIF(result,''),k);
    END IF;
  END LOOP;
  RETURN NULLIF(result,'');
END $$;

CREATE OR REPLACE FUNCTION parking_vehicle_excluded(t jsonb, side text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path TO :"schema", public AS $$
DECLARE k text; result text := '';
BEGIN
  FOREACH k IN ARRAY ARRAY['motorcar','disabled','bus','taxi','psv','hgv','goods','car_sharing','emergency','motorhome'] LOOP
    IF parking_get_side(t,side,k)='no' OR parking_conditional_has(parking_get_side(t,side,k||':conditional'),'no') THEN result := concat_ws(';',NULLIF(result,''),k); END IF;
  END LOOP;
  RETURN NULLIF(result,'');
END $$;

DROP TABLE IF EXISTS source_roads CASCADE;
CREATE TABLE source_roads AS
WITH r AS (
    SELECT CASE osm_type WHEN 'W' THEN 'way' WHEN 'N' THEN 'node' WHEN 'R' THEN 'relation' ELSE osm_type END AS osm_type, osm_id, tags, node_ids,
           ST_Force2D(ST_SetSRID(geom,3857)) AS geom_3857
    FROM raw_ways
    WHERE ST_IsValid(geom) AND (tags ? 'highway' OR tags ? 'parking:left' OR tags ? 'parking:right' OR tags ? 'parking:both')
), n AS (
    SELECT r.*, tags->>'highway' AS highway,
      CASE WHEN tags->>'highway' IN ('primary') THEN 17 WHEN tags->>'highway' IN ('secondary') THEN 15
           WHEN tags->>'highway' IN ('tertiary') THEN 13 WHEN tags->>'highway' IN ('service') AND tags->>'service'='driveway' THEN 2.5
           WHEN tags->>'highway' IN ('service','track','pedestrian','living_street','unclassified','residential','road') THEN 8
           ELSE 4 END::numeric AS default_width
    FROM r
)
SELECT *, ST_Transform(geom_3857,25833) AS geom_utm,
       COALESCE(parking_number(tags->>'width:carriageway'),parking_number(tags->>'width'),parking_number(tags->>'est_width'),default_width) AS width_m,
       tags->>'oneway' AS oneway,
       tags->>'name' AS name
FROM n;
CREATE INDEX source_roads_geom_idx ON source_roads USING gist (geom_utm);
CREATE INDEX source_roads_highway_idx ON source_roads (highway);
ANALYZE source_roads;

INSERT INTO diagnostics(stage,osm_type,osm_id,code,detail)
SELECT 'normalize',osm_type,osm_id,'invalid_width',tags->>'width'
FROM source_roads WHERE tags ? 'width' AND parking_number(tags->>'width') IS NULL;

DROP TABLE IF EXISTS normalized_lanes CASCADE;
CREATE TABLE normalized_lanes AS
SELECT r.*, s.side,
       CASE WHEN s.value='yes' THEN 'lane' WHEN s.value IN ('lane','half_on_kerb','on_kerb','street_side','shoulder','separate','no') THEN s.value ELSE 'no' END AS parking,
       CASE WHEN s.value NOT IN ('no','separate') AND s.value IS NOT NULL THEN
              CASE WHEN s.orientation IN ('parallel','diagonal','perpendicular') THEN s.orientation ELSE 'parallel' END END AS orientation,
       COALESCE(parking_number(s.width_tag), CASE s.orientation WHEN 'diagonal' THEN 4.5 WHEN 'perpendicular' THEN 5 ELSE 2 END) AS parking_width,
       parking_number(s.capacity_tag) AS mapped_capacity,
       CASE WHEN s.value IS NOT NULL AND s.value NOT IN ('lane','half_on_kerb','on_kerb','street_side','shoulder','separate','no','yes') THEN 'invalid_parking' END AS value_error,
       parking_condition_class(r.tags,s.side) AS condition_class,
       parking_vehicle_designated(r.tags,s.side) AS vehicle_designated,
       parking_vehicle_excluded(r.tags,s.side) AS vehicle_excluded,
       parking_get_side(r.tags,s.side,'surface') AS parking_surface,
       parking_get_side(r.tags,s.side,'markings') AS markings,
       parking_get_side(r.tags,s.side,'markings:type') AS markings_type
FROM source_roads r
CROSS JOIN LATERAL (VALUES
 ('left', COALESCE(r.tags->>'parking:left',r.tags->>'parking:both'), COALESCE(r.tags->>'parking:left:orientation',r.tags->>'parking:both:orientation'), COALESCE(r.tags->>'parking:left:width',r.tags->>'parking:both:width'), COALESCE(r.tags->>'parking:left:capacity',r.tags->>'parking:both:capacity')),
 ('right', COALESCE(r.tags->>'parking:right',r.tags->>'parking:both'), COALESCE(r.tags->>'parking:right:orientation',r.tags->>'parking:both:orientation'), COALESCE(r.tags->>'parking:right:width',r.tags->>'parking:both:width'), COALESCE(r.tags->>'parking:right:capacity',r.tags->>'parking:both:capacity'))
) AS s(side,value,orientation,width_tag,capacity_tag)
WHERE s.value IS NOT NULL;
CREATE INDEX normalized_lanes_geom_idx ON normalized_lanes USING gist (geom_utm);
CREATE INDEX normalized_lanes_source_idx ON normalized_lanes (osm_type,osm_id,side);
ANALYZE normalized_lanes;
INSERT INTO diagnostics(stage,osm_type,osm_id,code,detail)
SELECT 'normalize',osm_type,osm_id,value_error,parking FROM normalized_lanes WHERE value_error IS NOT NULL;
INSERT INTO diagnostics(stage,osm_type,osm_id,code,detail)
SELECT 'normalize',osm_type,osm_id,'invalid_orientation',tags->> ('parking:'||side||':orientation')
FROM normalized_lanes
WHERE tags->> ('parking:'||side||':orientation') IS NOT NULL
  AND tags->> ('parking:'||side||':orientation') NOT IN ('parallel','diagonal','perpendicular');
