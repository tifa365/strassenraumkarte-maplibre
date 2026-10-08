-- web_parking_cars_placeholder.sql — make sure public.parking_cars exists.
--
-- The parked cars come from the street-parking GeoJSON (data/build_parking.sh)
-- and are loaded separately by data/load_parking_cars.sh. Martin refuses to
-- start when a configured table is missing, so a freshly processed database
-- gets an empty table with the columns that load_parking_cars.sh produces;
-- loading the cars later replaces it.

CREATE TABLE IF NOT EXISTS parking_cars (
    gid serial PRIMARY KEY,
    space_id text,
    angle_deg double precision,
    orientation text,
    side text,
    oneway text,
    colour text,
    model text,
    icon text,
    icon_rotation real,
    geom geometry(Point, :crs)
);
CREATE INDEX IF NOT EXISTS parking_cars_geom_geom_idx ON parking_cars USING gist (geom);
