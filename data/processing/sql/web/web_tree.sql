-- Stable MapLibre-facing tree attributes.
--
-- Imported/generated values normally exist already. Fill only genuinely
-- missing values in the indexed source table, deriving them from persistent
-- feature identity. This avoids request-time randf() and also avoids serving
-- 2.3 million points through an unindexed view. Tree stumps deliberately
-- retain no crown.

DROP VIEW IF EXISTS tree_web;

UPDATE tree
SET
    diameter_crown = CASE
        WHEN "natural" = 'tree_stump' THEN NULL
        WHEN diameter_crown > 0 THEN diameter_crown
        WHEN "natural" = 'shrub' THEN round(
            (
                3.0
                + abs(
                    hashtextextended(
                        concat_ws(':', osm_type::text, osm_id::text, 'crown'),
                        0
                    ) % 1000000
                ) / 1000000.0 * 3.0
            )::numeric,
            1
        )::real
        ELSE round(
            (
                5.0
                + abs(
                    hashtextextended(
                        concat_ws(':', osm_type::text, osm_id::text, 'crown'),
                        0
                    ) % 1000000
                ) / 1000000.0 * 4.0
            )::numeric,
            1
        )::real
    END,
    rotation = COALESCE(
        rotation,
        floor(
            abs(
                hashtextextended(
                    concat_ws(':', osm_type::text, osm_id::text, 'rotation'),
                    0
                ) % 1000000
            ) / 1000000.0 * 41.0 - 20.0
        )::integer
    )
WHERE
    ("natural" != 'tree_stump' AND coalesce(diameter_crown, 0) <= 0)
    OR rotation IS NULL;
