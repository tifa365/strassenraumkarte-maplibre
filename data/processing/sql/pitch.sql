-- Generates textures for approximately rectangular sports pitches (centroid node with length, width and direction attribute)
-- TODO: Support for base- and softball field shapes (quarter circle)

DROP TABLE IF EXISTS pitch_markings;

CREATE TABLE pitch_markings AS
WITH rect_analysis AS (
    SELECT
        geom,
        osm_id,
        sport,
        surface,
        "surface:colour",
        hoops,
        -- get the directional bounding box around the sports field (rectangle)
        ST_OrientedEnvelope(geom) AS oriented_geom,
        ST_Centroid(geom) AS centroid
    FROM pitch
    WHERE sport ~ 'badminton|basketball|chess|handball|field_hockey|multi|rugby_league|rugby_union|soccer|streetball|table_tennis|tennis|volleyball'
        AND (
            -- convert areas representing single pitches only
            (capacity IS NULL OR capacity = 1)
            -- except basket-/streetball (using "hoops" for count of baskets) and table tennis areas (that are converted to points later)
            OR (sport ~ 'basketball|streetball|table_tennis')
        )
),
oriented_calc AS (
    SELECT
        centroid,
        osm_id,
        sport,
        surface,
        "surface:colour",
        hoops,
        ST_Area(geom) AS area_pitch,
        ST_Area(oriented_geom) AS area_rectangle,
        ST_ExteriorRing(oriented_geom) AS outline
    FROM rect_analysis
),
length_calc AS (
    SELECT
        centroid,
        osm_id,
        sport,
        surface,
        "surface:colour",
        hoops,
        area_pitch,
        area_rectangle,
        ST_PointN(outline, 1) AS p1,
        ST_PointN(outline, 2) AS p2,
        ST_PointN(outline, 3) AS p3,
        ST_Distance(ST_PointN(outline, 1), ST_PointN(outline, 2)) AS side1_length,
        ST_Distance(ST_PointN(outline, 2), ST_PointN(outline, 3)) AS side2_length
    FROM oriented_calc
)
SELECT
    osm_id,
    sport,
    surface,
    "surface:colour",
    hoops,
    -- get the length of the longer side of the rectangle
    ROUND(GREATEST(side1_length, side2_length)::NUMERIC, 1) AS dist_long,
    -- get the shorter length
    ROUND(LEAST(side1_length, side2_length)::NUMERIC, 1) AS dist_short,
    -- get the orientation angle (direction of the longer side of the rectangle)
    ROUND(
        DEGREES(
        CASE 
            WHEN side1_length >= side2_length
            THEN ST_Azimuth(p1, p2)
            ELSE ST_Azimuth(p2, p3)
        END
        )
    )::INTEGER AS direction,
    -- store all attributes at the centroid of the sport pitch that is used for the rendering of the markings
    centroid AS geom
FROM length_calc
-- Only for sports fields that are almost rectangular (area of the sports field similar to the area of the directional bounding box)
WHERE area_pitch / area_rectangle > 0.9;


-- Transfer direction back to vanilla sport pitch areas, esp. for better surface texture rendering (paving stones)
UPDATE pitch
SET direction = pitch_markings.direction
FROM pitch_markings
WHERE
    pitch.direction IS NULL
    AND pitch.osm_id = pitch_markings.osm_id;