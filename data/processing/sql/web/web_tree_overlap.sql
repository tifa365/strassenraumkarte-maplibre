-- web_tree_overlap.sql — crown overlap depth, so MapLibre can reproduce the
-- QGIS "tree crown" layer opacity.
--
-- QGIS draws all crowns into one layer and composites that flattened layer at
-- 0.25: a crown is 0.25 over the background however many crowns overlap it.
-- MapLibre's icon-opacity is per icon, so k overlapping crowns at alpha a
-- compound to 1 - (1 - a)^k. With crown_overlap = k, the mean number of crowns
-- covering a point of this crown (1 + the other crowns' overlap area / own
-- area), the style uses a = 1 - 0.75^(1/k): isolated crowns get QGIS's 0.25 and
-- k stacked crowns add up to 0.25 again.
--
-- The crown artwork fills ~0.93 of the icon half-width (diameter_crown), so the
-- effective radius is 0.45 * diameter_crown. The largest crowns are 30 m, which
-- bounds the neighbour search at 2 * 0.45 * 30 = 27 m.

ALTER TABLE tree
    ADD COLUMN IF NOT EXISTS crown_overlap real;

-- Pairs come from an indexed self-join of tree (a CTE referenced twice is
-- materialised without an index and degenerates to an n^2 nested loop).
CREATE TEMP TABLE crown_pairs AS
SELECT
    a.osm_type,
    a.osm_id,
    0.45 * a.diameter_crown * u.f AS r1,
    0.45 * b.diameter_crown * u.f AS r2,
    ST_Distance(a.geom, b.geom) AS d
FROM (SELECT metres(1.0) AS f) u
CROSS JOIN tree a
JOIN tree b
  ON ST_DWithin(a.geom, b.geom, 27.0 * u.f)
 AND NOT (a.osm_type = b.osm_type AND a.osm_id = b.osm_id)
WHERE a."natural" IN ('tree', 'shrub') AND a.diameter_crown > 0
  AND b."natural" IN ('tree', 'shrub') AND b.diameter_crown > 0
  AND ST_Distance(a.geom, b.geom) < 0.45 * (a.diameter_crown + b.diameter_crown) * u.f;

CREATE TEMP TABLE crown_depth AS
SELECT
    osm_type,
    osm_id,
    -- 1 + (sum of intersection areas of the circles r1, r2 at distance d) / own area
    1 + sum(
        CASE
            WHEN d <= abs(r1 - r2) THEN pi() * least(r1, r2) ^ 2
            ELSE r1 ^ 2 * acos(greatest(-1.0, least(1.0, (d ^ 2 + r1 ^ 2 - r2 ^ 2) / (2 * d * r1))))
               + r2 ^ 2 * acos(greatest(-1.0, least(1.0, (d ^ 2 + r2 ^ 2 - r1 ^ 2) / (2 * d * r2))))
               - 0.5 * sqrt(greatest(0.0, (-d + r1 + r2) * (d + r1 - r2) * (d - r1 + r2) * (d + r1 + r2)))
        END
    ) / (pi() * max(r1) ^ 2) AS k
FROM crown_pairs
GROUP BY osm_type, osm_id;

UPDATE tree t
SET crown_overlap = crown_depth.k
FROM crown_depth
WHERE t.osm_type = crown_depth.osm_type AND t.osm_id = crown_depth.osm_id;

UPDATE tree
SET crown_overlap = 1
WHERE crown_overlap IS NULL AND "natural" IN ('tree', 'shrub');
