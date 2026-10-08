-- Create geometries for all building parts with information on height and floating building parts as well as lines to represent the edges of buildings

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'


-- 1) Preparation: Distinguish building parts by height and floating building areas

-- Step A: For buildings: derive height from building:levels or use default building heights
UPDATE building
SET height = 
    CASE 
        -- derive height from building:levels...
        WHEN "building:levels" IS NOT NULL THEN "building:levels" * 3
        -- ...or use default building heights: 3m for roofs and service buildings, 5m otherwise
        WHEN building IN ('roof', 'service') THEN 3
        ELSE 5
    END
WHERE
    height IS NULL
    AND "building:part" IS NULL
    AND building IS NOT NULL;
    
-- Step B: For building:parts: adopt heigth from their building outlines, if not explicitly specified
UPDATE building AS part
SET height =
    CASE
        WHEN part."building:levels" IS NOT NULL THEN
            CASE
                -- derive height from building if it has the same building:levels number, but a height attribute
                WHEN part."building:levels" = outline."building:levels" AND outline.height IS NOT NULL THEN outline.height
                -- else derive height from building:part building:levels...
                ELSE part."building:levels" * 3
            END
        -- ...or adopt from building outline
        ELSE outline.height
    END
FROM building AS outline
WHERE
    part.height IS NULL 
    AND part."building:part" IS NOT NULL
    AND outline."building" IS NOT NULL
    AND ST_Contains(outline.geom, part.geom);

-- Step C: Workaround for flawed building:parts that aren't fully contained in building outlines and therefore still have no height (indicator for mapping errors)
WITH overlap_areas AS (
    SELECT
        part.osm_id AS part_id,
        outline.osm_id AS outline_id,
        outline.building AS outline_building,
        outline."building:levels" AS outline_building_levels,
        outline.height AS outline_height,
        ST_Area(ST_Intersection(part.geom, outline.geom)) AS intersection_area
    FROM 
        building AS part
    JOIN 
        building AS outline
    ON 
        ST_Intersects(part.geom, outline.geom)
    WHERE 
        part.height IS NULL 
        AND part."building:part" IS NOT NULL
        AND outline."building" IS NOT NULL
),
best_matches AS (
    SELECT
        part_id,
        outline_id,
        outline_building,
        outline_building_levels,
        outline_height,
        ROW_NUMBER() OVER (PARTITION BY part_id ORDER BY intersection_area DESC) AS rank
    FROM 
        overlap_areas
)
UPDATE building AS part
SET height = 
    CASE
        WHEN best_matches.outline_height IS NOT NULL THEN best_matches.outline_height
        WHEN best_matches.outline_building_levels IS NOT NULL THEN best_matches.outline_building_levels * 3
        WHEN best_matches.outline_building IN ('roof', 'service') THEN 3
        ELSE 5
    END
FROM best_matches
WHERE part.osm_id = best_matches.part_id AND best_matches.rank = 1;

-- Step D: There can still be some parts without height attribute, namely building:parts that don't intersect building outlines at all (also an indicator for mapping errors)
UPDATE building
SET height =
    CASE
        WHEN "building:levels" IS NOT NULL THEN "building:levels" * 3
        WHEN building IN ('roof', 'service') OR "building:part" IN ('roof', 'service') THEN 3
        ELSE 5
    END
WHERE
    height IS NULL;

-- Step E: Merge "building:min_level" > 0 and "min_height" > 0 and roofs to a simple "floating" true/false attribute
ALTER TABLE building ADD COLUMN floating BOOLEAN;

UPDATE building
SET floating = 
    CASE 
        WHEN "building:min_level" > 0 OR "min_height" > 0 OR "building" = 'roof' OR "building:part" = 'roof' THEN TRUE
        ELSE FALSE
    END;


-- 2) Create a table that contains exactly one area for each location within building areas, according to the different height and floating attributes of all parts

BEGIN; -- Using BEGIN-END-transaction for autodeleting temporary tables at the end

-- Step A: Extract all building and building part boundaries ("blade")
CREATE TEMP TABLE temp_edges AS
SELECT ST_Union(ST_Boundary(geom)) AS geom
FROM building;

CREATE INDEX temp_edges_geom_idx ON temp_edges USING GIST (geom);

