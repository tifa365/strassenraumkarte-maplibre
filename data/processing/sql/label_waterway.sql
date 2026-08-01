-- Create labeling lines for waterways

-- Dependency: water_body_dissolved from water_body.sql

-- Basic idea: Waterway lines should be labeled at regular intervals, preferably between (and not in) bridges or tunnels
-- and not in water areas (lakes in the course of the waterway line) or across water area edges. For this purpose, the waterway lines are
-- 1) first unified by name and category and water bodies are cut out,
-- 2) labeling target lines are generated (ranges around the middle of line sections with a maximum length for repeating and well placed labels),
-- 3) bridges and tunnels are cut out,
-- 4) and finally the lines with the largest overlap with the labeling target are selected.

DROP TABLE IF EXISTS label_waterway;
CREATE TABLE label_waterway AS


-- 1) Cut out water bodies and unify by name and category

-- Step A: Create cut lines ("blade"), where water bodys intersect waterways
-- explode the water body outline to single parts
-- SELECT DISTINCT instead of SELECT excludes duplicate geometries
WITH water_body_exploded AS (
    SELECT DISTINCT
        (ST_DumpSegments(geom)).geom AS geom
    FROM
        water_body_dissolved
),

-- just select those exploded segments, that intersect with waterway lines
water_body_intersections AS (
    SELECT DISTINCT
        water_body_exploded.geom
    FROM
        water_body_exploded
    JOIN
        waterway
    ON
        ST_Intersects(water_body_exploded.geom, waterway.geom)
),

-- exclude line segments that are identical to line segments from waterway, because the split function don't accept blade lines that cover geometries it should cut
water_body_blade AS (
    SELECT ST_Union(geom) AS geom
    FROM water_body_intersections
    WHERE NOT EXISTS (
        SELECT 1
        FROM waterway
        WHERE ST_CoveredBy(water_body_intersections.geom, waterway.geom)
    )
),

-- Step B: Create labeling base lines: Unify waterways by name, merge them to single geometries and cut this geometries with the blade lines from Step A.
labeling_baseline_1a AS (
    SELECT
        waterway.name,
        waterway.waterway,
        (ST_Dump(ST_Split(ST_LineMerge(ST_Multi(ST_Union(waterway.geom)), TRUE), water_body_blade.geom))).geom AS geom
    FROM
        waterway, water_body_blade
    WHERE
        -- keep segments with name and specific "main" waterway classes only
        waterway.waterway IN ('river', 'stream', 'tidal_channel', 'canal', 'ditch', 'drain')
        AND waterway.name IS NOT NULL
        -- exclude longer tunnel segments
        AND NOT (
            NOT ((waterway.tunnel = 'no' OR waterway.tunnel IS NULL) AND (waterway.covered = 'no' OR waterway.covered IS NULL))
            AND ST_Length(waterway.geom) > metres(100)
        )
    GROUP BY
        waterway.name, waterway.waterway, water_body_blade.geom
),

-- Step C: Cut out lakes / non-flowing water areas from these labeling base lines
water_body_non_flowing AS (
    SELECT ST_Union(geom) AS geom
    FROM water_body
    WHERE
        "natural" = 'water'
        AND (
            water NOT IN ('river', 'stream', 'tidal_channel', 'canal', 'ditch', 'drain')
            OR water IS NULL
        )
),

labeling_baseline_1b AS (
    SELECT
        baseline.name,
        baseline.waterway,
        CASE
            WHEN ST_Intersects(baseline.geom, water_body.geom) THEN ST_Difference(baseline.geom, water_body.geom)
            ELSE baseline.geom
        END AS geom
    FROM
        labeling_baseline_1a baseline, water_body_non_flowing water_body
),


-- 2) Create labeling target lines

-- Split unified waterway base linies in max. 1.200 m long segments
-- and shorten them to a length of 300 m (a range in the center of the splitted segments that is the base target for the waterway label)
-- Later, bridges and tunnels will be cut from the waterway labeling lines and the longest segment intersecting this target line will be used for labeling

-- Step A: Split segments to a max. length of 1.200 m
-- For segmentation see documentation of https://postgis.net/docs/ST_LineSubstring.html
target_line_segments AS (
    SELECT ST_LineSubstring(geom, startfrac, LEAST(endfrac, 1)) AS geom
    FROM (
        SELECT geom, ST_Length(geom) len, metres(1200) sublen FROM labeling_baseline_1b
        ) AS d
    CROSS JOIN LATERAL (
        SELECT i, (sublen * i) / len AS startfrac,
                (sublen * (i + 1)) / len AS endfrac
        FROM generate_series(0, floor( len / sublen )::INTEGER ) AS t(i)
        -- skip last i if line length is exact multiple of sublen
        WHERE
            (sublen * i) / len <> 1.0
            AND len > 0
        ) AS d2
),

-- Step B: Shorten splitted lines to a length of max. 300 m
target_lines AS (
    SELECT
        CASE
            WHEN ST_Length(geom) > metres(300) THEN
                ST_LineSubstring(
                    geom, 
                    (ST_Length(geom) - metres(300)) / (2 * ST_Length(geom)),
                    (ST_Length(geom) + metres(300)) / (2 * ST_Length(geom))
                )
            ELSE
                geom
        END AS geom
    FROM target_line_segments
    -- reject segments with length less than 200m
    WHERE ST_Length(geom) > metres(200)
),


