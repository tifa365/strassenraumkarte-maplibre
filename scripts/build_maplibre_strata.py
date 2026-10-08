#!/usr/bin/env python3
"""Expand highway prototypes into QGIS's six bridge/tunnel draw strata.

QGIS draws the unchecked ``highway (unlayered)`` template as six filtered
clones.  MapLibre fill layers have no feature sort key and its line sort key
cannot interleave fills from other sources, so literal style-layer groups are
required.  The groups here are emitted bottom-to-top: deep tunnels first,
then -1, ground, +1, +2, and high bridges last.

The generated ground clone retains each layer's original filter in metadata,
which makes this command idempotent. Edit the ground clone (including its
``strassenraumkarte:base-filter`` metadata) and rerun to propagate a change.
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any

import effects
import layer_opacity
import thin_lines
import zoom_convention as zc


ROOT = Path(__file__).resolve().parents[1]
# MapLibre antialiases a fill by drawing a 1 px outline in the fill colour over
# its edges, so a semi-transparent fill is composited twice along them. For the
# small embankment triangles and railway ties that doubled edge made them far
# too heavy (embankment dE 15.1 -> 9.4 without it). Road-marking fills keep
# antialiasing: unantialiased, sub-pixel lane colours drop out of most pixels
# instead of tinting them (cycleway dE 4.6 -> 9.8), see MAPLIBRE_PARITY.md.
# Calibrated, not derived from the QGIS project: the embankment ticks and line are sub-pixel to
# 2 px and MapLibre draws them far heavier than QGIS draws the flattened 0.5-opacity layer
# (class median 181,199,146 against QGIS 194,201,162 with the QGIS opacities; 188,202,157 with
# these factors, dE 8.7 -> 4.3; the line alone barely matters, the ticks carry the error).
EMPIRICAL_OPACITY = {
    "landscape-ticks": 0.24,
    "landscape-way-base": 0.4,
}


def scale_opacity(layer: dict[str, Any], factor: float) -> None:
    """Multiply a layer's (fill|line)-opacity, a number or a zoom interpolation, by factor."""
    prop = {"fill": "fill-opacity", "line": "line-opacity"}[layer["type"]]
    value = layer["paint"].get(prop, 1)
    if isinstance(value, (int, float)):
        layer["paint"][prop] = round(value * factor, 6)
    elif isinstance(value, list) and value[0] == "interpolate":
        layer["paint"][prop] = value[:3] + [
            item if index % 2 == 1 else ["*", factor, item]
            for index, item in enumerate(value[3:], start=3)
        ]


# Zebra stripes (0.5 m) likewise: at z19 their area matches QGIS without it
# (274 vs 287 px; 393 with), at z17 the integrated stripe colour is within 4 %
# of QGIS (64 % too strong with).
UNANTIALIASED_FILLS = {
    "railway-ties",
    "landscape-ticks",
    "road-marking-polygon-zebra",
    # 0.4-0.6 m wall/bollard markers: retaining wall dE 10.2 -> 4.5 (bollard
    # 0.4 -> 2.6, 130 px), same-session mean 1.909 -> 1.898.
    "barrier-way-marker-fill",
}
DEFAULT_STYLE = ROOT / "web" / "style.json"
SOURCE_ORDER = {
    # Bottom to top as in each QGIS "layer = N" group (layer tree order reversed):
    # bridge_shade, bridge, railway, path, service, tactile paving,
    # highway_area, road markings, feature (background), barrier way/polygon,
    # playground, feature (middleground), barrier_node. Layers of one table
    # that QGIS draws at two depths override this with metadata[RANK_KEY].
    "bridge_shade": -6,
    "bridge": -5.5,
    "railway_ties": -5,
    "railway_way": -4.9,
    "railway_node": -4.8,
    "highway": -3,
    "highway_hashes": -3,
    "highway_service": 0,
    # SQL-derived crosses from QGIS's tactile-paving MarkerLine.
    "tactile_paving": 0.5,
    "highway_area": 1,
    # Merged carriageway rings (web_highway_area_outline.sql) for the edge
    # shade, drawn among the highway_area layers.
    "highway_area_outline": 1,
    "road_marking_polygon": 2,
    # SQL-derived hatching of the same QGIS layer's LinePatternFill, drawn
    # after its outline (emitted after the literal polygon layers).
    "road_marking_hatch": 2,
    "road_marking_node": 2.5,
    "road_marking_way": 3,
    # Server-derived geometry for QGIS's road_marking_way MarkerLine. It
    # occupies the same family slot and is emitted after the literal lines.
    "road_marking_sharks_teeth": 3,
    "separation": 5,
    # feature (background): pier, background polygons
    "feature_way": 7,
    "feature_polygon": 7.1,
    "barrier_polygon": 9,
    "barrier_way": 10,
    "barrier_way_marker_polygons": 11,
    "playground_way": 14,
    "playground_polygon": 14.5,
    "playground_node": 15,
    "pitch": 16.5,
    # feature (middleground) layers carry RANK_KEY 17-17.5
    "feature_node": 18,
    "barrier_node": 18.5,
}
SPRITE_ZOOM_BANDS = range(14, 21)  # sprite families are baked for z14..z20


