-- params.sql — Central psql variables for the data preparation pipeline.
-- Include at the start of each script:
--   \i 'processing/sql/params/params.sql'
-- Paths are relative to the data/ working directory (see data_preparation.sh).
--
-- Distance / width values below are ground metres (true distance on Earth).
-- Under EPSG:3857, geometric operations must convert them via metres()
-- (see processing/sql/helper/metres.sql and crs_scale.sql). Attribute
-- comparisons stay in ground metres; line_offset applies metres() internally.
--
-- Structure (matches data_preparation.sh where applicable):
--   1) Lanes
--   2) Road markings
--   3) Highway areas
--   4) Trees / forests
--   5) Buildings


-- =============================================================================
-- 1) LANES
-- =============================================================================

-- Note: main lane processing steps are handled in lanes.lua, not in SQL.

-- lanes_connectivity.sql

\set lanes_connectivity_max_dist 5.0
-- max distance (m) for endpoint proximity when lane counts differ
\set lanes_connectivity_close_threshold 1.5
-- max width difference (m) between connected lane candidates
\set lanes_connectivity_max_width_diff 0.5


-- =============================================================================
-- 2) ROAD MARKINGS
-- =============================================================================

-- (de) Schmalstrich — default for motorized vehicle lanes
\set narrow_stroke_width 0.12
-- (de) Breitstrich — bus; bicycle toward traffic; center_running/crossing both sides
\set wide_stroke_width 0.25

\set road_marking_default_colour   'white'
\set road_marking_temporary_colour 'yellow'

\set road_markings_dissolve_snap_tolerance 0.5

\set dasharray_bicycle           '1;1'
\set dasharray_bicycle_crossing  '0.5;0.25'
\set dasharray_bus              '5;1'
\set dasharray_parking          '1;1'
\set dasharray_stop_line        '0.5;0.25'
\set dasharray_edge_line        '1;1'
\set dasharray_crossing_edge    '0.5;0.25'
\set dasharray_default          '3;3'


-- road_marking_stop_lines.sql

\set stop_line_colour           'white'
\set stop_line_colour_temporary 'yellow'
\set stop_line_stroke           'solid'
\set stop_line_width            0.5


-- road_marking_lanes_prepare.sql

\set crossing_road_trim_ref_tolerance 0.5
\set crossing_road_trim_min_length 0.5


-- road_marking_lane_divider.sql

-- DISABLED: dashed→solid at stop lines (does not match real-world practice)
-- \set lane_divider_stop_solid_max_length 10
\set junction_bicycle_dashed_whole_line_frac 0.67
\set junction_bicycle_dashed_min_fragment_length 0.3
\set junction_bicycle_motorized_lane_distance 1
\set buffer_lane_divider_min_m 0.3
\set buffer_lane_divider_min_road_overlap_frac 0.5


-- road_marking_barred_area.sql

\set barred_area_osm_feature_max_size_ratio 2
\set barred_area_osm_feature_overlap_min_frac 0.25
\set barred_area_crossing_min_fragment_length 0.3


-- road_marking_separation.sql

\set separation_buffer_k 0.25
\set separation_bollard_proximity_m 3.0
\set separation_bollard_node_spacing_m 2.0
\set separation_bollard_coverage_frac 0.3333333333


-- road_marking_crossing_edge.sql

\set cycleway_boundary_min_length 0.05


-- road_marking_arrows.sql

\set stop_line_candidate_max_dist 7.5
\set stop_line_max_end_dist 15

\set turn_arrow_spacing              12.0
\set turn_arrow_start_offset          7.5
\set turn_arrow_min_dist_from_end     5.0
\set turn_arrow_min_dist_from_start   2.5
\set turn_arrow_length                5.0
\set turn_arrow_length_bicycle        1.2


-- road_marking_nodes.sql

\set traffic_sign_default_width       2
\set traffic_sign_distortion_factor   2
\set road_marking_node_lane_search_m 10


-- road_marking_colour.sql

\set lane_colour_edge_inset 0.125


-- road_marking_restriction.sql

\set zigzag_side_clip_buffer_m 0.15
\set zigzag_snap_min_m 0.15
\set zigzag_snap_max_m 0.8


-- road_marking_crossing.sql

