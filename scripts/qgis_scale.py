#!/usr/bin/env python3
"""QGIS map scale <-> tile zoom, as the renderer actually computes it.

render/xyz_tiles.py renders a tile block with QgsMapSettings in EPSG:3857 at 96
dpi. QGIS derives the scale from the extent in map units (metres) without a
latitude correction, so the scale at tile zoom z is

    156543.03392804097 / 2**z   m/px  *  96 / 0.0254   px/m  ->  1:9028 at z16.

Earlier code assumed "z16 == 1:8000" (a round number, 11 % too small). With that
assumption every scale-based QGIS rule (label bands, label opacity steps, the
``$area / @map_scale`` and waterway label conditions) was converted to a zoom
0.17 levels too low, so MapLibre showed e.g. the 1:4000-1:16000 neighbourhood
labels at z15 although QGIS, at 1:18056, hides them there.
"""

import math

WEB_MERCATOR_METRES_PER_PIXEL_Z0 = 156543.03392804097
RENDER_DPI = 96
INCH_IN_METRES = 0.0254

# Scale denominator at tile zoom 16, also written into data/processing/sql/web/params_web.sql.
QGIS_SCALE_Z16 = WEB_MERCATOR_METRES_PER_PIXEL_Z0 / 2**16 * RENDER_DPI / INCH_IN_METRES


def scale_at_zoom(zoom: float) -> float:
    return QGIS_SCALE_Z16 * 2 ** (16 - zoom)


def zoom_at_scale(scale: float) -> float:
    """Raster tile zoom at which QGIS renders ``scale`` (1:scale)."""
    return 16 + math.log2(QGIS_SCALE_Z16 / scale)


if __name__ == "__main__":
    print(f"QGIS_SCALE_Z16 = {QGIS_SCALE_Z16:.4f}")
    for z in range(12, 21):
        print(f"z{z}: 1:{scale_at_zoom(z):,.0f}")