def zoom_banded_image(family: str, *suffix: Any) -> list[Any]:
    """Pick a per-zoom sprite as ``step(zoom, image(<family>14<suffix>), ...)``.

    MapLibre only allows ``["zoom"]`` as the input of a top-level ``step`` or
    ``interpolate``, so ``concat(family, floor(zoom))`` is rejected and takes
    the whole style down with it.
    """
    expression: list[Any] = ["step", ["zoom"]]
    for zoom in SPRITE_ZOOM_BANDS:
        name: Any = f"{family}{zoom}"
        if suffix:
            name = ["concat", name, *suffix]
        image = ["image", name]
        expression.extend([image] if zoom == SPRITE_ZOOM_BANDS[0] else [zoom, image])
    return expression


# Authored in raster-zoom units (0.34385 px/m at z15, minzoom 15 ...), like the
# QGIS map they mirror; converted to the style's MapLibre convention below.
_DERIVED_PROTOTYPES_RASTER: tuple[dict[str, Any], ...] = (
    {
        "id": "railway-ties",
        "type": "fill",
        "source": "railway_ties",
        "source-layer": "railway_ties",
        "minzoom": 15,
        # QGIS "railway tie": #a8a8a7, disused/abandoned/construction #b0b0af
        "paint": {"fill-color": ["case", ["==", ["get", "disused"], True], "#b0b0af", "#a8a8a7"]},
    },
    {
        "id": "highway-hashes",
        "type": "fill",
        "source": "highway_hashes",
        "source-layer": "highway_hashes",
        "minzoom": 15,
        # QGIS path (way, fill): steps #979c90 0.06 m, access aisles #ffffea 0.5 m.
        # MapLibre antialiases a sub-pixel polygon to about one pixel, so the
        # 0.06 m steps strokes get their pixel coverage as opacity (like
        # thin_lines.py for lines): 0.06 m * px/m, reaching 1 px at raster z21.
        "paint": {
            "fill-color": ["match", ["get", "kind"], "steps", "#979c90", "#ffffea"],
            "fill-opacity": [
                "interpolate", ["exponential", 2], ["zoom"],
                15, ["match", ["get", "kind"], "steps", 0.34385 * 0.06, 1],
                20, ["match", ["get", "kind"], "steps", 11.0032 * 0.06, 1],
            ],
        },
    },
    {
        "id": "bridge-fill",
        "type": "fill",
        "source": "bridge",
        "source-layer": "bridge",
        "minzoom": 15,
        # QGIS bridge SimpleFill #e8e8e8 (#dddddd is its disabled outline colour)
        "paint": {"fill-color": "#e8e8e8"},
    },
    {
        "id": "bridge-shade-fill",
        "type": "fill",
        "source": "bridge_shade",
        "source-layer": "bridge_shade",
        "minzoom": 15,
        # QGIS bridge_shade SimpleFill #e8e8e8 (#dddddd is its disabled outline colour)
        "paint": {"fill-color": "#e8e8e8"},
    },
    {
        # QGIS road_marking_polygon LinePatternFill: 0.25 m white lines,
        # clipped to the polygon (web_road_marking_hatch.sql).
        "id": "road-marking-polygon-hatch",
        "type": "line",
        "source": "road_marking_hatch",
        "source-layer": "road_marking_hatch",
        "minzoom": 15,
        "layout": {"line-cap": "butt", "line-join": "bevel"},
        "paint": {
            "line-color": ["to-color", ["coalesce", ["get", "colour"], "#ffffff"]],
            "line-width": ["interpolate", ["exponential", 2], ["zoom"], 15, 0.34385 * 0.25, 20, 11.0032 * 0.25],
        },
    },
    {
        "id": "road-marking-way-sharks-teeth",
        "type": "fill",
        "source": "road_marking_sharks_teeth",
        "source-layer": "road_marking_sharks_teeth",
        "minzoom": 15,
        "paint": {
            "fill-color": ["coalesce", ["get", "colour"], "#ffffff"],
        },
    },
    {
        "id": "tactile-paving-fill",
        "type": "fill",
        "source": "tactile_paving",
        "source-layer": "tactile_paving",
        "minzoom": 15,
        "paint": {"fill-color": "#ff0000"},
    },
    {
        "id": "tactile-paving-outline",
        "type": "line",
        "source": "tactile_paving",
        "source-layer": "tactile_paving",
        "minzoom": 15,
        "paint": {
            "line-color": "#eae8e3",
            "line-width": [
                "interpolate", ["exponential", 2], ["zoom"],
                15, 0.34385 * 0.12,
                20, 11.0032 * 0.12,
            ],
        },
    },
    {
        "id": "separation-marker-fill",
        "type": "fill",
        "source": "separation",
        "source-layer": "separation",
        "minzoom": 15,
        "paint": {"fill-color": ["get", "colour"]},
    },
    {
        "id": "separation-marker-outline",
        "type": "line",
        "source": "separation",
        "source-layer": "separation",
        "minzoom": 15,
        "paint": {
            "line-color": ["get", "outline_colour"],
            "line-width": [
                "interpolate", ["exponential", 2], ["zoom"],
                15, 0.34385 * 0.1,
                20, 11.0032 * 0.1,
            ],
        },
    },
    {
        "id": "barrier-way-marker-fill",
        "type": "fill",
        "source": "barrier_way_marker_polygons",
        "source-layer": "barrier_way_marker_polygons",
        "minzoom": 15,
        "paint": {"fill-color": ["get", "colour"]},
    },
    {
        "id": "feature-polygon-fountain-pattern",
        "type": "fill",
        "source": "feature_polygon",
        "source-layer": "feature_polygon",
        "minzoom": 15,
        "filter": ["==", ["get", "class"], "fountain"],
        "paint": {
            "fill-pattern": zoom_banded_image("water-z"),
            "fill-opacity": 0.2,
        },
    },
    {
        "id": "pitch-surface-grass-pattern",
        "type": "fill",
        "source": "pitch",
        "source-layer": "pitch",
        "minzoom": 15,
        "filter": ["==", ["get", "surface"], "grass"],
        "paint": {"fill-pattern": "texture-grass", "fill-opacity": 0.06},
    },
    {
        "id": "pitch-surface-sand-pattern",
        "type": "fill",
        "source": "pitch",
        "source-layer": "pitch",
        "minzoom": 15,
        "filter": ["match", ["get", "surface"], ["clay", "compacted", "dirt", "earth", "fine_gravel", "gravel", "ground", "sand"], True, False],
        "paint": {"fill-pattern": "texture-sand", "fill-opacity": 0.08},
    },
    {
        "id": "pitch-surface-asphalt-pattern",
        "type": "fill",
        "source": "pitch",
        "source-layer": "pitch",
        "minzoom": 15,
        "filter": ["match", ["get", "surface"], ["artificial_turf", "asphalt", "rubber", "rubbercrumb", "tartan"], True, False],
        "paint": {
            "fill-pattern": zoom_banded_image("surface-asphalt-z"),
            "fill-opacity": 0.06,
        },
    },
    {
        "id": "pitch-surface-concrete-pattern",
        "type": "fill",
        "source": "pitch",
        "source-layer": "pitch",
        "minzoom": 15,
        "filter": ["match", ["get", "surface"], ["concrete", "concrete:plates"], True, False],
        "paint": {
            "fill-pattern": zoom_banded_image("surface-concrete-z", "-r000"),
            "fill-opacity": 0.15,
        },
    },
    {
        "id": "pitch-surface-paving-pattern",
        "type": "fill",
        "source": "pitch",
        "source-layer": "pitch",
        "minzoom": 15,
        "filter": ["==", ["get", "surface"], "paving_stones"],
        "paint": {
            "fill-pattern": zoom_banded_image("surface-paving-stones-z", "-", ["coalesce", ["get", "texture_paving_rotation_bucket"], "r045"]),
            "fill-opacity": 0.07,
        },
    },
    {
        "id": "pitch-surface-sett-pattern",
        "type": "fill",
        "source": "pitch",
        "source-layer": "pitch",
        "minzoom": 15,
        "filter": ["==", ["get", "surface"], "sett"],
        "paint": {
            "fill-pattern": zoom_banded_image("surface-sett-11-z", "-r000"),
            "fill-opacity": 0.12,
        },
    },
    {
        "id": "pitch-surface-woodchips-pattern",
        "type": "fill",
        "source": "pitch",
        "source-layer": "pitch",
        "minzoom": 15,
        "filter": ["==", ["get", "surface"], "woodchips"],
        "paint": {
            "fill-pattern": zoom_banded_image("surface-woodchips-z"),
            "fill-opacity": 0.1,
        },
    },
    {
        "id": "playground-sandpit-pattern",
        "type": "fill",
        "source": "playground_polygon",
        "source-layer": "playground_polygon",
        "minzoom": 15,
        "filter": ["==", ["get", "playground"], "sandpit"],
        "paint": {"fill-pattern": "texture-sand", "fill-opacity": 0.08},
    },
)
DERIVED_PROTOTYPES: tuple[dict[str, Any], ...] = tuple(
    zc.shift_layer(layer, zc.SHIFT_TO_MAPLIBRE) for layer in _DERIVED_PROTOTYPES_RASTER
)
STRATA: tuple[tuple[str, str, list[Any]], ...] = (
    ("low", "<= -2", ["<=", ["coalesce", ["get", "layer"], 0], -2]),
    ("minus-1", "= -1", ["==", ["coalesce", ["get", "layer"], 0], -1]),
    (
        "ground",
        "= 0 or NULL",
        ["==", ["coalesce", ["get", "layer"], 0], 0],
    ),
    ("plus-1", "= 1", ["==", ["coalesce", ["get", "layer"], 0], 1]),
    ("plus-2", "= 2", ["==", ["coalesce", ["get", "layer"], 0], 2]),
    ("high", ">= 3", [">=", ["coalesce", ["get", "layer"], 0], 3]),
)
SUFFIXES = tuple(f"--stratum-{name}" for name, _, _ in STRATA)


