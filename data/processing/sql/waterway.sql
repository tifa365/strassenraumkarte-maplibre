-- clips out all waterways that are inside of water_body areas for better rendering
-- transfer all columns dynamically

-- Dependency: water_body_dissolved from water_body.sql

DROP TABLE IF EXISTS waterway_clipped;

DO $$
DECLARE
    cols text;
BEGIN
    SELECT string_agg(quote_ident(column_name), ', ')
    INTO cols
    FROM information_schema.columns
    WHERE table_name = 'waterway' AND column_name != 'geom';

    EXECUTE format('
        CREATE TABLE waterway_clipped AS
        SELECT
            %s,
            CASE
                WHEN ST_Intersects(waterway.geom, wbd.union_geom) THEN ST_Difference(waterway.geom, wbd.union_geom)
                ELSE waterway.geom
            END AS geom
        FROM
            waterway
            CROSS JOIN (
                SELECT ST_Union(geom) AS union_geom
                FROM water_body_dissolved
            ) wbd
    ', cols);
END
$$;

CREATE INDEX waterway_clipped_geom_idx ON waterway_clipped USING GIST (geom);
