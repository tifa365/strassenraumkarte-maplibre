-- Convert small table tennis pitch areas into nodes (feature_node class=table_tennis)

-- Dependency: pitch from pitch.sql

INSERT INTO feature_node (
    osm_type,
    osm_id,
    class,
    subclass,
    access,
    capacity,
    diameter,
    direction,
    markings,
    position,
    ref,
    support,
    temporary,
    disused,
    layer,
    geom
)
SELECT
    pitch.osm_type,
    pitch.osm_id,
    'table_tennis', -- class
    -- subclass (pitch:net)
    CASE
        WHEN pitch."pitch:net" = 'yes' THEN 'net_yes'
        WHEN pitch."pitch:net" = 'no' THEN 'net_no'
        ELSE NULL
    END,
    pitch.access,
    pitch.capacity,
    NULL, -- diameter
    pitch.direction,
    NULL, -- markings
    NULL, -- position
    NULL, -- ref
    NULL, -- support
    NULL, -- temporary
    NULL, -- disused
    pitch.layer,
    ST_Centroid(pitch.geom) -- create a table tennis table node in the middle of the area
FROM pitch
WHERE
    sport = 'table_tennis'
    -- only convert small areas
    AND ST_Area(geom) < 50
    -- ignore areas that still contain table tennis nodes
    AND NOT EXISTS (SELECT 1 FROM feature_node WHERE ST_Intersects(pitch.geom, feature_node.geom));