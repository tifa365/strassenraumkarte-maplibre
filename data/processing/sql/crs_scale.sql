----------------------------------------------------------------------
-- crs_scale.sql
--
-- Derive a single Web Mercator scale factor for this processing run
-- from the map location (bbox mid-latitude or data extent centroid).
--
-- psql variables (optional, set by data_preparation.sh):
--   :crs            EPSG code (default 3857)
--   :bbox_mid_lat   WGS84 mid-latitude from --bbox (empty = derive from data)
--
-- Creates public._processing_crs and metres() (via helper/metres.sql).
----------------------------------------------------------------------

\if :{?crs}
\else
\set crs 3857
\endif

\if :{?bbox_mid_lat}
\else
\set bbox_mid_lat ''
\endif

DROP TABLE IF EXISTS public._processing_crs;

CREATE TABLE public._processing_crs (
    epsg         integer          NOT NULL,
    latitude     double precision,
    scale_factor double precision NOT NULL,
    source       text             NOT NULL
);

-- Body lives in a function so :'crs' / :'bbox_mid_lat' can be substituted
-- by psql on the CALL site (variables are not expanded inside DO $$ blocks).
CREATE OR REPLACE FUNCTION public._init_processing_crs(
    p_epsg integer,
    p_bbox_mid_lat text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_lat    double precision;
    v_source text;
    v_scale  double precision;
    v_table  text;
    v_sql    text;
    v_bbox   text := NULLIF(trim(p_bbox_mid_lat), '');
BEGIN
    TRUNCATE public._processing_crs;

    IF v_bbox IS NOT NULL THEN
        -- Accept locale comma decimals (e.g. "52,4769") as well as "52.4769".
        v_lat := replace(v_bbox, ',', '.')::double precision;
        v_source := 'bbox';
    ELSE
        FOREACH v_table IN ARRAY ARRAY[
            'highway',
            'building',
            'feature_polygon',
            'lanes',
            'highway_area'
        ]
        LOOP
            IF to_regclass('public.' || v_table) IS NULL THEN
                CONTINUE;
            END IF;
            v_sql := format(
                $q$
                SELECT ST_Y(
                    ST_Transform(
                        ST_SetSRID(ST_Centroid(ST_Extent(geom)), %s),
                        4326
                    )
                )
                FROM public.%I
                WHERE geom IS NOT NULL
                $q$,
                p_epsg,
                v_table
            );
            BEGIN
                EXECUTE v_sql INTO v_lat;
            EXCEPTION WHEN OTHERS THEN
                v_lat := NULL;
            END;
            IF v_lat IS NOT NULL THEN
                v_source := v_table;
                EXIT;
            END IF;
        END LOOP;
    END IF;

    IF p_epsg = 3857 AND v_lat IS NOT NULL THEN
        v_scale := 1.0 / cos(radians(GREATEST(-85.0, LEAST(85.0, v_lat))));
    ELSE
        v_scale := 1.0;
        IF v_source IS NULL THEN
            v_source := 'fallback';
        END IF;
    END IF;

    IF v_source IS NULL THEN
        v_source := 'fallback';
    END IF;

    INSERT INTO public._processing_crs (epsg, latitude, scale_factor, source)
    VALUES (p_epsg, v_lat, v_scale, v_source);
END;
$fn$;

SELECT public._init_processing_crs(:'crs'::integer, :'bbox_mid_lat');

DROP FUNCTION public._init_processing_crs(integer, text);

\echo
\echo '=== Processing CRS scale ==='
SELECT
    epsg,
    round(latitude::numeric, 5) AS latitude,
    round(scale_factor::numeric, 6) AS scale_factor,
    source
FROM public._processing_crs;
\echo

\i 'processing/sql/helper/metres.sql'
