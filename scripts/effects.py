#!/usr/bin/env python3
"""QGIS paint effects (drop shadow, inner shadow, outer glow) as MapLibre line layers.

QGIS draws these as blurred, offset copies of a polygon composited with the
symbol. MapLibre has no effects, but a blurred line along the polygon outline
gives the same soft edge: `line-blur` equal to the line width makes the alpha
fall linearly from the outline to zero at `blur` metres on both sides, and the
polygon fill drawn on top hides the inner half (drop shadow, outer glow) or
the line is drawn above the fill and pushed inwards (inner shadow).

The line's opacity is 0.75 x the QGIS effect opacity: a blurred step edge
is half as strong at the edge as inside, but MapLibre's linear ramp falls off
faster than QGIS's blur, so the factor was set from the luminance profile next
to buildings on z18/z19 renders (0.5 too light at the wall, 1.0 too dark 2-6 px
out). Offsets follow QGIS's convention, a
compass bearing clockwise from north (checked on a z19 render: building
shadows fall to the north-east for 40°), converted to MapLibre's screen
`line-translate` (x east, y down). QGIS values are map units; divide by the
Mercator scale (~1.64 at Berlin) to get ground metres.

`EFFECTS` lists the ported effects; `apply(style)` (re)inserts their layers
directly before (shadow) or after (inner shadow, outside glow) the layer they
belong to, so the pass is idempotent.
"""

from __future__ import annotations

import math
from typing import Any

MERCATOR_SCALE = 1.6417  # Berlin; QGIS map units per ground metre
PX_PER_M = ((14, 0.34385), (19, 11.0032))  # MapLibre zoom -> px per ground metre
EFFECT_KEY = "strassenraumkarte:qgis-effect"


def _metres(map_units: float) -> float:
    return map_units / MERCATOR_SCALE


def _scaled(value_m: float) -> list[Any]:
    return ["interpolate", ["exponential", 2], ["zoom"],
            *(v for zoom, ppm in PX_PER_M for v in (zoom, round(value_m * ppm, 5)))]


def _translate(distance_m: float, bearing: float) -> list[Any]:
    dx = math.sin(math.radians(bearing)) * distance_m
    dy = -math.cos(math.radians(bearing)) * distance_m  # screen y points down
    return ["interpolate", ["exponential", 2], ["zoom"],
            *(v for zoom, ppm in PX_PER_M for v in (zoom, ["literal", [round(dx * ppm, 5), round(dy * ppm, 5)]]))]