-- Step B: Use these "blade" to split the total building area to create exactly one polygon for each part of the building
CREATE TEMP TABLE temp_parts_raw AS
SELECT (ST_Dump(ST_Polygonize(geom))).geom AS geom
FROM temp_edges;

CREATE INDEX temp_parts_raw_geom_idx ON temp_parts_raw USING GIST (geom);

-- Step C: Fetch height and floating attributes from building parts or building outlines (if there are no parts)
CREATE TEMP TABLE temp_parts_single AS
WITH building_overlap AS (
    SELECT
        part.geom AS geom,
        building.height,
        building.floating,
        (building.building IS NULL) AS is_part
    FROM temp_parts_raw part
    -- find all overlapping parts (or parts within, as they technically aren't overlapping)
    JOIN building ON ST_Overlaps(part.geom, building.geom) OR ST_Within(part.geom, building.geom)
)
SELECT
    geom,
    -- from all parts at this location, pick the maximum height value (from building parts, or from builing outlines, if there are no parts)
    COALESCE(
        MAX(height) FILTER (WHERE is_part),
        MAX(height)
    ) AS height,
    -- from all parts at this location, pick a fitting floating value...
    CASE
        WHEN BOOL_OR(floating = false) FILTER (WHERE is_part) THEN FALSE -- floating=false, if there is a non-floating building part at this location,
        WHEN COUNT(*) FILTER (WHERE is_part) > 0 THEN TRUE  -- or floating=true otherwise (if there are building parts existing)
        WHEN BOOL_OR(floating = false) THEN FALSE  -- or floating=false, if there are no building parts, but a non-floating building outline
        ELSE TRUE  -- or floating=true, if the whole building is floating (e.g. roofs)
    END AS floating
FROM building_overlap
GROUP BY geom;

CREATE INDEX temp_parts_single_geom_idx ON temp_parts_single USING GIST (geom);

-- Step D: Create a persistent table with polygons for rendering different building/height levels (merge building parts by height and floating)
DROP TABLE IF EXISTS building_parts;

CREATE TABLE building_parts AS
SELECT height, floating, (ST_Dump(ST_Union(geom))).geom AS geom
FROM temp_parts_single
GROUP BY height, floating;

-- Step E: Merge building parts by height only (dissolved into individual polygons, not multipolygons)
DROP TABLE IF EXISTS building_parts_dissolved_height;

CREATE TABLE building_parts_dissolved_height AS
SELECT height, (ST_Dump(ST_Union(geom))).geom AS geom
FROM temp_parts_single
GROUP BY height;

-- Step F: Extrude building areas into shade polygons (NE direction; length asymptotic in height)
DROP TABLE IF EXISTS building_shade;

CREATE TABLE building_shade AS
WITH src AS (
    SELECT
        height,
        -- Positive-then-negative micro-buffer (1cm, negligible at map scale)
        -- physically separates rings that only touch at a point/degenerate
        -- edge — ST_MakeValid alone satisfies GEOS's OGC-validity notion but
        -- not SFCGAL/CGAL's stricter "interior is not connected" check that
        -- CG_MinkowskiSum enforces below.
        ST_Buffer(ST_Buffer(ST_MakeValid(geom), 0.01), -0.01) AS geom,
        :'building_shade_base_m'::double precision
            + (:'building_shade_max_m'::double precision
               - :'building_shade_base_m'::double precision)
              * (1.0 - exp(
                    -GREATEST(COALESCE(height, 0), 0)
                      / :'building_shade_height_scale_m'::double precision
                ))
            AS shade_len_m
    FROM building_parts_dissolved_height
    WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
)
SELECT
    height,
    -- CG_Extrude(geom, dx, dy, 0.0) + ST_Force2D used to compute this (a pure
    -- XY-plane sweep, never actually wanting the 3D solid) but SFCGAL's
    -- Extrude now returns a Solid type that this PostGIS build's SFCGAL
    -- bridge can't convert back ("SFCGAL2LWGEOM: Unknown Type"). CG_MinkowskiSum
    -- with a hairline flat-capped rectangle standing in for the sweep vector
    -- computes the identical 2D shadow silhouette without ever producing a
    -- 3D Solid (verified against hand-computed cases, incl. polygons with
    -- holes). ST_ForceRHR normalizes ring winding, which SFCGAL requires.
    ST_MakeValid(
        CG_MinkowskiSum(
            ST_ForceRHR(geom),
            ST_Buffer(
                ST_MakeLine(
                    ST_MakePoint(0, 0),
                    ST_MakePoint(
                        metres(shade_len_m) * cos(radians(:'building_shade_angle_deg'::double precision)),
                        metres(shade_len_m) * sin(radians(:'building_shade_angle_deg'::double precision))
                    )
                ),
                0.001, 'endcap=flat join=mitre'
            )
        )
    ) AS geom
FROM src;

CREATE INDEX building_shade_geom_idx ON building_shade USING GIST (geom);


-- 3) Create building footprint outlines (the outlines of building areas that are connected to the ground) and derive whether they are covered by floating building parts or not

