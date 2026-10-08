-- web_symbol_names.sql — Map QGIS SvgMarker file expressions to stable
-- MapLibre sprite ids. This starts with the high-volume feature_node symbols;
-- the id is intentionally independent of a local absolute project path.
--
-- Symbol dimensions remain ground-metre values. The MapLibre style converts
-- them to pixels at render time, matching the existing tree implementation.

\i 'processing/sql/web/params_web.sql'

ALTER TABLE feature_node
    ADD COLUMN IF NOT EXISTS symbol_name text,
    ADD COLUMN IF NOT EXISTS symbol_size_m real,
    ADD COLUMN IF NOT EXISTS icon_rotation real;

ALTER TABLE road_marking_node
    ADD COLUMN IF NOT EXISTS symbol_name text,
    ADD COLUMN IF NOT EXISTS symbol_size_m real,
    ADD COLUMN IF NOT EXISTS icon_rotation real;

UPDATE feature_node
SET
    symbol_name = CASE
        WHEN "class" = 'artwork' THEN 'icon-tourism-artwork'
        WHEN "class" = 'bench' AND subclass ~ 'backrest_no'
            THEN 'icon-amenity-bench-backrest-no'
        WHEN "class" = 'bench' THEN 'icon-amenity-bench'
        WHEN "class" = 'bicycle_parking' THEN 'icon-amenity-bicycle'
        WHEN "class" = 'bicycle_rental' THEN 'icon-amenity-bicycle-rental'
        WHEN "class" = 'small_electric_vehicle_parking'
            THEN 'icon-amenity-small-electric-vehicle'
        WHEN "class" = 'fountain' THEN 'icon-amenity-fountain'
        WHEN "class" = 'information' AND subclass = 'guidepost'
            THEN 'icon-tourism-guidepost'
        WHEN "class" = 'manhole' THEN 'icon-man-made-manhole'
        WHEN "class" IN ('picnic_table', 'table') THEN 'icon-leisure-picnic-table'
        WHEN "class" = 'post_box' AND subclass = 'PIN Mail'
            THEN 'icon-amenity-post-box-yellow'
        WHEN "class" = 'post_box' THEN 'icon-amenity-post-box-green'
        WHEN "class" = 'recycling' THEN 'icon-amenity-recycling'
        WHEN "class" = 'street_lamp' AND subclass ~ 'bent_mast' AND direction IS NOT NULL
            THEN 'icon-highway-street-lamp-bent-mast'
        WHEN "class" = 'table_tennis' AND subclass = 'net_no'
            THEN 'icon-leisure-table-tennis-net-no'
        WHEN "class" = 'table_tennis' AND subclass = 'net_yes'
            THEN 'icon-leisure-table-tennis-net-yes'
        WHEN "class" = 'table_tennis' THEN 'icon-leisure-table-tennis'
        WHEN "class" = 'telephone' THEN 'icon-amenity-telephone'
        WHEN "class" = 'waste_basket' THEN 'icon-amenity-waste-basket'
        WHEN "class" = 'information' THEN 'icon-tourism-information'
        WHEN "class" = 'memorial' AND subclass <> 'stolperstein'
            THEN 'icon-historic-memorial'
        WHEN "class" = 'toilets' THEN 'icon-amenity-toilets'
        WHEN "class" = 'viewpoint' AND subclass = 'all_directions'
            THEN 'icon-tourism-viewpoint-all-directions'
        WHEN "class" = 'viewpoint' THEN 'icon-tourism-viewpoint'
        WHEN "class" = 'entrance' AND subclass ~ 'subway'
            THEN 'icon-public-transport-subway'
        WHEN "class" = 'entrance' AND subclass ~ 's-train'
            THEN 'icon-public-transport-s-train'
        -- QGIS SimpleMarker symbols (sprites rendered by scripts/marker_sprites.py)
        WHEN "class" = 'street_lamp' AND subclass ~ 'wall' AND direction IS NOT NULL
            THEN 'marker-street-lamp-wall'
        WHEN "class" = 'street_lamp' THEN 'marker-street-lamp'
        WHEN "class" = 'street_cabinet' THEN 'marker-street-cabinet'
        WHEN "class" = 'vending_machine' AND subclass = 'parking_tickets'
            THEN 'marker-parking-tickets'
        WHEN "class" = 'vending_machine' THEN 'marker-vending-machine'
        WHEN "class" = 'advertising_column' THEN 'marker-advertising-column'
        WHEN "class" = 'water_well' THEN 'marker-water-well'
        WHEN "class" = 'charging_station' THEN 'marker-charging-station'
        WHEN "class" = 'drinking_water' THEN 'marker-drinking-water'
        WHEN "class" = 'clock' AND (support IS NULL OR support NOT IN ('wall', 'wall_mounted'))
            THEN 'marker-clock'
        WHEN "class" = 'planter' THEN 'marker-planter'
        WHEN "class" = 'shelter' THEN 'marker-shelter'
        WHEN "class" = 'pole' THEN 'marker-pole'
        WHEN "class" = 'monitoring_station' THEN 'marker-monitoring-station'
        WHEN "class" = 'mast' THEN 'marker-mast'
        WHEN "class" = 'fire_hydrant' AND subclass IN ('pillar', 'pipe', 'wall')
            THEN 'marker-fire-hydrant-ring'
        WHEN "class" = 'fire_hydrant' THEN 'marker-fire-hydrant-h'
        WHEN "class" = 'flagpole' THEN 'marker-flagpole'
        WHEN "class" = 'grit_bin' THEN 'marker-grit-bin'
        WHEN "class" = 'chimney' THEN 'marker-chimney'
        WHEN "class" = 'public_bookcase' THEN 'marker-public-bookcase'
        WHEN "class" = 'memorial' AND subclass = 'stolperstein' THEN 'marker-stolperstein'
        WHEN "class" = 'guard_stone' THEN 'marker-guard-stone'
        -- signs: the post line and the full-size plate exist only on poles (or no support)
        WHEN "class" = 'traffic_sign' AND subclass ~ '222'
             AND (support IS NULL OR support = 'pole') THEN 'marker-traffic-sign-arrows'
        WHEN "class" = 'traffic_sign' AND subclass ~ 'street_name_sign'
             AND (support IS NULL OR support = 'pole') THEN 'marker-traffic-sign-street-name'
        WHEN "class" = 'traffic_sign' AND subclass !~ '222|605|street_name_sign'
             AND (support IS NULL OR support = 'pole') THEN 'marker-traffic-sign'
        WHEN "class" = 'traffic_sign' AND subclass !~ '222|605|street_name_sign'
            THEN 'marker-traffic-sign-wall'
        ELSE NULL
    END,
    -- QGIS SvgMarker sizes (data-defined "@mercator_scale * x", ground metres)
    -- set the icon's width; the sprite box is square and fits the longer side,
    -- so tall icons get width * height/width (memorial 1.31, table tennis 1.43,
    -- waste basket 1.17). viewpoint has no override: 3 map units.
    symbol_size_m = CASE
        WHEN "class" = 'artwork' THEN 1.6
        WHEN "class" = 'bench' THEN 1.7
        WHEN "class" = 'bicycle_parking' AND subclass = 'cargo_bike' THEN 2.2
        WHEN "class" IN ('bicycle_parking', 'bicycle_rental', 'small_electric_vehicle_parking') THEN 1.8
        WHEN "class" = 'fountain' THEN 3.2
        WHEN "class" = 'information' AND subclass = 'guidepost' THEN 1.8
        WHEN "class" = 'information' THEN 1.2
        WHEN "class" = 'manhole' THEN 0.75
        WHEN "class" IN ('picnic_table', 'table') THEN 1.75
        WHEN "class" = 'post_box' THEN 1.2
        WHEN "class" = 'recycling' THEN 1.4
        WHEN "class" = 'street_lamp' THEN 6.0
        WHEN "class" = 'table_tennis' THEN 1.7 * 1.43
        WHEN "class" = 'telephone' THEN 1.2
        WHEN "class" = 'waste_basket' THEN 0.8 * 1.17
        WHEN "class" = 'memorial' THEN 1.2 * 1.31
        WHEN "class" = 'toilets' THEN 1.6
        WHEN "class" = 'viewpoint' THEN 3.0 / metres(1.0)
        WHEN "class" = 'entrance' AND subclass ~ 'subway' THEN 2.0
        WHEN "class" = 'entrance' AND subclass ~ 's-train' THEN 2.2
        ELSE 1.6
    END,
    icon_rotation = CASE
        WHEN "class" = 'bench' AND direction IS NOT NULL THEN direction - 180.0
        -- QGIS: angle "direction" - 90 for the horizontal bent-mast SVG
        WHEN "class" = 'street_lamp' AND subclass ~ 'bent_mast' AND direction IS NOT NULL
            THEN direction - 90.0
        WHEN "class" = 'street_lamp' AND subclass ~ 'wall' AND direction IS NOT NULL THEN direction
        WHEN "class" IN ('street_cabinet', 'vending_machine', 'grit_bin')
            THEN COALESCE(direction, 0.0) + 90.0
        WHEN "class" IN ('charging_station') THEN COALESCE(direction, 0.0)
        WHEN "class" = 'memorial' AND subclass = 'stolperstein' THEN COALESCE(direction, 0.0)
        WHEN "class" = 'guard_stone' THEN COALESCE(direction, 0.0) - 90.0
        WHEN "class" = 'traffic_sign' THEN COALESCE(direction, 0.0) + 180.0
        WHEN "class" = 'viewpoint' AND direction IS NOT NULL THEN direction
        ELSE 0.0
    END;

