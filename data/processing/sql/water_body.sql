-- Dissolves all water areas for better rendering, then splits multiparts into single parts

DROP TABLE IF EXISTS water_body_dissolved;

CREATE TABLE water_body_dissolved AS
SELECT (ST_Dump(ST_Union(geom))).geom AS geom
FROM water_body;

CREATE INDEX water_body_dissolved_geom_idx ON water_body_dissolved USING GIST (geom);