-- Step A: Create building footprints
CREATE TEMP TABLE temp_building_footprints AS
SELECT (ST_Dump(ST_Union(geom))).geom AS geom
FROM temp_parts_single
WHERE floating IS false;

-- Step B: Prepare building "footlines" (outlines of the footprints)
CREATE TEMP TABLE temp_building_footlines AS
SELECT (ST_DumpSegments(geom)).geom AS geom
FROM temp_building_footprints;

-- Step C: Spatial query to distinguish covered from uncovered lines
CREATE TEMP TABLE temp_building_dissolved AS
SELECT (ST_Dump(ST_Union(geom))).geom AS geom
FROM building;

CREATE INDEX temp_building_footlines_geom_idx ON temp_building_footlines USING GIST (geom);
CREATE INDEX building_dissolved_geom_idx ON temp_building_dissolved USING GIST (geom);

ALTER TABLE temp_building_footlines ADD COLUMN covered BOOLEAN DEFAULT false;

UPDATE temp_building_footlines
SET covered = true
FROM temp_building_dissolved
WHERE ST_Within(temp_building_footlines.geom, temp_building_dissolved.geom);

-- Step D: Add building separation lines ("walls" between buildings) to footlines
CREATE TEMP TABLE temp_building_outlines AS
WITH outlines AS (
    SELECT DISTINCT (ST_DumpSegments(ST_Union(building.geom))).geom AS geom
    FROM building
    WHERE building."building" IS NOT NULL
    GROUP BY building.osm_id
)
SELECT (ST_DumpSegments(ST_Union(geom))).geom AS geom
FROM outlines;

CREATE INDEX temp_building_outlines_geom_idx ON temp_building_outlines USING GIST (geom);

CREATE TEMP TABLE temp_separator_lines AS
SELECT DISTINCT temp_building_outlines.geom
FROM temp_building_outlines, temp_building_footprints
WHERE ST_Within(temp_building_outlines.geom, temp_building_footprints.geom);

ALTER TABLE temp_separator_lines ADD COLUMN covered BOOLEAN DEFAULT false;

INSERT INTO temp_building_footlines (geom)
SELECT geom
FROM temp_separator_lines
WHERE geom IS NOT NULL;

-- Step E: Dissolve footlines by covered status, store in persistent table
DROP TABLE IF EXISTS building_lines;

CREATE TABLE building_lines AS
SELECT
    CASE
        WHEN covered = true THEN 'footline_covered'
        ELSE 'footline_uncovered'
    END AS class,
    (ST_Dump(ST_LineMerge(ST_Union(geom)))).geom AS geom
FROM temp_building_footlines
GROUP BY covered;


-- 4) Add all lines to the persistent building lines layer that are interesting for building rendering:
--    - footprints (covered and non-covered) – already included (see above)
--    - building part outlines
--    - roof ridges and edges

-- Step A: Insert building part outlines
INSERT INTO building_lines (class, geom)
SELECT 'part_outline' AS class, (ST_Dump(ST_Union(ST_Boundary(geom)))).geom
FROM temp_parts_single;

-- Step B: Insert roof lines (roof ridges and edges from separate table)
INSERT INTO building_lines (class, geom)
SELECT class, geom FROM roof_line;

END; -- delete temporary tables

CREATE INDEX building_lines_geom_idx ON building_lines USING GIST (geom);

-- original tables no longer required
DROP TABLE IF EXISTS roof_line;
-- DROP TABLE IF EXISTS building;