-- Move house numbers uniformly a little into the building area

WITH inner_boundary AS (
    SELECT
        ST_Boundary(ST_Buffer((ST_Dump(ST_Union(geom))).geom, metres(-2))) AS inner_edge
    FROM building_parts
),
housenumbers_to_move AS (
    SELECT 
        housenumber.osm_id AS housenumber_id,
        inner_boundary.inner_edge,
        ST_ClosestPoint(inner_boundary.inner_edge, housenumber.geom) AS new_point
    FROM housenumber
    JOIN inner_boundary
        ON ST_DWithin(inner_boundary.inner_edge, housenumber.geom, metres(3.5))
)
UPDATE housenumber
SET geom = move_hn.new_point
FROM housenumbers_to_move move_hn
WHERE housenumber.osm_id = move_hn.housenumber_id;