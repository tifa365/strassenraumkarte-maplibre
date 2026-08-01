----------------------------------------------------------------------
-- helper/metres.sql
--
-- Convert ground metres (true distance) to project CRS map units.
-- Under EPSG:3857 this multiplies by the Web Mercator scale factor
-- 1/cos(φ) stored in public._processing_crs (see crs_scale.sql).
-- For metric projected CRS (e.g. UTM) the factor is 1.
--
-- Convention: attribute columns and params stay in ground metres;
-- wrap only values that enter geometric operations (ST_Buffer,
-- ST_DWithin, …). line_offset applies metres() internally.
--
-- Raises if _processing_crs has not been initialised — silent fallback
-- to 1.0 would recreate the “too narrow in Web Mercator” bug.
----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION metres(m double precision)
RETURNS double precision
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    factor double precision;
BEGIN
    SELECT scale_factor INTO factor
    FROM public._processing_crs
    LIMIT 1;

    IF factor IS NULL THEN
        RAISE EXCEPTION
            'metres(): public._processing_crs is missing or empty — run processing/sql/crs_scale.sql first (Web Mercator scale factor)';
    END IF;

    RETURN m * factor;
END;
$$;
