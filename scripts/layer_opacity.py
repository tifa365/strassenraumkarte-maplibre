#!/usr/bin/env python3
"""QGIS layer opacity for MapLibre layers.

A QGIS layer has an opacity of its own on top of the alpha of its symbols: the
layer is drawn flattened and then composited at that opacity, so a red lane
colour with symbol alpha 0.45 in a layer at 0.67 ends up at 0.45 * 0.67. The
style only carried the symbol alpha, so all road markings, separation markers,
path casings, railway ties, pitch markings, landscape lines and tree trunks were
drawn 25-60 % too strong. Overlapping features inside one of these QGIS layers
are rare (tree crowns, the one layer where it matters, are tuned separately), so
applying the factor per feature is a close match.

``LAYER_OPACITY`` lists the QGIS layer each factor comes from; the parity audit
checks every entry against the project.

The symbol-level opacity is kept in layer metadata so the pass is idempotent.
Line layers store it under ``thin_lines.BASE_OPACITY_KEY`` (also read by the
audit); thin_lines.compensate() multiplies the layer factor into the
compensated opacity expression it generates.
"""

from __future__ import annotations

from typing import Any

import thin_lines

LAYER_FACTOR_KEY = thin_lines.LAYER_FACTOR_KEY
BASE_OPACITY_KEY = "strassenraumkarte:opacity-base"

# (match on MapLibre layer, QGIS layer name, QGIS layer opacity)
LAYER_OPACITY: tuple[tuple[dict[str, str], str, float], ...] = (
    ({"source": "road_marking_way"}, "road_marking_way", 0.67),
    ({"source": "road_marking_sharks_teeth"}, "road_marking_way", 0.67),
    ({"source": "road_marking_node"}, "road_marking_node", 0.67),
    ({"source": "road_marking_polygon"}, "road_marking_polygon", 0.67),
    ({"source": "road_marking_hatch"}, "road_marking_polygon", 0.67),
    ({"source": "separation"}, "separation", 0.67),
    ({"id_prefix": "highway-path-casing"}, "path (way, casing)", 0.67),
    ({"source": "railway_ties"}, "railway tie", 0.4),
    ({"source": "landscape_way"}, "landscape_way", 0.5),
    ({"source": "landscape_ticks"}, "landscape_way", 0.5),
    ({"source": "pitch_markings"}, "pitch_markings", 0.5),
    ({"id_prefix": "tree-trunk"}, "trunk", 0.75),
    ({"id_prefix": "construction-"}, "construction", 0.5),
)

_OPACITY_PROPERTY = {
    "fill": "fill-opacity",
    "line": "line-opacity",
    "symbol": "icon-opacity",
    "circle": "circle-opacity",
}


def _base_id(layer: dict[str, Any]) -> str:
    return layer["id"].split("--stratum-")[0]


def factor_for(layer: dict[str, Any]) -> float | None:
    for match, _qgis_layer, factor in LAYER_OPACITY:
        if "source" in match and layer.get("source") == match["source"]:
            return factor
        if "id_prefix" in match and _base_id(layer).startswith(match["id_prefix"]):
            return factor
    return None


def apply(layer: dict[str, Any]) -> dict[str, Any]:
    """Multiply the QGIS layer opacity into the layer's opacity, in place."""
    factor = factor_for(layer)
    prop = _OPACITY_PROPERTY.get(layer.get("type", ""))
    if prop is None:
        return layer
    if factor is None:
        # No (longer a) QGIS layer opacity: drop a stale factor from an earlier
        # run and restore the symbol-level opacity.
        metadata = layer.get("metadata", {})
        if metadata.pop(LAYER_FACTOR_KEY, None) is not None:
            base_key = thin_lines.BASE_OPACITY_KEY if layer["type"] == "line" else BASE_OPACITY_KEY
            if base_key in metadata:
                layer.setdefault("paint", {})[prop] = metadata[base_key]
        return layer
    paint = layer.setdefault("paint", {})
    metadata = layer.setdefault("metadata", {})
    metadata[LAYER_FACTOR_KEY] = factor
    base_key = thin_lines.BASE_OPACITY_KEY if layer["type"] == "line" else BASE_OPACITY_KEY
    current = paint.get(prop, 1)
    base = metadata.get(base_key, current if isinstance(current, (int, float)) else 1)
    metadata[base_key] = base
    # thin_lines.compensate() replaces this with an expression for eligible lines.
    paint[prop] = round(base * factor, 6)
    return layer
