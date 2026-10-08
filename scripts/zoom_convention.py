#!/usr/bin/env python3
"""Zoom conventions for web/style.json.

The QGIS map is rendered as 256 px raster tiles, where tile zoom Z shows
``ground_resolution = 156543.03 / 2**Z`` map units per pixel.  MapLibre uses a
512 px world, so MapLibre zoom Z shows the resolution of raster zoom Z + 1.
Everything in the style that is tied to the QGIS map -- sizes in ground metres
(``0.34385 px/m at z15``), scale-based layer visibility, texture-sprite bands --
is authored in *raster* zoom units.  Used unchanged in MapLibre it renders at
half size and appears one zoom level too late.

The fix is a uniform shift: ``style_maplibre(Z) = style_raster(Z + 1)``.  Every
zoom *position* (interpolate/step stops, layer minzoom/maxzoom, source minzoom)
moves down by one, values stay the same.  The convention a file is in is
recorded in ``metadata["strassenraumkarte:zoom-convention"]``.

Data properties that hold raster-convention zooms (``label_min_zoom``, derived
in SQL from QGIS scale rules) are compensated where they are compared with
``["zoom"]``: ``["get", "label_min_zoom"]`` becomes
``["+", ["get", "label_min_zoom"], -1]``.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

CONVENTION_KEY = "strassenraumkarte:zoom-convention"
RASTER = "raster-256"
MAPLIBRE = "maplibre-512"
# style zoom (MapLibre) = raster zoom + SHIFT_TO_MAPLIBRE
SHIFT_TO_MAPLIBRE = -1

_COMPARISONS = ("<", "<=", ">", ">=", "==", "!=")
_INTERPOLATIONS = ("interpolate", "interpolate-hcl", "interpolate-lab")
_LABEL_PROPERTY = ["get", "label_min_zoom"]


def _number(value: float) -> int | float:
    rounded = round(value, 6)
    return int(rounded) if rounded == int(rounded) else rounded


def _shift_label_operand(operand: Any, delta: int) -> Any:
    """Add ``delta`` to a ``label_min_zoom`` operand, normalising ``+ 0``."""
    offset = 0
    if operand == _LABEL_PROPERTY:
        pass
    elif (
        isinstance(operand, list)
        and len(operand) == 3
        and operand[0] == "+"
        and operand[1] == _LABEL_PROPERTY
        and isinstance(operand[2], (int, float))
    ):
        offset = operand[2]
    else:
        raise ValueError(f"unrecognised zoom comparison operand: {operand!r}")
    offset = _number(offset + delta)
    return copy.deepcopy(_LABEL_PROPERTY) if offset == 0 else ["+", copy.deepcopy(_LABEL_PROPERTY), offset]


def shift_expression(expression: Any, delta: int) -> Any:
    """Shift every zoom position in an expression (or paint/layout dict)."""
    if isinstance(expression, dict):
        if isinstance(expression.get("stops"), list):
            raise ValueError(
                "legacy zoom function {'stops': ...} cannot be shifted; "
                f"convert it to an expression first: {str(expression)[:120]}"
            )
        return {key: shift_expression(value, delta) for key, value in expression.items()}
    if not isinstance(expression, list) or not expression:
        return expression
    operator = expression[0]
    if operator in _INTERPOLATIONS and len(expression) >= 5 and expression[2] == ["zoom"]:
        result = [expression[0], copy.deepcopy(expression[1]), ["zoom"]]
        for index in range(3, len(expression), 2):
            result.append(_number(expression[index] + delta))
            result.append(shift_expression(expression[index + 1], delta))
        return result
    if operator == "step" and expression[1] == ["zoom"]:
        result = [operator, ["zoom"], shift_expression(expression[2], delta)]
        for index in range(3, len(expression), 2):
            result.append(_number(expression[index] + delta))
            result.append(shift_expression(expression[index + 1], delta))
        return result
    if operator in _COMPARISONS and len(expression) == 3 and ["zoom"] in expression[1:]:
        left, right = expression[1], expression[2]
        if left == ["zoom"]:
            return [operator, left, _shift_label_operand(right, delta)]
        return [operator, _shift_label_operand(left, delta), right]
    return [shift_expression(item, delta) for item in expression]


def shift_layer(layer: dict[str, Any], delta: int) -> dict[str, Any]:
    result = copy.deepcopy(layer)
    for key in ("minzoom", "maxzoom"):
        if key in result:
            result[key] = _number(max(0, result[key] + delta))
    for section in ("filter", "paint", "layout"):
        if section in result:
            result[section] = shift_expression(result[section], delta)
    return result


def convention_of(style: dict[str, Any]) -> str:
    # Files authored before this module existed carry no marker and are raster.
    return style.get("metadata", {}).get(CONVENTION_KEY, RASTER)


def convert_style(style: dict[str, Any], target: str) -> dict[str, Any]:
    """Return a copy of ``style`` in the ``target`` zoom convention."""
    if target not in (RASTER, MAPLIBRE):
        raise ValueError(f"unknown zoom convention {target!r}")
    current = convention_of(style)
    result = copy.deepcopy(style)
    if current != target:
        delta = SHIFT_TO_MAPLIBRE if target == MAPLIBRE else -SHIFT_TO_MAPLIBRE
        result["layers"] = [shift_layer(layer, delta) for layer in style["layers"]]
        for source in result.get("sources", {}).values():
            if "minzoom" in source:
                source["minzoom"] = _number(max(0, source["minzoom"] + delta))
    result.setdefault("metadata", {})[CONVENTION_KEY] = target
    return result


def load_style(path: Path, convention: str = MAPLIBRE) -> dict[str, Any]:
    """Load a style file, converted (in memory) to ``convention``."""
    return convert_style(json.loads(Path(path).read_text()), convention)