-- 3) Cut out bridges and tunnels from labeling base lines

-- Exclude bridge areas from labeling base lines
labeling_baseline_3a AS (
    SELECT
        baseline.name,
        baseline.waterway,
        COALESCE(
            -- return difference from waterway and bridge, or just the waterway, if there is no intersecting bridge (and ST_Difference would return NULL)
            ST_Difference(baseline.geom, ST_Union(bridge.geom)),
            baseline.geom
        ) AS geom
    FROM labeling_baseline_1b baseline
    LEFT JOIN
        bridge
    ON
        ST_Intersects(baseline.geom, bridge.geom)
    GROUP BY
        baseline.name, baseline.waterway, baseline.geom
),

-- Exclude bridge ways from labeling base lines
-- Step A: Create blade/cut lines to split labeling base lines at bridges without bridge areas (therefore select highway segments with bridge=* crossing waterways)
bridge_blades_raw AS (
    SELECT DISTINCT
        (ST_DumpSegments(highway.geom)).geom AS geom
    FROM
        highway, labeling_baseline_3a baseline
    WHERE
        NOT (highway.bridge IS NULL OR highway.bridge = 'no')
        -- ignore path-class bridges (footway, path, cycleway, …)
        AND highway.type IS DISTINCT FROM 'path'
        AND ST_Intersects(highway.geom, baseline.geom)
),

-- Step B: Exclude highway segments from the blade that are fully covering waterway segments (to prevent ST_Split errors)
bridge_blades AS (
    SELECT ST_Union(geom) AS geom
    FROM bridge_blades_raw
    WHERE
        NOT EXISTS (
            SELECT 1
            FROM labeling_baseline_3a baseline
            WHERE ST_CoveredBy(bridge_blades_raw.geom, baseline.geom)
        )
),

-- Step C: Split labeling base lines at bridge blade lines
-- When no blades remain (e.g. only path bridges), ST_Union is NULL — keep lines unsplit
labeling_baseline_3b AS (
    SELECT
        baseline.name,
        baseline.waterway,
        (ST_Dump(
            CASE
                WHEN bridge_blades.geom IS NULL THEN ST_LineMerge(baseline.geom)
                ELSE ST_Split(ST_LineMerge(baseline.geom), bridge_blades.geom)
            END
        )).geom AS geom
    FROM
        labeling_baseline_3a baseline, bridge_blades
),

-- Exclude tunnel segments (short tunnels, since longer tunnels where excluded before)
-- Step A: Select tunnel segments
waterway_tunnels AS (
    SELECT geom
    FROM waterway
    WHERE
        NOT ((tunnel = 'no' OR tunnel IS NULL) AND (covered = 'no' OR covered IS NULL))
        AND waterway IN ('river', 'stream', 'tidal_channel', 'canal', 'ditch', 'drain')
        AND name IS NOT NULL
),

-- Step B: Exclude tunnel segments (difference)
labeling_baseline_3c AS (
    SELECT
        baseline.name,
        baseline.waterway,
        (ST_Dump(
            COALESCE(
                -- return difference from processed base line and waterway tunnels, or just the processed base line, if there is no intersection (and ST_Difference would return NULL)
                ST_Difference(baseline.geom, ST_Union(waterway_tunnels.geom)),
                baseline.geom
            )
        )).geom AS geom
    FROM labeling_baseline_3b baseline
    LEFT JOIN
        waterway_tunnels
    ON
        ST_Intersects(baseline.geom, waterway_tunnels.geom)
    GROUP BY
        baseline.name, baseline.waterway, baseline.geom
),


-- 4) Finally, select the labeling base line with the largest overlap with the labeling target line

-- Step A: Calculate overlapping length for each waterway labeling base line intersecting a target line
overlap AS (
    SELECT
        target_lines.geom AS target_geom,
        baseline.name AS waterway_name,
        baseline.waterway AS waterway_category,
        baseline.geom AS waterway_geom,
        ST_Length(ST_Intersection(target_lines.geom, baseline.geom)) AS overlap_length
    FROM
        target_lines
    LEFT JOIN
        labeling_baseline_3c baseline
    ON
        ST_Intersects(target_lines.geom, baseline.geom)
),

-- Step B: Rank overlap length by longest overlap
overlap_ranked AS (
    SELECT
        target_geom,
        waterway_name,
        waterway_category,
        waterway_geom,
        ROW_NUMBER() OVER (
            PARTITION BY target_geom
            ORDER BY overlap_length DESC
        ) AS rank
    FROM
        overlap
)

-- Choose segment with largest overlap for each target line
SELECT DISTINCT
    waterway_name AS name,
    waterway_category AS waterway,
    waterway_geom AS geom
FROM
    overlap_ranked
WHERE
    rank = 1;


CREATE INDEX label_waterway_geom_idx ON label_waterway USING GIST (geom);