-- Ground metres covered by each marker sprite (scripts/marker_sprites.py MARKERS[].box;
-- audit_marker_sprites.py compares the two).
UPDATE feature_node
SET symbol_size_m = marker_box.box
FROM (VALUES
    ('marker-street-lamp', 1.0), ('icon-highway-street-lamp-bent-mast', 6.0),
    ('marker-street-lamp-wall', 1.6), ('marker-street-cabinet', 1.0),
    ('marker-vending-machine', 0.5), ('marker-parking-tickets', 0.7),
    ('marker-advertising-column', 2.0), ('marker-water-well', 1.5),
    ('marker-charging-station', 0.7), ('marker-drinking-water', 0.8),
    ('marker-clock', 0.8), ('marker-planter', 1.0), ('marker-shelter', 3.4),
    ('marker-pole', 0.6), ('marker-monitoring-station', 0.4), ('marker-mast', 0.9),
    ('marker-fire-hydrant-h', 0.9), ('marker-fire-hydrant-ring', 1.1), ('marker-flagpole', 0.4), ('marker-grit-bin', 1.4), ('marker-chimney', 1.5),
    ('marker-public-bookcase', 1.2), ('marker-stolperstein', 0.4),
    ('marker-guard-stone', 0.8), ('marker-traffic-sign', 1.2),
    ('marker-traffic-sign-wall', 1.2), ('marker-traffic-sign-street-name', 1.2),
    ('marker-traffic-sign-arrows', 1.2)
) AS marker_box(name, box)
WHERE feature_node.symbol_name = marker_box.name;

UPDATE road_marking_node
SET
    symbol_name = CASE
        WHEN road_marking = 'arrow'
         AND arrow IN (
            'left', 'left;right', 'left;through', 'merge_to_left',
            'merge_to_right', 'right', 'slight_left', 'slight_right',
            'through', 'through;right'
         )
         AND length IN (2, 5)
            THEN 'road-arrow-' || replace(arrow, ';', '-') || '-l' || length::integer
        ELSE NULL
    END,
    symbol_size_m = CASE
        WHEN road_marking = 'arrow' AND length IN (2, 5) THEN length
        ELSE NULL
    END,
    icon_rotation = CASE
        WHEN road_marking = 'arrow' THEN COALESCE(direction, 0)
        ELSE 0.0
    END;