def is_highway_layer(layer: dict[str, Any]) -> bool:
    return layer.get("source-layer") in SOURCE_ORDER


RANK_KEY = "strassenraumkarte:family-rank"


def family_rank(layer: dict[str, Any]) -> float:
    """Draw-order slot of a layer within a stratum.

    Normally the rank of its source table; a layer can override it with
    metadata[RANK_KEY] when QGIS draws it at a different depth than the rest of
    its table (e.g. bus platforms are feature_way/feature_polygon rows but sit
    between the separation and barrier layers).
    """
    return layer.get("metadata", {}).get(RANK_KEY, SOURCE_ORDER[layer["source-layer"]])


def normalize_highway_filter(expression: Any) -> Any:
    """Map an obsolete raw-tag reference to the imported highway schema."""
    if isinstance(expression, list):
        return [normalize_highway_filter(item) for item in expression]
    return "class" if expression == "footway" else expression


def prototypes(
    layers: list[dict[str, Any]], available_sources: set[str]
) -> list[dict[str, Any]]:
    generated_ground = [
        layer
        for layer in layers
        if layer.get("metadata", {}).get("strassenraumkarte:stratum") == "ground"
        and is_highway_layer(layer)
    ]
    if generated_ground:
        # A source rename can leave an old generated layer beside its new
        # prototype. Treat the base id as canonical so repeated builds cannot
        # multiply an otherwise identical six-stratum family.
        ground_by_base_id = {
            layer.get("metadata", {}).get(
                "strassenraumkarte:base-id", layer["id"]
            ): layer
            for layer in generated_ground
        }
        generated_ground = list(ground_by_base_id.values())
        # Preserve already-generated ground clones as the canonical templates,
        # but also admit newly added eligible layers.  Without this, a source
        # introduced after the first expansion is silently removed by build().
        generated_ids = {
            layer.get("metadata", {}).get("strassenraumkarte:base-id", layer["id"])
            for layer in generated_ground
        }
        new_layers = [
            layer
            for layer in layers
            if is_highway_layer(layer)
            and "strassenraumkarte:stratum" not in layer.get("metadata", {})
            and layer["id"] not in generated_ids
        ]
        source = generated_ground + new_layers
    else:
        source = [layer for layer in layers if is_highway_layer(layer)]
    result: list[dict[str, Any]] = []
    for order, layer in enumerate(source):
        item = copy.deepcopy(layer)
        metadata = item.get("metadata", {})
        base_id = metadata.get("strassenraumkarte:base-id", item["id"])
        base_filter = metadata.get("strassenraumkarte:base-filter", item.get("filter"))
        if item.get("source-layer") == "highway":
            base_filter = normalize_highway_filter(base_filter)
        item["id"] = base_id
        item.pop("metadata", None)
        # Keep the opacity bookkeeping (symbol-level base opacity, QGIS layer
        # factor) that the post-pass below recomputes from; the stratum keys
        # are rebuilt by expand().
        kept = {
            key: value
            for key, value in metadata.items()
            if key.startswith(("strassenraumkarte:opacity", "strassenraumkarte:line-opacity", "strassenraumkarte:qgis-layer-opacity", RANK_KEY))
        }
        if kept:
            item["metadata"] = kept
        if base_filter is None:
            item.pop("filter", None)
        else:
            item["filter"] = base_filter
        item["_stratum_order"] = order
        result.append(item)
    # Derived tables and generated non-native renderers are defined in this
    # script, so their declarations are authoritative on every build.  Unlike
    # hand-authored ground clones, do not retain stale generated definitions.
    derived_ids = {item["id"] for item in DERIVED_PROTOTYPES}
    result = [item for item in result if item["id"] not in derived_ids]
    represented_ids = {item["id"] for item in result}
    for derived in DERIVED_PROTOTYPES:
        if (
            derived["source"] in available_sources
            and derived["id"] not in represented_ids
        ):
            item = copy.deepcopy(derived)
            item["_stratum_order"] = len(source) + len(result)
            result.append(item)
    result.sort(key=lambda layer: (family_rank(layer), layer["_stratum_order"]))
    for layer in result:
        layer.pop("_stratum_order")
    return result