\set crossing_default_width 5
\set crossing_default_width_zebra 4
\set crossing_extend 5
\set crossing_min_length 1.25
\set crossing_merge_angle_tolerance 45
\set crossing_edge_osm_skip_extra 1
\set crossing_clip_side_extra 0.25
\set crossing_anchor_window 1.5

\set crossing_stripe_spacing 1.0
\set crossing_stripe_width 0.5
\set crossing_stripe_length_extra 1.0


-- road_marking_buffer_marking.sql

\set buffer_marking_back_edge_length 6.5
\set buffer_marking_front_edge_length 5.5
\set buffer_marking_depth 2.5
\set buffer_marking_osm_feature_overlap_max_m2 4.0
-- max angle (degrees) between an existing path/footway segment and the target side
-- direction for it to be used as the crossing ray on that side (else generic fallback)
\set buffer_marking_side_match_angle_max 45
-- max undirected angle (degrees) between a lane and road_azimuth for the lane to be
-- considered "parallel" (i.e. a bicycle lane running alongside the road, not crossing it)
\set buffer_marking_bicycle_azimuth_tolerance 25
-- length (m) of the search line projected from the reference point toward the road,
-- used to locate the bicycle lane edge when relocating the reference point
\set buffer_marking_bicycle_search_length 5.0
-- fallback total width (m) of the pedestrian "tunnel" cut out of a buffer marking where
-- a crossing line passes through it, used when the crossing way has no mapped width.
-- Like a mapped width, only half of this value is used as the ST_Buffer radius.
\set buffer_marking_footway_cutout_default_width 1.5
-- rendered size (m) of the footway symbol point placed in the cutout tunnel
\set buffer_marking_footway_symbol_length 1.05
\set buffer_marking_footway_symbol_width 0.65


-- =============================================================================
-- 3) HIGHWAY AREAS
-- =============================================================================

-- highway_area_direction.sql

\set area_direction_road_search_m 20


-- highway_area_parking_class.sql

\set parking_class_highway_search_m 30


-- road_marking_parking.sql

\set parking_outline_min_length 0.05
\set parking_symbol_parallel_angle_deg 25
\set parking_symbol_road_search_m 30


-- =============================================================================
-- 4) TREES / FORESTS
-- =============================================================================

-- tree.sql — interpolate tree points in forest/wood/trees areas

-- Shrink forest polygons inward so generated trees stay off the edge (m)
\set tree_forest_edge_shrink_m 1.5
-- Shrink clipped grid cells before placing a random point (fraction of grid size)
\set tree_forest_cell_shrink_frac 0.2

-- Size classes by forest area (ground m²): small | medium (≥ this) | large (≥ this)
\set tree_forest_area_medium_m2 15000
\set tree_forest_area_large_m2 100000

-- Hexagon grid base edge length (m) for medium forests
\set tree_forest_grid_m 6
-- Dampens size_factor deviation for grid: grid = grid_m * (1 + (size_factor - 1) * this).
-- Crowns scale fully with size_factor, grid only partially — so larger forests still look denser.
\set tree_forest_grid_size_factor 0.67

-- Crown diameter base range (m) for medium forests; small/large scale via factors
\set tree_forest_crown_min_m 8.0
\set tree_forest_crown_max_m 17.0
\set tree_forest_size_factor_small 0.85
\set tree_forest_size_factor_large 1.25

-- Slight rotation for less uniform crowns (degrees)
\set tree_forest_rotation_min -20
\set tree_forest_rotation_max 20

-- leaf_type probabilities when forest leaf_type is mixed / unknown
\set tree_forest_mixed_needleleaved_frac 0.33
\set tree_forest_unknown_needleleaved_frac 0.1


-- =============================================================================
-- 5) BUILDINGS
-- =============================================================================

-- building.sql — shade extrusion length: base + (max - base) * (1 - exp(-height / scale))

-- Minimum shade length (m) at height 0
\set building_shade_base_m 0.0
-- Asymptotic maximum shade length (m)
\set building_shade_max_m 5.0
-- Characteristic height (m): ~63% of (max - base) reached at this height
\set building_shade_height_scale_m 30.0
-- Extrude direction (degrees; 0 = east, 90 = north → 45 = northeast / sun from SW)
\set building_shade_angle_deg 40
