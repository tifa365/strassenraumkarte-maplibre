#!/usr/bin/env python3
"""Opacity compensation for lines thinner than about one pixel.

QGIS (Qt) draws a line whose true width w is below one pixel with coverage
proportional to w, so a 2 cm building seam or a 15 cm road marking at street
scale is faint. MapLibre's line shader adds a half-pixel antialiasing outset to
every line, so a near-zero-width line is rendered at about 50 % alpha across
roughly one pixel. Measured on the building seams of the bridge test block they
come out two to three times darker than QGIS.

For a line of width ``w`` px and no offset or blur the shader's alpha across the
line is ``clamp(h + 0.5 - |d|, 0, 1)`` with ``h = w / 2``; its integral, the
width the eye sees, is ``(w / 2 + 0.5) ** 2`` for ``w < 1``. Multiplying the
layer opacity by ``w / (w / 2 + 0.5) ** 2`` restores the QGIS coverage. For
``w >= 1`` the shader is accurate and the factor is 1.

The widths are zoom interpolations, so the factor is written as a zoom
interpolation of its own with one stop per integer zoom (the factor is not
linear in ``w``). The layer's original ``line-opacity`` is kept in
``metadata["strassenraumkarte:line-opacity-base"]`` so the pass is idempotent
and audits can still read the QGIS opacity.

Layers using ``line-offset``, ``line-blur``, ``line-pattern`` or
``line-gradient`` are left alone (``line-gap-width`` lines are two lines of the
same width, so they are compensated like any other): their rendering
is intentionally not a plain 1:1 line.
"""

from __future__ import annotations

import math
from typing import Any

BASE_OPACITY_KEY = "strassenraumkarte:line-opacity-base"
# QGIS layer opacity applied on top of the symbol opacity (see layer_opacity.py)
LAYER_FACTOR_KEY = "strassenraumkarte:qgis-layer-opacity"
_SKIPPED_PAINT = ("line-offset", "line-blur", "line-pattern", "line-gradient")


def _factor(width: Any) -> list[Any]:
    """Expression for the coverage factor of a width expression (px)."""
    return [
        "let", "w", width,
        ["case",
            ["<", ["var", "w"], 1],
            ["/", ["var", "w"], ["^", ["+", ["/", ["var", "w"], 2], 0.5], 2]],
            1],
    ]


def compensate(layer: dict[str, Any]) -> dict[str, Any]:
    """Add the thin-line opacity compensation to a line layer, in place."""
    if layer.get("type") != "line":
        return layer
    paint = layer.setdefault("paint", {})
    if any(key in paint for key in _SKIPPED_PAINT):
        return layer
    width = paint.get("line-width")
    if not (
        isinstance(width, list)
        and len(width) == 7
        and width[0] == "interpolate"
        and width[2] == ["zoom"]
        and width[1][0] == "exponential"
    ):
        return layer
    metadata = layer.setdefault("metadata", {})
    base_opacity = metadata.get(BASE_OPACITY_KEY, paint.get("line-opacity", 1))
    metadata[BASE_OPACITY_KEY] = base_opacity
    effective_opacity = base_opacity * metadata.get(LAYER_FACTOR_KEY, 1)
    exponent = width[1][1]
    first_zoom, first_width, last_zoom, last_width = width[3], width[4], width[5], width[6]
    span = last_zoom - first_zoom
    expression: list[Any] = ["interpolate", ["exponential", 2], ["zoom"]]
    for zoom in range(math.ceil(first_zoom), math.floor(last_zoom) + 1):
        ratio = (exponent ** (zoom - first_zoom) - 1) / (exponent**span - 1)
        if ratio == 0:
            stop_width = first_width
        elif ratio == 1:
            stop_width = last_width
        else:
            stop_width = ["+", first_width, ["*", ratio, ["-", last_width, first_width]]]
        factor = _factor(stop_width)
        expression += [zoom, factor if effective_opacity == 1 else ["*", round(effective_opacity, 6), factor]]
    paint["line-opacity"] = expression
    return layer