def expand(prototype_layers: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for stratum, qgis_filter, stratum_filter in STRATA:
        for prototype in prototype_layers:
            layer = copy.deepcopy(prototype)
            base_id = layer["id"]
            base_filter = layer.get("filter")
            layer["id"] = f"{base_id}--stratum-{stratum}"
            layer["metadata"] = {
                **layer.get("metadata", {}),
                "strassenraumkarte:base-id": base_id,
                "strassenraumkarte:base-filter": base_filter,
                "strassenraumkarte:stratum": stratum,
                "strassenraumkarte:qgis-layer-filter": qgis_filter,
            }
            if base_filter is None:
                layer["filter"] = copy.deepcopy(stratum_filter)
            else:
                layer["filter"] = [
                    "all",
                    copy.deepcopy(stratum_filter),
                    base_filter,
                ]
            result.append(layer)
    return result


def build(style_path: Path) -> None:
    style = json.loads(style_path.read_text())
    if zc.convention_of(style) != zc.MAPLIBRE:
        raise SystemExit(
            f"{style_path.name} is not in the {zc.MAPLIBRE} zoom convention; "
            "run: python3 scripts/shift_style_zoom.py --to maplibre"
        )
    layers = style["layers"]
    candidate_indices = [
        index for index, layer in enumerate(layers) if is_highway_layer(layer)
    ]
    if not candidate_indices:
        raise ValueError("style has no represented highway layers to stratify")
    # Anchor the block at the first already-generated stratum layer. A new
    # prototype added anywhere else in the list (e.g. at the top) must not drag
    # the whole road block with it and bury it under landuse and water.
    generated_indices = [
        index
        for index in candidate_indices
        if layers[index].get("metadata", {}).get("strassenraumkarte:stratum")
    ]
    insert_at = min(generated_indices or candidate_indices)
    prototype_layers = prototypes(layers, set(style["sources"]))
    remaining = [layer for layer in layers if not is_highway_layer(layer)]
    removed_before = sum(1 for index in candidate_indices if index < insert_at)
    insert_at -= removed_before
    expanded = expand(prototype_layers)
    style["layers"] = remaining[:insert_at] + expanded + remaining[insert_at:]
    # QGIS paint effects (drop shadows ...) as blurred outline layers, see effects.py
    effects.apply(style)
    for layer in style["layers"]:
        layer_opacity.apply(layer)
        thin_lines.compensate(layer)
        factor = EMPIRICAL_OPACITY.get(layer["id"].split("--stratum-")[0])
        if factor is not None:
            scale_opacity(layer, factor)
        if layer.get("type") == "fill":
            if layer["id"].split("--stratum-")[0] in UNANTIALIASED_FILLS:
                layer.setdefault("paint", {})["fill-antialias"] = False
            else:
                layer.get("paint", {}).pop("fill-antialias", None)
    style.setdefault("metadata", {}).update(
        {
            "strassenraumkarte:layer-strata": [
                "highway",
                "bridge",
                "bridge_shade",
                "highway_area",
                "highway_service",
                "road_marking_polygon",
                "road_marking_way",
                "road_marking_node",
                "separation",
                "tactile_paving",
                "feature_node",
                "barrier_node",
                "barrier_polygon",
                "barrier_way",
                "feature_way",
                "feature_polygon",
                "playground_node",
                "playground_way",
                "playground_polygon",
                "railway_node",
                "railway_way",
            ],
            "strassenraumkarte:layer-strata-order": [
                qgis_filter for _, qgis_filter, _ in STRATA
            ],
            "strassenraumkarte:layer-strata-builder": (
                "python3 scripts/build_maplibre_strata.py"
            ),
        }
    )
    style_path.write_text(json.dumps(style, indent=2) + "\n")
    shown_path = style_path.resolve()
    if shown_path.is_relative_to(ROOT):
        shown_path = shown_path.relative_to(ROOT)
    print(
        f"wrote {shown_path}: {len(prototype_layers)} prototypes "
        f"x {len(STRATA)} QGIS strata = {len(expanded)} highway layers"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--style", type=Path, default=DEFAULT_STYLE)
    return parser.parse_args()


if __name__ == "__main__":
    build(parse_args().style)
