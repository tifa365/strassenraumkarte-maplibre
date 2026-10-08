-- web_parking_cars.sql — sprite name and rotation for the QGIS "parking cars"
-- layer (SvgMarker symbols/cars/<model>_<colour>.svg, 2.4 m wide).
-- Expects public.parking_cars loaded by data/load_parking_cars.sh.
--
-- icon_rotation reproduces the QGIS data-defined angle expression
--   if(orientation='parallel', angle + if(oneway='yes' and side='left', 180, 0),
--   if(orientation='diagonal', angle + if(oneway='yes' and side='left', -54+180, 54),
--   if(orientation='perpendicular', angle - 90, rand(0, 360)))) - @mercator_scale
-- QGIS's rand() is re-rolled on every render; here a stable hash of space_id
-- stands in. "- @mercator_scale" subtracts the project variable (1/cos(latitude),
-- about 1.64 at Berlin) from the angle in degrees; it is reproduced as-is, using
-- each point's own latitude so the script works for any city.

ALTER TABLE parking_cars
    ADD COLUMN IF NOT EXISTS icon text,
    ADD COLUMN IF NOT EXISTS icon_rotation real;

UPDATE parking_cars
SET
    icon = 'parking-car-' || model || '_' || colour,
    icon_rotation = mod(
        (
            CASE orientation
                WHEN 'parallel' THEN
                    angle_deg + CASE WHEN oneway = 'yes' AND side = 'left' THEN 180 ELSE 0 END
                WHEN 'diagonal' THEN
                    angle_deg + CASE WHEN oneway = 'yes' AND side = 'left' THEN -54 + 180 ELSE 54 END
                WHEN 'perpendicular' THEN
                    angle_deg - 90
                ELSE
                    mod(mod(hashtext(space_id), 360) + 360, 360)
            END
            - 1.0 / cos(radians(ST_Y(ST_Transform(geom, 4326))))
        )::numeric + 360,
        360
    );

CREATE INDEX IF NOT EXISTS parking_cars_icon_idx ON parking_cars (icon);