def shadow_layer(effect: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
    blur_m = _metres(effect.get("blur", 0))
    if effect["kind"] == "cast_shadow":
        # a taller part's shadow on a lower neighbour: a band left of the wall line (the
        # lower part's side), width/blur in ground metres, opacity by the wall's `facing`
        paint: dict[str, Any] = {
            "line-color": effect["color"],
            "line-opacity": ["interpolate", ["linear"], ["get", "facing"],
                             *(v for f, share in ((-1, 0.25), (0, 0.6), (1, 1.05)) for v in (f, round(effect["opacity"] * share, 4)))],
            "line-width": _scaled(effect["width_m"]),
            "line-blur": _scaled(effect["blur_m"]),
            "line-offset": _scaled(-effect["width_m"] / 2),
        }
    elif effect.get("outside"):
        # outer glow: a band entirely outside the ring, drawn above the fill (other fills
        # of the same layer would cover a line underneath); MVT exterior rings have the
        # outside on the left, where line-offset is negative
        spread_m = _metres(effect["spread"])
        paint: dict[str, Any] = {
            "line-color": effect["color"],
            "line-opacity": effect["opacity"],
            "line-width": _scaled(spread_m + blur_m),
            "line-blur": _scaled(blur_m),
            "line-offset": _scaled(-(spread_m + blur_m) / 2),
        }
    else:
        paint = {
            "line-color": effect["color"],
            "line-opacity": round(effect["opacity"] * 0.75, 4),
            "line-width": _scaled(2 * blur_m),
            "line-blur": _scaled(2 * blur_m),
        }
    if effect.get("offset"):
        paint["line-translate"] = _translate(_metres(effect["offset"]), effect.get("bearing", 0))
        paint["line-translate-anchor"] = "map"
    if effect["kind"] == "inner_shadow":
        paint["line-offset"] = _scaled(blur_m)  # inward for MVT exterior rings
    source = effect.get("source", target["source"])
    layer: dict[str, Any] = {
        "id": effect["id"],
        "type": "line",
        "source": source,
        "source-layer": source if "source" in effect else target.get("source-layer", source),
        "layout": {"line-join": "round"},
        "paint": paint,
        "metadata": {EFFECT_KEY: effect["qgis"]},
    }
    for key in ("filter", "minzoom", "maxzoom"):
        if key in target and "source" not in effect:
            layer[key] = target[key]
    for key in ("filter", "minzoom"):
        if key in effect:
            layer[key] = effect[key]
    return layer


# QGIS values: blur and offset in map units, bearing in degrees, opacity of the effect.
EFFECTS: tuple[dict[str, Any], ...] = (
    {
        # merged outlines of touching parts (web_building_outline.sql): no dots at shared walls
        "id": "building-shadow", "target": "building-fill", "kind": "drop_shadow", "source": "building_outline",
        "qgis": "building_parts_dissolved_height dropShadow",
        "color": "#232323", "opacity": 0.4, "blur": 2.0, "offset": 1.0, "bearing": 40,
    },
    # The same shadow where a taller part meets a lower one (web_building_height_steps.sql):
    # QGIS draws parts ordered by height, so it falls on the lower roof. Two nested bands
    # fitted to QGIS's luminance on the lower roof next to such walls (z18 Hermannplatz:
    # 17/9/4/2 darker 1-4 px from walls facing north-east, a quarter of that facing
    # south-west), then set to 0.7 x those opacities: the original tiles are about half as
    # dark, full QGIS strength read as 3D but too heavy (owner, 2026-10-07). A single
    # blurred QGIS-sized band peaked 2-4 px from the wall.
    *(
        {"id": f"building-step-shadow{suffix}", "target": "building-fill", "kind": "cast_shadow",
         "source": "building_height_step",
         "qgis": "building_parts_dissolved_height dropShadow (ordered by height)",
         "color": "#232323", "opacity": opacity, "width_m": width_m, "blur_m": blur_m}
        for suffix, width_m, blur_m, opacity in (("", 0.567, 0.182, 0.0886), ("-soft", 1.705, 1.463, 0.0345))
    ),
    # Landuse outer glows (spread 0.75, blur 0.75 map units) as bands outside the ring, above
    # the fill so neighbouring landuse does not cover them. QGIS also draws a drop shadow
    # (0.33 at 0.4 map units, 40°; shrub family 0.1): with it the edge was too dark 2 px out
    # on z18 (forest 181 vs QGIS 183, scrub 193 vs 205) and in the fill's antialiased edge
    # pixel, so only the glows are ported; they alone account for most of the darker edge.
    {"id": "landuse-glow", "target": "landuse-fill", "kind": "outer_glow", "outside": True,
     "qgis": "landuse forest/wood/trees/shrub/shrubbery/tundra outerGlow",
     "filter": ["match", ["get", "class"], ["forest", "wood", "trees", "shrub", "shrubbery", "tundra"], True, False],
     "color": "#c8dbb6", "opacity": 1.0, "blur": 0.75, "spread": 0.75},
    {"id": "landuse-glow-scrub", "target": "landuse-scrub-fill", "kind": "outer_glow", "outside": True,
     "qgis": "scrub (width shade) outerGlow",
     "color": "#c4d8af", "opacity": 1.0, "blur": 0.75, "spread": 0.75},
)


def apply(style: dict[str, Any]) -> None:
    layers = [l for l in style["layers"] if EFFECT_KEY not in l.get("metadata", {})]
    by_id = {l["id"]: l for l in layers}
    for effect in EFFECTS:
        target = by_id[effect["target"]]
        layer = shadow_layer(effect, target)
        index = layers.index(target)
        layers.insert(index + 1 if effect["kind"] in ("inner_shadow", "cast_shadow") or effect.get("outside") else index, layer)
    style["layers"] = layers
