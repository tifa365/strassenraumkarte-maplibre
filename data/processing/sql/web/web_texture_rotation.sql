-- web_texture_rotation.sql — deterministic angle buckets for QGIS RasterFill
-- surface textures.  MapLibre has no fill-pattern-rotate, so the vector tile
-- carries the nearest pre-rendered sprite angle.  The style combines this
-- literal rNNN suffix with its zoom-specific pattern family.

\i 'processing/sql/web/params_web.sql'

ALTER TABLE highway_area
    ADD COLUMN IF NOT EXISTS texture_rotation_bucket text,
    ADD COLUMN IF NOT EXISTS texture_paving_rotation_bucket text;

ALTER TABLE pitch
    ADD COLUMN IF NOT EXISTS texture_paving_rotation_bucket text;

UPDATE highway_area
SET
    texture_rotation_bucket = format(
        'r%s',
        lpad(
            (
                mod(
                    round(coalesce(direction, 0) / :texture_rotation_step_deg)::integer
                    * :texture_rotation_step_deg::integer,
                    360
                )
            )::integer::text,
            3,
            '0'
        )
    ),
    -- QGIS's paving_stones RasterFill is direction + 45 degrees.
    texture_paving_rotation_bucket = format(
        'r%s',
        lpad(
            (
                mod(
                    round((coalesce(direction, 0) + 45) / :texture_rotation_step_deg)::integer
                    * :texture_rotation_step_deg::integer,
                    360
                )
            )::integer::text,
            3,
            '0'
        )
    );

-- Pitch paving stones use the same direction + 45 degree expression as the
-- highway-area renderer.  Literal buckets are needed because MapLibre cannot
-- rotate a fill-pattern at render time.
UPDATE pitch
SET texture_paving_rotation_bucket = format(
    'r%s',
    lpad(
        (
            mod(
                round((coalesce(direction, 0) + 45) / :texture_rotation_step_deg)::integer
                * :texture_rotation_step_deg::integer,
                360
            )
        )::integer::text,
        3,
        '0'
    )
);
