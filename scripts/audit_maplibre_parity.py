#!/usr/bin/env python3
"""Audit the MapLibre port against the QGIS project that defines the map.

This intentionally reads symbol-layer options only from their direct
``layer/Option`` child.  A descendant XPath also sees paint-effect colors and
was the cause of an earlier, visually plausible color corruption.

The default audit is strict for the Phase 1 layers represented in
``web/style.json`` and reports whole-project coverage.  Pass
``--require-full-coverage`` when the port is expected to be complete.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from typing import Any, Iterable

import layer_opacity
import qgis_scale
import thin_lines
import zoom_convention as zc


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_QGZ = ROOT / "style" / "strassenraumkarte.qgz"
DEFAULT_STYLE = ROOT / "web" / "style.json"
DEFAULT_MARTIN = ROOT / "render" / "mvt" / "martin-config.yaml"
TRANSPARENT = (0, 0, 0, 0.0)
SPECIAL_ROAD_STROKES = {
    "double_solid",
    "double_dashed",
    "double:solid",
    "dashed;solid",
    "solid;dashed",
    "barred_area;solid",
    "zebra",
    "ladder",
    "sharks_teeth",
}
NON_NATIVE_SYMBOL_CLASSES = {
    "CentroidFill",
    "GradientFill",
    "HashLine",
    "LinePatternFill",
    "MarkerLine",
    "PointPatternFill",
    "RasterFill",
    "ShapeburstFill",
}


def load_qgis_project(path: Path) -> ET.Element:
    with zipfile.ZipFile(path) as archive:
        qgs_names = [name for name in archive.namelist() if name.endswith(".qgs")]
        if len(qgs_names) != 1:
            raise ValueError(f"expected one .qgs in {path}, found {len(qgs_names)}")
        return ET.fromstring(archive.read(qgs_names[0]))


def direct_options(symbol_layer: ET.Element) -> dict[str, str]:
    """Return renderer options, excluding nested effect-stack options."""
    return {
        option.get("name", ""): option.get("value", "")
        for option in symbol_layer.findall("./Option/Option")
    }


def data_defined_expression(symbol_layer: ET.Element, name: str) -> str | None:
    """Read one active QGIS data-defined property from this exact layer.

    Restricting the lookup to the direct data_defined_properties child avoids
    accidentally reading a nested marker or effect property with the same
    name.
    """
    property_ = symbol_layer.find(
        "./data_defined_properties/Option/Option[@name='properties']"
        f"/Option[@name='{name}']"
    )
    if property_ is None:
        return None
    options = {
        option.get("name", ""): option.get("value", "")
        for option in property_.findall("./Option")
    }
    return options.get("expression") if options.get("active") == "true" else None


def table_name(map_layer: ET.Element) -> str | None:
    match = re.search(
        r'table="[^"]+"\."([^"]+)"', map_layer.findtext("datasource", "")
    )
    return match.group(1) if match else None


def find_map_layer(root: ET.Element, name: str, table: str) -> ET.Element:
    matches = [
        layer
        for layer in root.findall(".//projectlayers/maplayer")
        if layer.findtext("layername") == name and table_name(layer) == table
    ]
    if len(matches) != 1:
        raise ValueError(
            f"expected one QGIS layer {name!r} on {table!r}, found {len(matches)}"
        )
    return matches[0]


def find_unfiltered_map_layer(root: ET.Element, name: str, table: str) -> ET.Element:
    matches = [
        layer
        for layer in root.findall(".//projectlayers/maplayer")
        if layer.findtext("layername") == name
        and table_name(layer) == table
        and " sql=" not in layer.findtext("datasource", "")
    ]
    if len(matches) != 1:
        raise ValueError(
            f"expected one unfiltered QGIS layer {name!r} on {table!r}, "
            f"found {len(matches)}"
        )
    return matches[0]


def rgba(value: str) -> tuple[int, int, int, float]:
    parts = value.split(",")
    # QGIS 4 appends a colour-spec suffix, e.g. "202,202,202,255,rgb:0.79,0.79,0.79,1".
    if len(parts) > 4 and parts[4].startswith("rgb:"):
        parts = parts[:4]
    if len(parts) != 4:
        raise ValueError(f"not a QGIS RGBA color: {value!r}")
    red, green, blue, alpha = (int(part) for part in parts)
    return red, green, blue, alpha / 255


def css_color(value: Any) -> tuple[int, int, int, float] | None:
    if not isinstance(value, str):
        return None
    value = value.strip().lower()
    if re.fullmatch(r"#[0-9a-f]{6}", value):
        return int(value[1:3], 16), int(value[3:5], 16), int(value[5:7], 16), 1.0
    if re.fullmatch(r"#[0-9a-f]{8}", value):
        return (
            int(value[1:3], 16),
            int(value[3:5], 16),
            int(value[5:7], 16),
            int(value[7:9], 16) / 255,
        )
    match = re.fullmatch(
        r"rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([0-9.]+))?\s*\)",
        value,
    )
    if match:
        return (
            int(match.group(1)),
            int(match.group(2)),
            int(match.group(3)),
            float(match.group(4) or 1),
        )
    return None


def colors_equal(left: Any, right: tuple[int, int, int, float]) -> bool:
    parsed = css_color(left)
    return parsed is not None and parsed[:3] == right[:3] and math.isclose(
        parsed[3], right[3], abs_tol=1 / 255
    )


def decode_match(expression: Any) -> tuple[str | None, dict[str, Any], Any]:
    if not isinstance(expression, list) or len(expression) < 4 or expression[0] != "match":
        return None, {}, None
    getter = expression[1]
    if not isinstance(getter, list) or len(getter) != 2 or getter[0] != "get":
        return None, {}, expression[-1]
    result: dict[str, Any] = {}
    for labels, output in zip(expression[2:-1:2], expression[3:-1:2]):
        for label in labels if isinstance(labels, list) else [labels]:
            if isinstance(label, str):
                result[label] = output
    return getter[1], result, expression[-1]


def style_layer(style: dict[str, Any], layer_id: str) -> dict[str, Any]:
    matches = [layer for layer in style["layers"] if layer.get("id") == layer_id]
    if not matches:
        matches = [
            layer
            for layer in style["layers"]
            if layer.get("metadata", {}).get("strassenraumkarte:base-id") == layer_id
            and layer.get("metadata", {}).get("strassenraumkarte:stratum") == "ground"
        ]
    if len(matches) != 1:
        raise ValueError(f"expected one MapLibre layer {layer_id!r}, found {len(matches)}")
    return matches[0]


def base_layer_id(layer: dict[str, Any]) -> str:
    return layer.get("metadata", {}).get(
        "strassenraumkarte:base-id", layer.get("id", "")
    )


def first_solid_fill(symbol: ET.Element) -> tuple[int, int, int, float] | None:
    for symbol_layer in symbol.findall("./layer"):
        if symbol_layer.get("enabled") == "0" or symbol_layer.get("class") != "SimpleFill":
            continue
        options = direct_options(symbol_layer)
        if options.get("style") == "solid" and options.get("color"):
            return rgba(options["color"])
    return None


def categorized_solid_fills(
    map_layer: ET.Element,
) -> tuple[str, dict[str, tuple[int, int, int, float]], set[str]]:
    renderer = map_layer.find("renderer-v2")
    if renderer is None or renderer.get("type") != "categorizedSymbol":
        raise ValueError(f"{map_layer.findtext('layername')} is not categorizedSymbol")
    symbols = {
        symbol.get("name", ""): symbol
        for symbol in renderer.findall("./symbols/symbol")
    }
    fills: dict[str, tuple[int, int, int, float]] = {}
    disabled_or_non_solid: set[str] = set()
    for category in renderer.findall("./categories/category"):
        value = category.get("value", "")
        symbol = symbols.get(category.get("symbol", ""))
        color = first_solid_fill(symbol) if symbol is not None else None
        if category.get("render") == "true" and color is not None:
            fills[value] = color
        else:
            disabled_or_non_solid.add(value)
    return renderer.get("attr", ""), fills, disabled_or_non_solid


def rule_solid_fills(map_layer: ET.Element) -> dict[str, tuple[int, int, int, float]]:
    renderer = map_layer.find("renderer-v2")
    if renderer is None or renderer.get("type") != "RuleRenderer":
        raise ValueError(f"{map_layer.findtext('layername')} is not RuleRenderer")
    symbols = {
        symbol.get("name", ""): symbol
        for symbol in renderer.findall("./symbols/symbol")
    }
    result: dict[str, tuple[int, int, int, float]] = {}
    for rule in renderer.findall("./rules/rule"):
        symbol = symbols.get(rule.get("symbol", ""))
        color = first_solid_fill(symbol) if symbol is not None else None
        if color is None:
            continue
        match = re.search(r'"area:highway"\s+IN\s+\(([^)]+)\)', rule.get("filter", ""))
        if not match:
            continue
        for value in re.findall(r"'([^']+)'", match.group(1)):
            result[value] = color
    return result


def single_symbol_fill(map_layer: ET.Element) -> tuple[tuple[int, int, int, float], float]:
    renderer = map_layer.find("renderer-v2")
    symbol = renderer.find("./symbols/symbol") if renderer is not None else None
    if symbol is None:
        raise ValueError(f"no symbol on {map_layer.findtext('layername')}")
    color = first_solid_fill(symbol)
    if color is None:
        raise ValueError(f"no direct solid fill on {map_layer.findtext('layername')}")
    return color, float(symbol.get("alpha", "1"))


def rule_simple_lines(
    map_layer: ET.Element,
) -> dict[str, tuple[tuple[int, int, int, float], float, float]]:
    """Return first direct SimpleLine color, ground width, and symbol opacity by rule."""
    renderer = map_layer.find("renderer-v2")
    if renderer is None or renderer.get("type") != "RuleRenderer":
        raise ValueError(f"{map_layer.findtext('layername')} is not RuleRenderer")
    symbols = {
        symbol.get("name", ""): symbol
        for symbol in renderer.findall("./symbols/symbol")
    }
    result: dict[str, tuple[tuple[int, int, int, float], float, float]] = {}
    for rule in renderer.findall("./rules/rule"):
        symbol = symbols.get(rule.get("symbol", ""))
        if symbol is None:
            continue
        for symbol_layer in symbol.findall("./layer"):
            if symbol_layer.get("enabled") == "0" or symbol_layer.get("class") != "SimpleLine":
                continue
            options = direct_options(symbol_layer)
            if options.get("line_style") == "no" or not options.get("line_color"):
                continue
            result[rule.get("label", "")] = (
                rgba(options["line_color"]),
                float(options["line_width"]),
                float(symbol.get("alpha", "1")),
            )
            break
    return result


def rule_raster_fills(map_layer: ET.Element) -> dict[str, dict[str, Any]]:
    """Return direct options and active data-defined values for RasterFill rules."""
    renderer = map_layer.find("renderer-v2")
    if renderer is None or renderer.get("type") != "RuleRenderer":
        raise ValueError(f"{map_layer.findtext('layername')} is not RuleRenderer")
    symbols = {
        symbol.get("name", ""): symbol
        for symbol in renderer.findall("./symbols/symbol")
    }
    result: dict[str, dict[str, Any]] = {}
    for rule in renderer.findall("./rules/rule"):
        symbol = symbols.get(rule.get("symbol", ""))
        if symbol is None:
            continue
        raster_layers = [
            layer
            for layer in symbol.findall("./layer")
            if layer.get("enabled", "1") != "0" and layer.get("class") == "RasterFill"
        ]
        if not raster_layers:
            continue
        if len(raster_layers) != 1:
            raise ValueError(f"multiple RasterFill layers on {rule.get('label')}")
        raster_layer = raster_layers[0]
        data_defined: dict[str, dict[str, str]] = {}
        for option in raster_layer.findall(
            './/data_defined_properties//Option[@type="Map"]'
        ):
            name = option.get("name", "")
            if name in {"angle", "file", "width"}:
                data_defined[name] = {
                    child.get("name", ""): child.get("value", "")
                    for child in option.findall("./Option")
                }
        # QPainter composition mode of the effect stack's source draw (13 =
        # Multiply); 0 (normal) when the layer has no active effect stack.
        blend_mode = 0
        stack = raster_layer.find("./effect")
        if stack is not None and stack.get("enabled") == "1":
            for effect in stack.findall("./effect"):
                if effect.get("type") == "drawSource":
                    options = {o.get("name"): o.get("value") for o in effect.iter("Option")}
                    if options.get("enabled") == "1":
                        blend_mode = int(options.get("blend_mode", "0"))
        result[rule.get("label", "")] = {
            "options": direct_options(raster_layer),
            "data_defined": data_defined,
            "blend_mode": blend_mode,
        }
    return result


QT_MULTIPLY = 13


def texture_family(family: str, qgis_texture: dict[str, Any]) -> str:
    """Sprite family MapLibre must use: Multiply textures have a darken-only variant."""
    return f"{family}-multiply" if qgis_texture["blend_mode"] == QT_MULTIPLY else family


def categorized_raster_fill(
    map_layer: ET.Element, category_value: str
) -> dict[str, Any]:
    """Return the one active RasterFill attached to a categorized value."""
    renderer = map_layer.find("renderer-v2")
    if renderer is None or renderer.get("type") != "categorizedSymbol":
        raise ValueError(f"{map_layer.findtext('layername')} is not categorized")
    category = next(
        (
            item
            for item in renderer.findall("./categories/category")
            if item.get("value") == category_value and item.get("render") == "true"
        ),
        None,
    )
    if category is None:
        raise ValueError(f"missing rendered category {category_value!r}")
    symbol = next(
        (
            item
            for item in renderer.findall("./symbols/symbol")
            if item.get("name") == category.get("symbol")
        ),
        None,
    )
    if symbol is None:
        raise ValueError(f"missing symbol for category {category_value!r}")
    rasters = [
        layer
        for layer in symbol.findall("./layer")
        if layer.get("enabled", "1") != "0" and layer.get("class") == "RasterFill"
    ]
    if len(rasters) != 1:
        raise ValueError(
            f"expected one RasterFill for category {category_value!r}, got {len(rasters)}"
        )
    raster = rasters[0]
    return {
        "options": direct_options(raster),
        "file": data_defined_expression(raster, "file") or "",
        "width": data_defined_expression(raster, "width") or "",
        "angle": data_defined_expression(raster, "angle") or "",
    }


def qgis_label_style(
    map_layer: ET.Element, description: str | None = None
) -> tuple[tuple[int, int, int, float], float, tuple[int, int, int, float], float]:
    """Return static text color/size and buffer color/size for one QGIS label rule."""
    labeling = map_layer.find("labeling")
    if labeling is None:
        raise ValueError(f"no labeling on {map_layer.findtext('layername')}")
    if labeling.get("type") == "rule-based":
        rules = [
            rule
            for rule in labeling.findall("./rules/rule")
            if description is None or rule.get("description") == description
        ]
        if len(rules) != 1:
            raise ValueError(
                f"expected one label rule {description!r} on "
                f"{map_layer.findtext('layername')}, found {len(rules)}"
            )
        settings = rules[0].find("settings")
    else:
        settings = labeling.find("settings")
    text_style = settings.find("text-style") if settings is not None else None
    text_buffer = text_style.find("text-buffer") if text_style is not None else None
    if text_style is None or text_buffer is None:
        raise ValueError(f"incomplete label style on {map_layer.findtext('layername')}")
    if text_style.get("fontSizeUnit") != "Point":
        raise ValueError("label audit currently expects QGIS point-sized text")
    if text_buffer.get("bufferSizeUnits") != "Point":
        raise ValueError("label audit currently expects QGIS point-sized buffers")
    text_color = rgba(text_style.get("textColor", ""))
    buffer_color = rgba(text_buffer.get("bufferColor", ""))
    buffer_color = (
        *buffer_color[:3],
        buffer_color[3] * float(text_buffer.get("bufferOpacity", "1")),
    )
    points_to_css_pixels = 96 / 72
    return (
        text_color,
        float(text_style.get("fontSize", "0")) * points_to_css_pixels,
        buffer_color,
        float(text_buffer.get("bufferSize", "0")) * points_to_css_pixels,
    )


def qgis_label_data_defined(
    map_layer: ET.Element, description: str | None, property_name: str
) -> str | None:
    labeling = map_layer.find("labeling")
    if labeling is None:
        return None
    if labeling.get("type") == "rule-based":
        rules = [
            rule
            for rule in labeling.findall("./rules/rule")
            if rule.get("description") == description
        ]
        settings = rules[0].find("settings") if len(rules) == 1 else None
    else:
        settings = labeling.find("settings")
    if settings is None:
        return None
    candidates = settings.findall(f'.//Option[@name="{property_name}"]')
    if len(candidates) != 1:
        return None
    values = {
        option.get("name", ""): option.get("value", "")
        for option in candidates[0].findall("./Option")
    }
    return values.get("expression") if values.get("active") == "true" else None


def qgis_scale_opacity(expression: str) -> tuple[float, float, float]:
    """Translate `scale < N ? A : B` using the renderer's real scale (see qgis_scale)."""
    match = re.search(
        r"WHEN\s+@map_scale\s*<\s*([0-9.]+)\s+THEN\s+([0-9.]+)"
        r"\s+ELSE\s+([0-9.]+)",
        expression,
        re.DOTALL,
    )
    if not match:
        raise ValueError(f"unsupported QGIS scale opacity expression: {expression!r}")
    scale, above_threshold, below_threshold = map(float, match.groups())
    zoom_threshold = qgis_scale.zoom_at_scale(scale)
    return zoom_threshold, below_threshold / 100, above_threshold / 100


def qgis_label_zoom_range(
    map_layer: ET.Element, description: str
) -> tuple[float, float]:
    rules = [
        rule
        for rule in map_layer.findall("./labeling/rules/rule")
        if rule.get("description") == description
    ]
    if len(rules) != 1:
        raise ValueError(
            f"expected one QGIS label rule {description!r}, found {len(rules)}"
        )
    maximum_scale = float(rules[0].get("scalemaxdenom", "0"))
    minimum_scale = float(rules[0].get("scalemindenom", "0"))
    return (
        qgis_scale.zoom_at_scale(maximum_scale),
        qgis_scale.zoom_at_scale(minimum_scale),
    )


def evaluate_literal_expression(
    expression: Any, properties: dict[str, Any], zoom: float | None = None
) -> Any:
    """Evaluate the expression subset used by direct-value parity checks."""
    if not isinstance(expression, list):
        return expression
    operator = expression[0]
    if operator == "get":
        return properties.get(expression[1])
    if operator == "zoom":
        if zoom is None:
            raise ValueError("zoom expression evaluated without a zoom")
        return zoom
    if operator == "floor":
        return math.floor(float(evaluate_literal_expression(expression[1], properties, zoom)))
    if operator == "to-string":
        return str(evaluate_literal_expression(expression[1], properties, zoom))
    if operator == "image":
        return evaluate_literal_expression(expression[1], properties, zoom)
    if operator == "concat":
        return "".join(
            str(evaluate_literal_expression(value, properties, zoom))
            for value in expression[1:]
        )
    if operator == "match":
        value = evaluate_literal_expression(expression[1], properties, zoom)
        for labels, output in zip(expression[2:-1:2], expression[3:-1:2]):
            if value in labels if isinstance(labels, list) else value == labels:
                return evaluate_literal_expression(output, properties, zoom)
        return evaluate_literal_expression(expression[-1], properties, zoom)
    if operator == "step":
        value = float(evaluate_literal_expression(expression[1], properties, zoom))
        output = expression[2]
        for stop, candidate in zip(expression[3::2], expression[4::2]):
            if value < float(stop):
                break
            output = candidate
        return evaluate_literal_expression(output, properties, zoom)
    if operator == "*":
        return math.prod(
            float(evaluate_literal_expression(value, properties, zoom))
            for value in expression[1:]
        )
    if operator == "/":
        left = float(evaluate_literal_expression(expression[1], properties, zoom))
        right = float(evaluate_literal_expression(expression[2], properties, zoom))
        return left / right
    if operator == "coalesce":
        for value in expression[1:]:
            evaluated = evaluate_literal_expression(value, properties, zoom)
            if evaluated is not None:
                return evaluated
        return None
    raise ValueError(f"unsupported audit expression operator: {operator!r}")


def width_at_zoom_stop(expression: Any, zoom: int, properties: dict[str, Any]) -> float:
    if not (
        isinstance(expression, list)
        and len(expression) >= 7
        and expression[0] == "interpolate"
        and expression[2] == ["zoom"]
    ):
        raise ValueError(f"not a zoom interpolation: {expression!r}")
    for stop, output in zip(expression[3::2], expression[4::2]):
        if stop == zoom:
            return float(evaluate_literal_expression(output, properties))
    raise ValueError(f"zoom {zoom} is not an explicit interpolation stop")


def martin_properties(path: Path) -> dict[str, set[str]]:
    """Read the small, fixed indentation subset used by martin-config.yaml."""
    result: dict[str, set[str]] = {}
    current_table: str | None = None
    in_tables = False
    in_properties = False
    for raw_line in path.read_text().splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line:
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if indent == 2 and stripped == "tables:":
            in_tables = True
            continue
        if not in_tables:
            continue
        if indent == 4 and stripped.endswith(":"):
            current_table = stripped[:-1]
            result[current_table] = set()
            in_properties = False
        elif indent == 6 and stripped == "properties:":
            in_properties = True
        elif indent <= 6:
            in_properties = False
        elif indent == 8 and in_properties and current_table:
            property_match = re.fullmatch(r"(.+):\s+\S+", stripped)
            if property_match:
                result[current_table].add(property_match.group(1))
    return result


def martin_declared_types(path: Path) -> dict[str, tuple[str, dict[str, str]]]:
    """Per Martin source: (database table, declared property types)."""
    result: dict[str, tuple[str, dict[str, str]]] = {}
    current_table: str | None = None
    in_properties = False
    in_tables = False
    for raw_line in path.read_text().splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line:
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if indent == 2 and stripped == "tables:":
            in_tables = True
            continue
        if not in_tables:
            continue
        if indent == 4 and stripped.endswith(":"):
            current_table = stripped[:-1]
            result[current_table] = (current_table, {})
            in_properties = False
        elif indent == 6 and stripped.startswith("table:") and current_table:
            result[current_table] = (stripped.split(":", 1)[1].strip(), result[current_table][1])
        elif indent == 6 and stripped == "properties:":
            in_properties = True
        elif indent <= 6:
            in_properties = False
        elif indent == 8 and in_properties and current_table:
            match = re.fullmatch(r"(.+):\s+(\S+)", stripped)
            if match:
                result[current_table][1][match.group(1)] = match.group(2)
    return result


def check_martin_config_against_database(
    path: Path, errors: list[str], warnings: list[str]
) -> None:
    """Every declared tile property must exist in PostGIS with a tile-safe type.

    Martin refuses to start when a declared column is missing, and a PostgreSQL
    ``numeric`` column is encoded as a *string* in vector tiles, which silently
    breaks arithmetic and comparisons in style expressions (the pitch markings
    disappeared because dist_long was numeric).
    """
    declared = martin_declared_types(path)
    environment = os.environ
    command = [
        "psql", "--no-psqlrc", "-XAt", "-F", "|",
        "-h", environment.get("DB_HOST", "localhost"),
        "-p", environment.get("DB_PORT", "5433"),
        "-U", environment.get("DB_USER", "postgres"),
        "-d", environment.get("DB_NAME", "strassenraumkarte"),
        "-c",
        "SELECT table_name, column_name, data_type FROM information_schema.columns "
        "WHERE table_schema = 'public'",
    ]
    try:
        completed = subprocess.run(command, check=True, text=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as error:
        warnings.append(f"database schema check skipped (psql failed: {str(error)[:80]})")
        return
    columns: dict[tuple[str, str], str] = {}
    for line in completed.stdout.splitlines():
        table, column, data_type = line.split("|")
        columns[(table, column)] = data_type
    numeric_declared = ("int2", "int4", "int8", "float4", "float8")
    for source, (table, properties) in declared.items():
        for column, declared_type in properties.items():
            data_type = columns.get((table, column))
            if data_type is None:
                errors.append(f"martin: {source} ({table}).{column} is declared but missing in the database")
            elif data_type == "numeric":
                errors.append(
                    f"martin: {source} ({table}).{column} is numeric, which vector tiles encode as a "
                    f"string; cast it to real or double precision"
                )
            elif declared_type in numeric_declared and data_type in ("text", "character varying"):
                errors.append(f"martin: {source} ({table}).{column} is declared {declared_type} but is {data_type}")


# Enabled QGIS layers with an opacity below 1 that MapLibre handles by other
# means or has not ported yet (see layer_opacity.LAYER_OPACITY for the rest).
UNAPPLIED_LAYER_OPACITY = {
    "tree crown": "per-zoom icon-opacity tuned against QGIS (flattened layer vs per-icon)",
    "parking cars": "icon-opacity 0.67 set on the parking-cars layer",
    "water body (depth effect)": "ShapeburstFill depth gradient is not ported",
    "construction": "landuse construction hatch is not ported",
    "dog park": "landuse dog-park symbols are not ported",
    "roof shape": "unchecked in the project (and intentionally not ported)",
}


def check_layer_opacity_table(
    root: ET.Element, errors: list[str], warnings: list[str]
) -> None:
    """layer_opacity.LAYER_OPACITY must match the QGIS project's layer opacities."""
    layers_by_name: dict[str, list[float]] = {}
    for map_layer in root.iter("maplayer"):
        name = map_layer.findtext("layername") or ""
        layers_by_name.setdefault(name, []).append(
            float(map_layer.findtext("layerOpacity") or 1)
        )
    for _match, qgis_name, factor in layer_opacity.LAYER_OPACITY:
        opacities = layers_by_name.get(qgis_name)
        if not opacities:
            errors.append(f"layer_opacity: QGIS layer {qgis_name!r} not found")
        elif not all(math.isclose(value, factor, abs_tol=1e-6) for value in opacities):
            errors.append(
                f"layer_opacity: QGIS layer {qgis_name!r} has opacity {sorted(set(opacities))}, "
                f"table says {factor}"
            )
    handled = {qgis_name for _match, qgis_name, _factor in layer_opacity.LAYER_OPACITY}
    for map_layer in root.iter("maplayer"):
        name = map_layer.findtext("layername") or ""
        opacity = float(map_layer.findtext("layerOpacity") or 1)
        if opacity < 0.999 and name not in handled and name not in UNAPPLIED_LAYER_OPACITY:
            # The zNN highway-area effect layers are the blur/inner-shadow templates.
            if not (name.startswith("z") and name[1:].isdigit()):
                warnings.append(f"QGIS layer {name!r} has opacity {opacity} that the style does not apply")


def walk_gets(value: Any) -> Iterable[str]:
    if isinstance(value, list):
        if len(value) >= 2 and value[0] == "get" and isinstance(value[1], str):
            yield value[1]
        for child in value[1:]:
            yield from walk_gets(child)
    elif isinstance(value, dict):
        for child in value.values():
            yield from walk_gets(child)


def excludes_special_road_strokes(expression: Any) -> bool:
    """Detect the common filter that rejects separately rendered stroke types."""
    if not isinstance(expression, list):
        return False
    if (
        len(expression) >= 5
        and expression[0] == "match"
        and expression[1] == ["get", "stroke"]
        and isinstance(expression[2], list)
        and SPECIAL_ROAD_STROKES.issubset(expression[2])
        and expression[3] is False
        and expression[-1] is True
    ):
        return True
    return any(excludes_special_road_strokes(child) for child in expression[1:])


def contains_expression(expression: Any, expected: Any) -> bool:
    if expression == expected:
        return True
    return isinstance(expression, list) and any(
        contains_expression(child, expected) for child in expression[1:]
    )


def effectively_enabled_qgis_layers(root: ET.Element) -> list[ET.Element]:
    layers_by_id = {
        layer.findtext("id", ""): layer
        for layer in root.findall(".//projectlayers/maplayer")
    }
    enabled: list[ET.Element] = []

    def walk(group: ET.Element, parent_enabled: bool = True) -> None:
        group_enabled = parent_enabled and group.get("checked", "Qt::Checked") != "Qt::Unchecked"
        for child in group:
            if child.tag == "layer-tree-group":
                walk(child, group_enabled)
            elif (
                child.tag == "layer-tree-layer"
                and group_enabled
                and child.get("checked", "Qt::Checked") != "Qt::Unchecked"
            ):
                map_layer = layers_by_id.get(child.get("id", ""))
                if map_layer is not None:
                    enabled.append(map_layer)

    tree = root.find("layer-tree-group")
    if tree is not None:
        walk(tree)
    return enabled


def effectively_enabled_qgis_tables(root: ET.Element) -> set[str]:
    return {
        table
        for layer in effectively_enabled_qgis_layers(root)
        if (table := table_name(layer)) is not None
    }


def enabled_effect_types(map_layer: ET.Element) -> set[str]:
    result: set[str] = set()
    renderer = map_layer.find("renderer-v2")
    if renderer is None:
        return result
    for stack in renderer.findall(".//effect[@type='effectStack']"):
        if stack.get("enabled") not in {"1", "true"}:
            continue
        for effect in stack.findall(".//effect"):
            effect_type = effect.get("type", "")
            if effect_type in {"", "drawSource", "effectStack"}:
                continue
            if direct_options(effect).get("enabled") == "1":
                result.add(effect_type)
    return result


def symbol_layer_classes(map_layer: ET.Element) -> set[str]:
    return {
        symbol_layer.get("class", "")
        for symbol_layer in map_layer.findall(".//renderer-v2/symbols/symbol/layer")
        if symbol_layer.get("enabled", "1") != "0"
    }


# Mid-latitude of the reference extent (render log: @mercator_scale 1.641711).
REFERENCE_LATITUDE = math.degrees(math.acos(1 / 1.641711))


def maplibre_px_per_ground_metre(zoom: float) -> float:
    """True pixels per ground metre of a 512 px-world MapLibre map at ``zoom``."""
    equator_circumference_m = 40075016.686
    return 512 * 2**zoom / (
        equator_circumference_m * math.cos(math.radians(REFERENCE_LATITUDE))
    )


def check_ground_scale_convention(
    style: dict[str, Any], errors: list[str]
) -> None:
    """Verify the stored (MapLibre-convention) style sizes things physically.

    Every ``["*", C, ...]`` stop value inside a zoom interpolation encodes
    C pixels per ground metre at that stop's zoom; C must match the real
    geometry of a 512 px MapLibre world, not of a 256 px raster pyramid.
    """
    if zc.convention_of(style) != zc.MAPLIBRE:
        errors.append(
            f"style is in the {zc.convention_of(style)} zoom convention, "
            f"expected {zc.MAPLIBRE}"
        )
        return
    checked = 0
    bad: list[str] = []
    constants = (0.34385, 11.0032)  # px per ground metre at the raster z15 / z20 stops

    def literals(value: Any) -> Iterable[float]:
        if isinstance(value, list):
            for item in value:
                yield from literals(item)
        elif isinstance(value, (int, float)) and not isinstance(value, bool):
            yield value

    def walk(node: Any, layer_id: str) -> None:
        nonlocal checked
        if isinstance(node, dict):
            for value in node.values():
                walk(value, layer_id)
            return
        if not isinstance(node, list):
            return
        if node and node[0] == "interpolate" and len(node) >= 5 and node[2] == ["zoom"]:
            for index in range(3, len(node), 2):
                zoom, value = node[index], node[index + 1]
                expected = maplibre_px_per_ground_metre(zoom)
                for constant in literals(value):
                    if constant in constants:
                        checked += 1
                        if abs(constant - expected) / expected > 0.005:
                            bad.append(
                                f"{layer_id} z{zoom}: {constant} != {expected:.5f} px/m"
                            )
        for item in node:
            walk(item, layer_id)

    for layer in style["layers"]:
        for section in ("paint", "layout"):
            for prop, value in layer.get(section, {}).items():
                # line-opacity holds thin-line compensation expressions that
                # embed blended copies of the width stops; it is not a size.
                if prop != "line-opacity":
                    walk(value, layer["id"])
    if checked < 300:
        errors.append(f"ground-scale convention check found only {checked} stops")
    for message in bad[:8]:
        errors.append(f"ground-metre scale does not match 512 px MapLibre geometry: {message}")
    if len(bad) > 8:
        errors.append(f"... and {len(bad) - 8} more ground-metre scale mismatches")


def audit(args: argparse.Namespace) -> int:
    root = load_qgis_project(args.qgis_project)
    # All layer-level checks below reason in the QGIS (raster) zoom convention;
    # the physical-scale check runs on the style exactly as stored.
    stored_style = json.loads(args.style.read_text())
    style = zc.convert_style(stored_style, zc.RASTER)
    properties = martin_properties(args.martin_config)
    errors: list[str] = []
    check_ground_scale_convention(stored_style, errors)
    warnings: list[str] = []
    check_martin_config_against_database(args.martin_config, errors, warnings)
    check_layer_opacity_table(root, errors, warnings)
    verified_non_native: set[tuple[str, str, str]] = set()
    verified_scale_bands: set[tuple[str, str]] = set()

    if any(source.get("type") != "vector" for source in style["sources"].values()):
        errors.append("web style contains a non-vector source")

    for layer in style["layers"]:
        source_name = layer.get("source")
        if not source_name:
            continue
        declared = properties.get(source_name)
        if declared is None:
            errors.append(f"{layer['id']}: source {source_name!r} is absent from Martin config")
            continue
        for property_name in sorted(set(walk_gets(layer))):
            if property_name not in declared:
                errors.append(
                    f"{layer['id']}: property {property_name!r} is not exposed by source "
                    f"{source_name!r}"
                )

    generic_road_layers = [
        layer
        for layer in style["layers"]
        if base_layer_id(layer) == "road-marking-way-solid"
        or base_layer_id(layer).startswith("road-marking-way-dash-")
    ]
    for layer in generic_road_layers:
        if not excludes_special_road_strokes(layer.get("filter")):
            errors.append(
                f"{layer['id']}: generic road-marking layer must exclude double "
                "strokes and sharks_teeth"
            )

    # QGIS MarkerLine -> literal polygon geometry. Keep this separate from the
    # direct-color checks: MarkerLine's interval, angle averaging, nested
    # SimpleMarker transform, and data-defined values are all visually silent
    # failure modes if only the final fill colour is inspected.
    markerline_checkpoint = len(errors)
    qgis_road_markings = find_unfiltered_map_layer(
        root, "road_marking_way", "road_marking_way"
    )
    marker_lines = qgis_road_markings.findall(
        ".//renderer-v2/symbols/symbol/layer[@class='MarkerLine']"
    )
    marker_line = marker_lines[0] if len(marker_lines) == 1 else None
    if marker_line is None:
        errors.append(
            f"QGIS road_marking_way must have exactly one MarkerLine, found {len(marker_lines)}"
        )
    else:
        marker_options = direct_options(marker_line)
        expected_marker_options = {
            "average_angle_length": "4",
            "average_angle_unit": "MapUnit",
            "place_on_every_part": "true",
            "placements": "Interval",
            "rotate": "1",
        }
        for option, expected in expected_marker_options.items():
            if marker_options.get(option) != expected:
                errors.append(
                    f"QGIS sharks-teeth MarkerLine {option} changed from {expected!r} "
                    f"to {marker_options.get(option)!r}"
                )
        interval_expression = data_defined_expression(marker_line, "interval") or ""
        offset_expression = (
            data_defined_expression(marker_line, "offsetAlongLine") or ""
        )
        if not all(
            token in interval_expression
            for token in ("@mercator_scale", "array_sum", '"dasharray"')
        ):
            errors.append("QGIS sharks-teeth interval expression changed")
        if not all(
            token in offset_expression
            for token in ("@mercator_scale", "array_get", '"dasharray"', ", 1)")
        ):
            errors.append("QGIS sharks-teeth along-line offset expression changed")

        simple_marker = marker_line.find("./symbol/layer[@class='SimpleMarker']")
        if simple_marker is None:
            errors.append("QGIS sharks-teeth MarkerLine lost its SimpleMarker")
        else:
            simple_options = direct_options(simple_marker)
            for option, expected in {
                "angle": "180",
                "name": "triangle",
                "outline_style": "no",
            }.items():
                if simple_options.get(option) != expected:
                    errors.append(
                        f"QGIS sharks-teeth SimpleMarker {option} changed from "
                        f"{expected!r} to {simple_options.get(option)!r}"
                    )
            size_expression = data_defined_expression(simple_marker, "size") or ""
            marker_offset_expression = (
                data_defined_expression(simple_marker, "offset") or ""
            )
            fill_expression = (
                data_defined_expression(simple_marker, "fillColor") or ""
            )
            if not all(
                token in size_expression
                for token in ("@mercator_scale", "array_get", '"dasharray"', ", 0)")
            ):
                errors.append("QGIS sharks-teeth size expression changed")
            if not all(
                token in marker_offset_expression
                for token in ("-0.25", "@mercator_scale", "array_get", ", 0)")
            ):
                errors.append("QGIS sharks-teeth rotated marker-offset expression changed")
            if '"colour"' not in fill_expression or "'white'" not in fill_expression:
                errors.append("QGIS sharks-teeth fill-colour expression changed")

    sharks_sql = (
        ROOT / "data/processing/sql/web/web_road_marking_symbols.sql"
    ).read_text()
    for required_sql in (
        "4.0::double precision AS average_angle_map_units",
        "distance_along - 2.0",
        "distance_along + 2.0",
        "marker_size * 0.25",
        "marker_size / 2.0",
        "sum(value)",
    ):
        if required_sql not in sharks_sql:
            errors.append(
                f"sharks-teeth SQL lost QGIS transform term {required_sql!r}"
            )
    sharks_style_layers = [
        layer
        for layer in style["layers"]
        if layer.get("source-layer") == "road_marking_sharks_teeth"
    ]
    if len(sharks_style_layers) != 6 or any(
        layer.get("type") != "fill" for layer in sharks_style_layers
    ):
        errors.append(
            "derived sharks-teeth polygons must have one fill in every QGIS stratum"
        )
    if len(errors) == markerline_checkpoint:
        verified_non_native.add(("road_marking_way", "road_marking_way", "MarkerLine"))

    qgis_road_marking_nodes = find_unfiltered_map_layer(
        root, "road_marking_node", "road_marking_node"
    )
    arrow_rule = next(
        (
            rule
            for rule in qgis_road_marking_nodes.findall("./renderer-v2/rules/rule")
            if rule.get("label") == "arrow"
        ),
        None,
    )
    arrow_marker = (
        qgis_road_marking_nodes.find(
            f"./renderer-v2/symbols/symbol[@name='{arrow_rule.get('symbol')}']"
            "/layer[@class='SvgMarker']"
        )
        if arrow_rule is not None
        else None
    )
    if arrow_marker is None:
        errors.append("QGIS road-marking arrows must retain their SvgMarker")
    else:
        arrow_name = data_defined_expression(arrow_marker, "name") or ""
        arrow_height = data_defined_expression(arrow_marker, "height") or ""
        arrow_width = data_defined_expression(arrow_marker, "width") or ""
        if 'symbols/traffic_signs/arrows/' not in arrow_name or '"arrow"' not in arrow_name:
            errors.append("QGIS road-arrow SVG-name expression changed")
        if "@mercator_scale" not in arrow_height or '"length"' not in arrow_height:
            errors.append("QGIS road-arrow height expression changed")
        if not all(
            token in arrow_width for token in ("@mercator_scale", "0.3", "max", "min")
        ):
            errors.append("QGIS road-arrow width expression changed")

    arrow_style_layers = [
        layer
        for layer in style["layers"]
        if layer.get("source-layer") == "road_marking_node"
    ]
    if len(arrow_style_layers) != 6 or any(
        layer.get("type") != "symbol" for layer in arrow_style_layers
    ):
        errors.append("road arrows must have one symbol layer in every QGIS stratum")
    for layer in arrow_style_layers:
        if layer.get("layout", {}).get("icon-image") != ["get", "symbol_name"]:
            errors.append(f"{layer['id']}: road arrows must use their derived sprite id")
        if layer.get("layout", {}).get("icon-rotate") != [
            "coalesce",
            ["get", "icon_rotation"],
            0,
        ]:
            errors.append(f"{layer['id']}: road arrows must retain QGIS rotation")
    arrow_sprite_names = {
        f"road-arrow-{name.replace(';', '-')}-l{length}"
        for name in (
            "left", "left;right", "left;through", "merge_to_left",
            "merge_to_right", "right", "slight_left", "slight_right",
            "through", "through;right",
        )
        for length in (2, 5)
    }
    sprite_names = set(json.loads((ROOT / "web" / "sprite.json").read_text()))
    missing_arrow_sprites = sorted(arrow_sprite_names - sprite_names)
    if missing_arrow_sprites:
        errors.append("road-arrow sprites missing: " + ", ".join(missing_arrow_sprites))
    arrow_sql = (ROOT / "data/processing/sql/web/web_symbol_names.sql").read_text()
    for required_sql in (
        "road_marking = 'arrow'",
        "replace(arrow, ';', '-')",
        "length IN (2, 5)",
        "COALESCE(direction, 0)",
    ):
        if required_sql not in arrow_sql:
            errors.append(f"road-arrow SQL lost QGIS mapping term {required_sql!r}")

    tactile_checkpoint = len(errors)
    qgis_tactile = find_unfiltered_map_layer(root, "tactile_paving", "tactile_paving")
    tactile_marker_lines = qgis_tactile.findall(
        ".//renderer-v2/symbols/symbol/layer[@class='MarkerLine']"
    )
    if len(tactile_marker_lines) != 1:
        errors.append(
            "QGIS tactile_paving must have exactly one MarkerLine, found "
            f"{len(tactile_marker_lines)}"
        )
    else:
        tactile_marker = tactile_marker_lines[0]
        tactile_options = direct_options(tactile_marker)
        for option, expected in {
            "interval": "1",
            "offset": "-0.5",
            "offset_along_line": "0.5",
            "interval_unit": "MapUnit",
            "offset_unit": "MapUnit",
            "offset_along_line_unit": "MapUnit",
            "place_on_every_part": "true",
            "placements": "Interval",
            "rotate": "1",
        }.items():
            if tactile_options.get(option) != expected:
                errors.append(
                    f"QGIS tactile-paving MarkerLine {option} changed from "
                    f"{expected!r} to {tactile_options.get(option)!r}"
                )
        tactile_simple = tactile_marker.find("./symbol/layer[@class='SimpleMarker']")
        if tactile_simple is None:
            errors.append("QGIS tactile-paving MarkerLine lost its SimpleMarker")
        else:
            tactile_simple_options = direct_options(tactile_simple)
            for option, expected in {
                "name": "cross2",
                "color": "255,0,0,255",
                "outline_color": "234,232,227,255",
                "outline_width": "0.12",
                "size": "1",
            }.items():
                if tactile_simple_options.get(option) != expected:
                    errors.append(
                        f"QGIS tactile-paving SimpleMarker {option} changed from "
                        f"{expected!r} to {tactile_simple_options.get(option)!r}"
                    )

    tactile_sql = (ROOT / "data/processing/sql/web/web_tactile_paving.sql").read_text()
    for required_sql in (
        "0.5 + marker_index",
        "tangent_y * 0.5",
        "tangent_x * 0.5",
        "distance_along - 2.0",
        "distance_along + 2.0",
        "0.06, 'endcap=flat join=mitre'",
    ):
        if required_sql not in tactile_sql:
            errors.append(
                f"tactile-paving SQL lost QGIS transform term {required_sql!r}"
            )
    tactile_style_layers = [
        layer for layer in style["layers"] if layer.get("source-layer") == "tactile_paving"
    ]
    tactile_fills = [layer for layer in tactile_style_layers if layer.get("type") == "fill"]
    tactile_outlines = [layer for layer in tactile_style_layers if layer.get("type") == "line"]
    if len(tactile_fills) != 6 or any(
        layer.get("paint", {}).get("fill-color") != "#ff0000"
        for layer in tactile_fills
    ):
        errors.append("tactile paving must have one red fill in every QGIS stratum")
    if len(tactile_outlines) != 6 or any(
        layer.get("paint", {}).get("line-color") != "#eae8e3"
        for layer in tactile_outlines
    ):
        errors.append(
            "tactile paving must have one off-white outline in every QGIS stratum"
        )
    if len(errors) == tactile_checkpoint:
        verified_non_native.add(("tactile_paving", "tactile_paving", "MarkerLine"))

    separation_checkpoint = len(errors)
    qgis_separation = find_unfiltered_map_layer(root, "separation", "separation")
    separation_rules = {
        rule.get("label")
        for rule in qgis_separation.findall("./renderer-v2/rules/rule")
    }
    expected_separation_rules = {"bollard", "flex_post", "bump", "vertical_panel"}
    if separation_rules != expected_separation_rules:
        errors.append(
            "QGIS separation rules changed: "
            f"{sorted(separation_rules)} != {sorted(expected_separation_rules)}"
        )
    separation_sql = (
        ROOT / "data/processing/sql/web/web_separation_markers.sql"
    ).read_text()
    for required_sql in (
        "('bollard'::text), ('flex_post'), ('bump'), ('vertical_panel')",
        "1.0 + marker_index * 2.0",
        "distance_along - 2.0",
        "distance_along + 2.0",
        "WHEN 'bump' THEN ST_MakePolygon",
    ):
        if required_sql not in separation_sql:
            errors.append(
                f"separation SQL lost QGIS transform term {required_sql!r}"
            )
    separation_style_layers = [
        layer for layer in style["layers"] if layer.get("source-layer") == "separation"
    ]
    separation_fills = [
        layer for layer in separation_style_layers if layer.get("type") == "fill"
    ]
    separation_outlines = [
        layer for layer in separation_style_layers if layer.get("type") == "line"
    ]
    if len(separation_fills) != 6 or any(
        layer.get("paint", {}).get("fill-color") != ["get", "colour"]
        for layer in separation_fills
    ):
        errors.append("separation markers must have one data-colored fill per stratum")
    if len(separation_outlines) != 6 or any(
        layer.get("paint", {}).get("line-color") != ["get", "outline_colour"]
        for layer in separation_outlines
    ):
        errors.append("separation markers must have one outlined fill per stratum")
    if len(errors) == separation_checkpoint:
        verified_non_native.add(("separation", "separation", "MarkerLine"))
        verified_non_native.add(("separation", "separation", "HashLine"))

    qgis_barriers = find_unfiltered_map_layer(root, "barrier_node", "barrier_node")
    qgis_barrier_categories = {
        category.get("value")
        for category in qgis_barriers.findall("./renderer-v2/categories/category")
    }
    barrier_style_layers = [
        layer
        for layer in style["layers"]
        if layer.get("source-layer") == "barrier_node"
    ]
    if len(barrier_style_layers) != 6 or any(
        layer.get("type") != "circle" for layer in barrier_style_layers
    ):
        errors.append("barrier nodes must have one ground-sized marker per stratum")
    else:
        marker_filter = barrier_style_layers[0].get("filter", [])
        if marker_filter and marker_filter[0] == "all":
            marker_filter = marker_filter[-1]
        filter_categories = set(marker_filter[2] if len(marker_filter) > 2 else [])
        if filter_categories != qgis_barrier_categories:
            errors.append(
                "barrier marker categories drifted from QGIS: "
                f"{sorted(filter_categories)} != {sorted(qgis_barrier_categories)}"
            )

    barrier_marker_audit = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "audit_barrier_way_markers.py")],
        text=True,
        capture_output=True,
    )
    if barrier_marker_audit.returncode:
        errors.append(
            "barrier MarkerLine audit failed: "
            + (barrier_marker_audit.stdout + barrier_marker_audit.stderr).strip()
        )
    else:
        verified_non_native.add(("barrier_way", "barrier_way", "MarkerLine"))

    landscape_tick_audit = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "audit_landscape_ticks.py")],
        text=True,
        capture_output=True,
    )
    if landscape_tick_audit.returncode:
        errors.append(
            "landscape MarkerLine audit failed: "
            + (landscape_tick_audit.stdout + landscape_tick_audit.stderr).strip()
        )
    else:
        verified_non_native.add(("landscape_way", "landscape_way", "MarkerLine"))

    hash_audit = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "audit_hash_geometries.py")],
        text=True,
        capture_output=True,
    )
    if hash_audit.returncode:
        errors.append(
            "derived HashLine audit failed: "
            + (hash_audit.stdout + hash_audit.stderr).strip()
        )
    else:
        verified_non_native.add(("highway", "path (way, fill)", "HashLine"))
        verified_non_native.add(("railway_way", "railway tie", "HashLine"))

    # Closed barriers use QGIS's categorized SimpleFill renderer.  Keep its
    # deliberately unstyled unmatched values unpainted: adding a generic fill
    # here would make unsupported barrier values look plausibly intentional.
    qgis_barrier_polygons = find_unfiltered_map_layer(
        root, "barrier_polygon", "barrier_polygon"
    )
    qgis_polygon_categories = {
        category.get("value"): category.get("symbol")
        for category in qgis_barrier_polygons.findall(
            "./renderer-v2/categories/category"
        )
    }
    expected_polygon_categories = {
        "fence;hedge": "0",
        "hedge;fence": "1",
        "hedge": "2",
        "planter": "3",
        "wall": "4",
        "": "5",
    }
    if qgis_polygon_categories != expected_polygon_categories:
        errors.append(
            "QGIS barrier-polygon categories or symbol assignment changed: "
            f"{qgis_polygon_categories!r}"
        )
    barrier_polygon_layers = [
        layer
        for layer in style["layers"]
        if layer.get("source-layer") == "barrier_polygon"
    ]
    expected_polygon_layers = {
        "barrier-polygon-hedge-fill": ("fill", "#c7d6b8"),
        "barrier-polygon-planter-fill": ("fill", "#c7d6b8"),
        "barrier-polygon-planter-outline": ("line", "#505050"),
        "barrier-polygon-wall-fill": ("fill", "#c0c0c0"),
        "barrier-polygon-wall-outline": ("line", "#505050"),
        "barrier-polygon-empty-outline": ("line", "#505050"),
    }
    for base_id, (layer_type, colour) in expected_polygon_layers.items():
        matched = [
            layer
            for layer in barrier_polygon_layers
            if layer.get("metadata", {}).get("strassenraumkarte:base-id") == base_id
        ]
        if len(matched) != 6 or any(
            layer.get("type") != layer_type for layer in matched
        ):
            errors.append(
                f"{base_id}: expected one {layer_type} in every QGIS stratum"
            )
            continue
        paint_key = "fill-color" if layer_type == "fill" else "line-color"
        if any(layer.get("paint", {}).get(paint_key) != colour for layer in matched):
            errors.append(f"{base_id}: color drifted from its QGIS SimpleFill")
    if len(barrier_polygon_layers) != 36:
        errors.append(
            "barrier polygons must have six categorized layers in every QGIS stratum"
        )

    landuse = find_map_layer(root, "landuse", "landuse")
    qgis_attr, qgis_landuse, unsupported_landuse = categorized_solid_fills(landuse)
    landuse_expression = style_layer(style, "landuse-fill")["paint"]["fill-color"]
    maplibre_attr, maplibre_landuse, landuse_fallback = decode_match(landuse_expression)
    if maplibre_attr != qgis_attr:
        errors.append(
            f"landuse-fill reads {maplibre_attr!r}; QGIS categorized renderer reads {qgis_attr!r}"
        )
    for category, expected in qgis_landuse.items():
        actual = maplibre_landuse.get(category)
        if not colors_equal(actual, expected):
            errors.append(
                f"landuse {category!r}: MapLibre {actual!r} != QGIS rgba{expected}"
            )
    for category in unsupported_landuse:
        actual = maplibre_landuse.get(category, "rgba(0,0,0,0)")
        if css_color(actual) != TRANSPARENT:
            errors.append(
                f"landuse {category!r} is disabled/non-solid in QGIS but has MapLibre fill {actual!r}"
            )
    if css_color(landuse_fallback) != TRANSPARENT:
        errors.append(
            f"landuse fallback must be transparent (QGIS has no default category), got {landuse_fallback!r}"
        )

    qgis_highway = rule_solid_fills(
        find_unfiltered_map_layer(root, "highway_area", "highway_area")
    )
    highway_expression = style_layer(style, "highway-area-fill")["paint"]["fill-color"]
    highway_attr, maplibre_highway, highway_fallback = decode_match(highway_expression)
    if highway_attr != "area:highway":
        errors.append(f"highway-area-fill reads {highway_attr!r}, expected 'area:highway'")
    for category, expected in qgis_highway.items():
        actual = maplibre_highway.get(category)
        if not colors_equal(actual, expected):
            errors.append(
                f"highway_area {category!r}: MapLibre {actual!r} != QGIS rgba{expected}"
            )
    if css_color(highway_fallback) != TRANSPARENT:
        errors.append(
            "highway-area fallback must be transparent (QGIS has no ELSE fill), "
            f"got {highway_fallback!r}"
        )

    qgis_surface_textures = rule_raster_fills(
        find_unfiltered_map_layer(root, "highway_area", "highway_area")
    )
    expected_texture_rules = {
        "concrete:plates": (
            "highway-area-surface-concrete",
            "surface-concrete",
            3.0,
            "texture_rotation_bucket",
        ),
        "concrete": (
            "highway-area-surface-concrete",
            "surface-concrete",
            3.0,
            "texture_rotation_bucket",
        ),
        "paving_stones": (
            "highway-area-surface-paving-stones",
            "surface-paving-stones",
            4.5,
            "texture_paving_rotation_bucket",
        ),
        "asphalt": (
            "highway-area-surface-asphalt",
            "surface-asphalt",
            6.0,
            None,
        ),
    }
    expected_texture_files = {
        "concrete:plates": "concrete.png",
        "concrete": "concrete.png",
        "paving_stones": "paving_stones.png",
        "asphalt": "asphalt.png",
    }
    sprite_1x = json.loads((ROOT / "web" / "sprite.json").read_text())
    sprite_2x = json.loads((ROOT / "web" / "sprite@2x.json").read_text())
    if set(sprite_1x) != set(sprite_2x):
        errors.append("1x and 2x sprite manifests expose different image IDs")

    checked_texture_layers: set[str] = set()
    for rule_name, (
        maplibre_id,
        sprite_family,
        ground_width,
        bucket_property,
    ) in expected_texture_rules.items():
        qgis_texture = qgis_surface_textures.get(rule_name)
        if qgis_texture is None:
            errors.append(f"QGIS highway_area RasterFill rule {rule_name!r} is missing")
            continue
        qgis_options = qgis_texture["options"]
        qgis_data_defined = qgis_texture["data_defined"]
        # asphalt is not grey, so it keeps its plain texture (see build_maplibre_sprite.py)
        if rule_name != "asphalt":
            sprite_family = texture_family(sprite_family, qgis_texture)
        if not math.isclose(float(qgis_options["width"]), ground_width):
            errors.append(
                f"QGIS {rule_name} default RasterFill width changed from "
                f"{ground_width} m"
            )
        file_expression = qgis_data_defined.get("file", {}).get("expression", "")
        if expected_texture_files[rule_name] not in file_expression:
            errors.append(
                f"QGIS {rule_name} RasterFill no longer reads "
                f"{expected_texture_files[rule_name]}"
            )
        width_expression = qgis_data_defined.get("width", {}).get("expression", "")
        if "@mercator_scale" not in width_expression:
            errors.append(f"QGIS {rule_name} RasterFill width lost ground-unit scaling")
        angle_options = qgis_data_defined.get("angle", {})
        if rule_name in {"concrete", "concrete:plates"}:
            if angle_options.get("field") != "direction":
                errors.append(f"QGIS {rule_name} texture no longer reads direction")
        elif rule_name == "paving_stones":
            if angle_options.get("expression") != '"direction" + 45':
                errors.append("QGIS paving_stones texture is no longer direction + 45")
        elif angle_options.get("active") != "false":
            errors.append("QGIS asphalt texture unexpectedly has active rotation")
        layer = style_layer(style, maplibre_id)
        expected_opacity = float(qgis_texture["options"]["alpha"])
        actual_opacity = float(layer["paint"].get("fill-opacity", 1))
        if not math.isclose(actual_opacity, expected_opacity):
            errors.append(
                f"{maplibre_id}: texture opacity {actual_opacity} "
                f"!= QGIS {expected_opacity}"
            )
        checked_texture_layers.add(maplibre_id)
        for zoom in range(14, 21):
            properties_for_pattern = (
                {bucket_property: "r000"} if bucket_property else {}
            )
            actual_name = evaluate_literal_expression(
                layer["paint"]["fill-pattern"], properties_for_pattern, zoom
            )
            expected_name = f"{sprite_family}-z{zoom}"
            if bucket_property:
                expected_name += "-r000"
            if actual_name != expected_name:
                errors.append(
                    f"{maplibre_id} at z{zoom}: pattern {actual_name!r} "
                    f"!= {expected_name!r}"
                )
                continue
            for manifest, pixel_ratio in ((sprite_1x, 1), (sprite_2x, 2)):
                entry = manifest.get(expected_name)
                if entry is None:
                    errors.append(f"sprite is missing {expected_name!r} at {pixel_ratio}x")
                    continue
                expected_pixels = max(
                    1,
                    round(
                        ground_width
                        * 0.34385
                        * 2 ** (zoom - 15)
                        * pixel_ratio
                    ),
                )
                if entry.get("width") != expected_pixels:
                    errors.append(
                        f"{expected_name} at {pixel_ratio}x: width "
                        f"{entry.get('width')} != QGIS ground scale {expected_pixels}px"
                    )
                if entry.get("pixelRatio") != pixel_ratio:
                    errors.append(
                        f"{expected_name}: pixelRatio {entry.get('pixelRatio')} "
                        f"!= {pixel_ratio}"
                    )
        if bucket_property:
            for zoom in range(14, 21):
                for angle in range(0, 360, 15):
                    expected_name = f"{sprite_family}-z{zoom}-r{angle:03d}"
                    if expected_name not in sprite_1x or expected_name not in sprite_2x:
                        errors.append(f"sprite is missing rotated texture {expected_name!r}")

    sett_texture = qgis_surface_textures.get("sett")
    if sett_texture is None:
        errors.append("QGIS highway_area RasterFill rule 'sett' is missing")
    else:
        sett_data_defined = sett_texture["data_defined"]
        sett_file_expression = sett_data_defined.get("file", {}).get("expression", "")
        sett_width_expression = sett_data_defined.get("width", {}).get("expression", "")
        sett_angle_expression = sett_data_defined.get("angle", {}).get("expression", "")
        if "sett.png" not in sett_file_expression:
            errors.append("QGIS sett RasterFill no longer reads sett.png")
        for expected_fragment in (
            "@mercator_scale",
            '"sett:length"=\'5 cm\' THEN 6',
            '"sett:length"=\'10 cm\' THEN 8.5',
            "ELSE 11",
        ):
            if expected_fragment not in sett_width_expression:
                errors.append(
                    f"QGIS sett width expression lost {expected_fragment!r}"
                )
        if sett_angle_expression != '"direction"':
            errors.append("QGIS sett texture no longer reads direction")
        expected_sett_opacity = float(sett_texture["options"]["alpha"])
        for maplibre_id, sprite_family, width in (
            ("highway-area-surface-sett-5cm", "surface-sett-6", 6.0),
            ("highway-area-surface-sett-10cm", "surface-sett-8_5", 8.5),
            ("highway-area-surface-sett-default", "surface-sett-11", 11.0),
        ):
            sprite_family = texture_family(sprite_family, sett_texture)
            layer = style_layer(style, maplibre_id)
            if not math.isclose(
                float(layer["paint"].get("fill-opacity", 1)), expected_sett_opacity
            ):
                errors.append(
                    f"{maplibre_id}: texture opacity does not match "
                    f"QGIS {expected_sett_opacity}"
                )
            for zoom in range(14, 21):
                actual_name = evaluate_literal_expression(
                    layer["paint"]["fill-pattern"],
                    {"texture_rotation_bucket": "r000"},
                    zoom,
                )
                expected_name = f"{sprite_family}-z{zoom}-r000"
                if actual_name != expected_name:
                    errors.append(
                        f"{maplibre_id} at z{zoom}: pattern {actual_name!r} "
                        f"!= {expected_name!r}"
                    )
                for manifest, pixel_ratio in ((sprite_1x, 1), (sprite_2x, 2)):
                    entry = manifest.get(expected_name)
                    expected_pixels = max(
                        1,
                        round(width * 0.34385 * 2 ** (zoom - 15) * pixel_ratio),
                    )
                    if entry is None or entry.get("width") != expected_pixels:
                        errors.append(
                            f"{expected_name} at {pixel_ratio}x does not have "
                            f"QGIS-scaled width {expected_pixels}px"
                        )
                for angle in range(0, 360, 15):
                    rotated_name = f"{sprite_family}-z{zoom}-r{angle:03d}"
                    if rotated_name not in sprite_1x or rotated_name not in sprite_2x:
                        errors.append(f"sprite is missing rotated texture {rotated_name!r}")

    # These exact source files, QGIS opacities, ground-unit sizes, seven zoom
    # bands, and all 15-degree buckets are now executable audit coverage.
    verified_non_native.add(("highway_area", "highway_area", "RasterFill"))
    verified_scale_bands.update(
        ("highway_area", f"z{zoom}") for zoom in range(14, 21)
    )

    # The pitch and sandpit patterns use the exact QGIS texture files.  Pixel
    # textures remain native-pixel sprites; map-unit textures reuse the
    # ground-scaled, zoom-banded families above.
    pitch_qgis = next(
        layer
        for layer in root.findall(".//projectlayers/maplayer")
        if table_name(layer) == "pitch" and layer.findtext("layername") == "pitch surface"
    )
    pitch_patterns = {
        "artificial_turf": ("pitch-surface-asphalt-pattern", "asphalt.png", 0.06),
        "grass": ("pitch-surface-grass-pattern", "grass.png", 0.06),
        "clay": ("pitch-surface-sand-pattern", "sand.png", 0.08),
        "compacted": ("pitch-surface-sand-pattern", "sand.png", 0.08),
        "dirt": ("pitch-surface-sand-pattern", "sand.png", 0.08),
        "earth": ("pitch-surface-sand-pattern", "sand.png", 0.08),
        "fine_gravel": ("pitch-surface-sand-pattern", "sand.png", 0.08),
        "gravel": ("pitch-surface-sand-pattern", "sand.png", 0.08),
        "ground": ("pitch-surface-sand-pattern", "sand.png", 0.08),
        "sand": ("pitch-surface-sand-pattern", "sand.png", 0.08),
        "asphalt": ("pitch-surface-asphalt-pattern", "asphalt.png", 0.06),
        "rubber": ("pitch-surface-asphalt-pattern", "asphalt.png", 0.06),
        "rubbercrumb": ("pitch-surface-asphalt-pattern", "asphalt.png", 0.06),
        "tartan": ("pitch-surface-asphalt-pattern", "asphalt.png", 0.06),
        "concrete": ("pitch-surface-concrete-pattern", "concrete.png", 0.15),
        "concrete:plates": ("pitch-surface-concrete-pattern", "concrete.png", 0.15),
        "paving_stones": ("pitch-surface-paving-pattern", "paving_stones.png", 0.07),
        "sett": ("pitch-surface-sett-pattern", "sett.png", 0.12),
        "woodchips": ("pitch-surface-woodchips-pattern", "woodchips.png", 0.10),
    }
    for surface, (maplibre_id, filename, opacity) in pitch_patterns.items():
        qgis_raster = categorized_raster_fill(pitch_qgis, surface)
        if filename not in qgis_raster["file"]:
            errors.append(f"QGIS pitch {surface} RasterFill no longer reads {filename}")
        if not math.isclose(float(qgis_raster["options"]["alpha"]), opacity):
            errors.append(f"QGIS pitch {surface} RasterFill opacity changed")
        layer = style_layer(style, maplibre_id)
        if surface not in json.dumps(layer.get("filter", True)):
            errors.append(f"{maplibre_id}: no longer selects pitch surface {surface}")
        if not math.isclose(float(layer["paint"].get("fill-opacity", 1)), opacity):
            errors.append(f"{maplibre_id}: opacity does not match QGIS pitch {surface}")
    for maplibre_id, family in (
        ("pitch-surface-asphalt-pattern", "surface-asphalt"),
        ("pitch-surface-concrete-pattern", "surface-concrete"),
        ("pitch-surface-paving-pattern", "surface-paving-stones"),
        ("pitch-surface-sett-pattern", "surface-sett-11"),
        ("pitch-surface-woodchips-pattern", "surface-woodchips"),
    ):
        layer = style_layer(style, maplibre_id)
        for zoom in range(14, 21):
            name = evaluate_literal_expression(
                layer["paint"]["fill-pattern"],
                {"texture_paving_rotation_bucket": "r045"},
                zoom,
            )
            if name not in sprite_1x or name not in sprite_2x:
                errors.append(f"{maplibre_id} at z{zoom}: sprite is missing {name!r}")
    for texture in ("texture-grass", "texture-sand"):
        if texture not in sprite_1x or texture not in sprite_2x:
            errors.append(f"sprite is missing pixel RasterFill texture {texture!r}")
    verified_non_native.add(("pitch", "pitch surface", "RasterFill"))

    sandpit_qgis = next(
        layer
        for layer in root.findall(".//projectlayers/maplayer")
        if table_name(layer) == "playground_polygon"
        and layer.findtext("layername") == "sandpit"
    )
    sandpit_raster = categorized_raster_fill(sandpit_qgis, "sandpit")
    sandpit_layer = style_layer(style, "playground-sandpit-pattern")
    if (
        "sand.png" not in sandpit_raster["file"]
        or not math.isclose(float(sandpit_raster["options"]["alpha"]), 0.08)
        or sandpit_layer["paint"].get("fill-pattern") != "texture-sand"
        or not math.isclose(float(sandpit_layer["paint"].get("fill-opacity", 1)), 0.08)
    ):
        errors.append("playground sandpit RasterFill no longer matches QGIS sand texture")
    verified_non_native.add(("playground_polygon", "sandpit", "RasterFill"))

    wetland_qgis = next(
        layer
        for layer in root.findall(".//projectlayers/maplayer")
        if table_name(layer) == "water_body" and layer.findtext("layername") == "wetland"
    )
    wetland_raster = categorized_raster_fill(wetland_qgis, "wetland")
    wetland_layer = style_layer(style, "wetland-pattern")
    if (
        "wetland.png" not in wetland_raster["file"]
        or wetland_raster["width"] != "@mercator_scale * 30"
        or not math.isclose(float(wetland_raster["options"]["alpha"]), 0.3)
        or not math.isclose(float(wetland_layer["paint"].get("fill-opacity", 1)), 0.3)
    ):
        errors.append("wetland RasterFill no longer matches QGIS texture, scale, or opacity")
    verified_non_native.add(("water_body", "wetland", "RasterFill"))

    water_qgis = find_map_layer(root, "water body", "water_body_dissolved")
    water_raster = next(
        layer
        for layer in water_qgis.findall(".//renderer-v2/symbols/symbol/layer")
        if layer.get("enabled", "1") != "0" and layer.get("class") == "RasterFill"
    )
    water_pattern = style_layer(style, "water-pattern")
    if (
        "water.png" not in (data_defined_expression(water_raster, "file") or "")
        or data_defined_expression(water_raster, "width") != "@mercator_scale * 35"
        or not math.isclose(float(direct_options(water_raster)["alpha"]), 0.2)
        or not math.isclose(float(water_pattern["paint"].get("fill-opacity", 1)), 0.2)
    ):
        errors.append("water RasterFill no longer matches QGIS texture, scale, or opacity")
    for zoom in range(14, 21):
        name = evaluate_literal_expression(water_pattern["paint"]["fill-pattern"], {}, zoom)
        if name not in sprite_1x or name not in sprite_2x:
            errors.append(f"water-pattern at z{zoom}: sprite is missing {name!r}")
    verified_non_native.add(("water_body_dissolved", "water body", "RasterFill"))

    fountain_layer = style_layer(style, "feature-polygon-fountain-pattern")
    if (
        fountain_layer["paint"].get("fill-opacity") != 0.2
        or "fountain" not in json.dumps(fountain_layer.get("filter", True))
    ):
        errors.append("feature fountain RasterFill prototype drifted")
    verified_non_native.add(("feature_polygon", "feature_polygon (background)", "RasterFill"))

    # Measured against the original tiles (tiles.osm-berlin.org/strassenraumkarte):
    # buildings render as exactly #cacaca (202) there. The QGIS XML says alpha 0.7
    # (which would give 212 without the layer effect stack), so MapLibre, which
    # has no layer effects, uses the opaque colour. "building_shade" and
    # "roof shape" are unchecked in the project and are intentionally not ported.
    measured_opacity_override = {"building-fill": 1.0}
    for maplibre_id, qgis_name, table in (
        ("building-fill", "building_parts_dissolved_height", "building_parts_dissolved_height"),
        ("water-fill", "water body", "water_body_dissolved"),
    ):
        expected_color, expected_opacity = single_symbol_fill(
            find_map_layer(root, qgis_name, table)
        )
        expected_opacity = measured_opacity_override.get(maplibre_id, expected_opacity)
        layer = style_layer(style, maplibre_id)
        actual_color = layer["paint"].get("fill-color")
        actual_opacity = layer["paint"].get("fill-opacity", 1)
        if not colors_equal(actual_color, expected_color):
            errors.append(
                f"{maplibre_id}: MapLibre {actual_color!r} != QGIS rgba{expected_color}"
            )
        if not math.isclose(float(actual_opacity), expected_opacity):
            errors.append(
                f"{maplibre_id}: opacity {actual_opacity!r} != QGIS {expected_opacity}"
            )

    def check_scaled_line(
        maplibre_id: str,
        expected: tuple[tuple[int, int, int, float], float, float],
        properties_for_width: dict[str, Any],
    ) -> None:
        expected_color, expected_ground_width, expected_opacity = expected
        layer = style_layer(style, maplibre_id)
        paint = layer["paint"]
        if not colors_equal(paint.get("line-color"), expected_color):
            errors.append(
                f"{maplibre_id}: MapLibre {paint.get('line-color')!r} "
                f"!= QGIS rgba{expected_color}"
            )
        # thin_lines.compensate() turns line-opacity into a zoom expression and
        # keeps the QGIS opacity in the layer metadata.
        actual_opacity = layer.get("metadata", {}).get(
            thin_lines.BASE_OPACITY_KEY, paint.get("line-opacity", 1)
        )
        if not math.isclose(float(actual_opacity), expected_opacity):
            errors.append(
                f"{maplibre_id}: opacity {actual_opacity!r} "
                f"!= QGIS {expected_opacity}"
            )
        for zoom, pixels_per_ground_metre in ((15, 0.34385), (20, 11.0032)):
            actual_width = width_at_zoom_stop(
                paint.get("line-width"), zoom, properties_for_width
            )
            expected_width = expected_ground_width * pixels_per_ground_metre
            if not math.isclose(actual_width, expected_width, abs_tol=1e-5):
                errors.append(
                    f"{maplibre_id}: z{zoom} width {actual_width} != "
                    f"QGIS {expected_ground_width} m ({expected_width} px)"
                )

    waterway_lines = rule_simple_lines(
        find_map_layer(root, "waterway_clipped", "waterway_clipped")
    )
    check_scaled_line(
        "waterway-clipped-open", waterway_lines["river/canal"], {"waterway": "river"}
    )
    check_scaled_line(
        "waterway-clipped-open",
        waterway_lines["stream/ditch/drain"],
        {"waterway": "stream"},
    )
    check_scaled_line(
        "waterway-clipped-covered",
        waterway_lines["river/canal (tunnel)"],
        {"waterway": "river"},
    )
    check_scaled_line(
        "waterway-clipped-covered",
        waterway_lines["stream/ditch/drain (tunnel)"],
        {"waterway": "stream"},
    )

    service_lines = rule_simple_lines(
        find_unfiltered_map_layer(root, "service", "highway_service")
    )
    check_scaled_line(
        "highway-service-road", service_lines["service road"], {"class": "alley"}
    )
    check_scaled_line(
        "highway-service-driveway",
        service_lines["service driveway"],
        {"class": "driveway"},
    )

    def check_label(
        maplibre_id: str,
        zoom: float,
        feature_properties: dict[str, Any],
        expected_text_color: tuple[int, int, int, float],
        expected_text_opacity: float,
        expected_text_size: float,
        expected_buffer_color: tuple[int, int, int, float],
        expected_buffer_size: float,
    ) -> None:
        layer = style_layer(style, maplibre_id)
        layout = layer.get("layout", {})
        paint = layer.get("paint", {})
        actual_text_color = evaluate_literal_expression(
            paint.get("text-color"), feature_properties, zoom
        )
        actual_text_opacity = evaluate_literal_expression(
            paint.get("text-opacity", 1), feature_properties, zoom
        )
        actual_text_size = evaluate_literal_expression(
            layout.get("text-size"), feature_properties, zoom
        )
        actual_buffer_color = evaluate_literal_expression(
            paint.get("text-halo-color"), feature_properties, zoom
        )
        actual_buffer_size = evaluate_literal_expression(
            paint.get("text-halo-width", 0), feature_properties, zoom
        )
        if not colors_equal(actual_text_color, expected_text_color):
            errors.append(
                f"{maplibre_id} at z{zoom}: text color {actual_text_color!r} "
                f"!= QGIS rgba{expected_text_color}"
            )
        if not math.isclose(float(actual_text_opacity), expected_text_opacity):
            errors.append(
                f"{maplibre_id} at z{zoom}: text opacity {actual_text_opacity!r} "
                f"!= QGIS {expected_text_opacity}"
            )
        if not math.isclose(float(actual_text_size), expected_text_size, abs_tol=1e-6):
            errors.append(
                f"{maplibre_id}: text size {actual_text_size!r} "
                f"!= QGIS {expected_text_size} CSS px"
            )
        if not colors_equal(actual_buffer_color, expected_buffer_color):
            errors.append(
                f"{maplibre_id} at z{zoom}: halo {actual_buffer_color!r} "
                f"!= QGIS rgba{expected_buffer_color}"
            )
        if not math.isclose(float(actual_buffer_size), expected_buffer_size, abs_tol=1e-6):
            errors.append(
                f"{maplibre_id}: halo width {actual_buffer_size!r} "
                f"!= QGIS {expected_buffer_size} CSS px"
            )

    def check_label_zoom_range(
        maplibre_id: str, qgis_layer: ET.Element, qgis_description: str
    ) -> None:
        expected_minzoom, expected_maxzoom = qgis_label_zoom_range(
            qgis_layer, qgis_description
        )
        layer = style_layer(style, maplibre_id)
        if not math.isclose(float(layer.get("minzoom", 0)), expected_minzoom, abs_tol=1e-5):
            errors.append(
                f"{maplibre_id}: minzoom {layer.get('minzoom')} "
                f"!= QGIS {expected_minzoom}"
            )
        if not math.isclose(float(layer.get("maxzoom", 24)), expected_maxzoom, abs_tol=1e-5):
            errors.append(
                f"{maplibre_id}: maxzoom {layer.get('maxzoom')} "
                f"!= QGIS {expected_maxzoom}"
            )

    place_polygon = find_map_layer(root, "place_polygon", "place_polygon")
    place_node = find_map_layer(root, "place_node", "place_node")
    place_polygon_style = qgis_label_style(place_polygon, "z12")
    place_node_style = qgis_label_style(place_node, "z12")
    for suffix, description, zoom in (
        ("city", "z12", 12.5),
        ("town", "z13", 13.5),
        ("suburb", "z13 - z14", 14.5),
        ("local", "z15 - z16", 15.5),
    ):
        check_label(
            f"label-place-polygon-{suffix}",
            zoom,
            {},
            place_polygon_style[0],
            1,
            place_polygon_style[1],
            place_polygon_style[2],
            place_polygon_style[3],
        )
        check_label(
            f"label-place-node-{suffix}",
            zoom,
            {},
            place_node_style[0],
            1,
            place_node_style[1],
            place_node_style[2],
            place_node_style[3],
        )
        check_label_zoom_range(
            f"label-place-polygon-{suffix}", place_polygon, description
        )
        check_label_zoom_range(
            f"label-place-node-{suffix}", place_node, description
        )

    polygon_micro_style = qgis_label_style(place_polygon, "z16 - z18")
    polygon_font_scale = qgis_label_data_defined(
        place_polygon, "z16 - z18", "FontOpacity"
    )
    polygon_buffer_scale = qgis_label_data_defined(
        place_polygon, "z16 - z18", "BufferOpacity"
    )
    node_micro_style = qgis_label_style(place_node, "z16 - z18")
    node_buffer_scale = qgis_label_data_defined(
        place_node, "z16 - z18", "BufferOpacity"
    )
    if not polygon_font_scale or not polygon_buffer_scale or not node_buffer_scale:
        errors.append("QGIS micro-place opacity expressions could not be read")
    else:
        font_boundary, font_before, font_after = qgis_scale_opacity(polygon_font_scale)
        polygon_halo_boundary, polygon_halo_before, polygon_halo_after = (
            qgis_scale_opacity(polygon_buffer_scale)
        )
        node_halo_boundary, node_halo_before, node_halo_after = qgis_scale_opacity(
            node_buffer_scale
        )
        for zoom, text_opacity, halo_opacity in (
            (font_boundary - 0.1, font_before, polygon_halo_before),
            (font_boundary + 0.1, font_after, polygon_halo_after),
        ):
            check_label(
                "label-place-polygon-micro",
                zoom,
                {},
                polygon_micro_style[0],
                text_opacity,
                polygon_micro_style[1],
                (*polygon_micro_style[2][:3], halo_opacity),
                polygon_micro_style[3],
            )
        for zoom, halo_opacity in (
            (node_halo_boundary - 0.1, node_halo_before),
            (node_halo_boundary + 0.1, node_halo_after),
        ):
            check_label(
                "label-place-node-micro",
                zoom,
                {},
                node_micro_style[0],
                1,
                node_micro_style[1],
                (*node_micro_style[2][:3], halo_opacity),
                node_micro_style[3],
            )
    check_label_zoom_range(
        "label-place-polygon-micro", place_polygon, "z16 - z18"
    )
    check_label_zoom_range("label-place-node-micro", place_node, "z16 - z18")
    expected_area_filter = [
        "<",
        ["get", "label_min_zoom"],
        ["zoom"],
    ]
    polygon_micro_filter = style_layer(
        style, "label-place-polygon-micro"
    ).get("filter", [])
    if expected_area_filter not in polygon_micro_filter[1:]:
        errors.append(
            "label-place-polygon-micro must use the strict area-derived "
            "label_min_zoom < zoom test"
        )
    polygon_micro_rules = [
        rule
        for rule in place_polygon.findall("./labeling/rules/rule")
        if rule.get("description") == "z16 - z18"
    ]
    area_filter = polygon_micro_rules[0].get("filter", "")
    area_ratio = re.search(
        r"\$area\s*/\s*@map_scale\s*>\s*([0-9.]+)", area_filter
    )
    label_dedup_sql = (ROOT / "data/processing/sql/web/web_label_dedup.sql").read_text()
    if (
        area_ratio is None
        or f"* {float(area_ratio.group(1))}) / ST_Area" not in label_dedup_sql
        or ":qgis_scale_at_z16" not in label_dedup_sql
    ):
        errors.append("place_polygon area/scale proxy no longer matches its QGIS rule")
    params_sql = (ROOT / "data/processing/sql/web/params_web.sql").read_text()
    scale_param = re.search(r"\\set qgis_scale_at_z16\s+([0-9.]+)", params_sql)
    if scale_param is None or not math.isclose(
        float(scale_param.group(1)), qgis_scale.QGIS_SCALE_Z16, abs_tol=1e-3
    ):
        errors.append("params_web.sql qgis_scale_at_z16 does not match scripts/qgis_scale.py")

    highway_labels = find_map_layer(root, "label_highway", "label_highway")
    highway_low_style = qgis_label_style(highway_labels, "low")
    highway_high_style = qgis_label_style(highway_labels, "high")
    check_label(
        "label-highway-low", 16.5, {}, highway_low_style[0], 1,
        highway_low_style[1], highway_low_style[2], highway_low_style[3]
    )
    check_label_zoom_range("label-highway-low", highway_labels, "low")
    highway_font_scale = qgis_label_data_defined(
        highway_labels, "high", "FontOpacity"
    )
    if not highway_font_scale:
        errors.append("QGIS high-zoom highway font-opacity expression could not be read")
    else:
        boundary, before, after = qgis_scale_opacity(highway_font_scale)
        for zoom, opacity in ((boundary - 0.1, before), (boundary + 0.1, after)):
            check_label(
                "label-highway-high", zoom, {}, highway_high_style[0], opacity,
                highway_high_style[1], highway_high_style[2], highway_high_style[3]
            )
    check_label_zoom_range("label-highway-high", highway_labels, "high")

    waterway_labels = find_map_layer(root, "label_waterway", "label_waterway")
    waterway_style = qgis_label_style(waterway_labels)
    check_label(
        "label-waterway", 17, {"waterway": "river"}, waterway_style[0], 1,
        waterway_style[1], waterway_style[2], waterway_style[3]
    )
    check_label(
        "label-waterway", 17, {"waterway": "stream"},
        waterway_style[2][:3] + (1,), 1, waterway_style[1],
        waterway_style[0][:3] + (waterway_style[2][3],), waterway_style[3]
    )
    waterway_layer = style_layer(style, "label-waterway")
    expected_waterway_filter = [
        "all",
        ["has", "label_min_zoom"],
        ["<=", ["get", "label_min_zoom"], ["zoom"]],
    ]
    if waterway_layer.get("filter") != expected_waterway_filter:
        errors.append(
            "label-waterway must use its QGIS-derived label_min_zoom <= zoom test"
        )
    if waterway_layer.get("minzoom") != 12 or waterway_layer.get("maxzoom") != 21:
        errors.append("label-waterway must remain visible across the z12-z20 output range")
    waterway_size_expression = qgis_label_data_defined(
        waterway_labels, None, "Size"
    )
    visibility_sql = (
        ROOT / "data/processing/sql/web/web_label_visibility.sql"
    ).read_text()
    if not waterway_size_expression:
        errors.append("QGIS waterway label-size expression could not be read")
    else:
        length_match = re.search(r"\$length\s*<\s*([0-9.]+)", waterway_size_expression)
        scale_thresholds = re.findall(
            r"@map_scale\s*>\s*([0-9.]+)", waterway_size_expression
        )
        if length_match is None or f"< {length_match.group(1)}" not in visibility_sql:
            errors.append("waterway SQL lost the QGIS minimum label length")
        for scale in scale_thresholds:
            if f"/ {float(scale):.1f}" not in visibility_sql:
                errors.append(
                    f"waterway SQL lost the QGIS 1:{scale} visibility threshold"
                )

    housenumbers = find_map_layer(root, "housenumber", "housenumber")
    housenumber_style = qgis_label_style(housenumbers)
    check_label(
        "housenumber-labels",
        19,
        {},
        housenumber_style[0],
        1,
        housenumber_style[1],
        housenumber_style[2],
        housenumber_style[3],
    )
    housenumber_layer = style_layer(style, "housenumber-labels")
    if housenumber_layer.get("layout", {}).get("text-field") != [
        "get",
        "addr:housenumber",
    ]:
        errors.append("housenumber-labels must read QGIS's addr:housenumber field")
    # QGIS limits this simple label layer to scales 1:1,000 and closer.
    if not math.isclose(
        float(housenumber_layer.get("minzoom", 0)),
        qgis_scale.zoom_at_scale(1000),
        abs_tol=1e-3,
    ):
        errors.append(
            "housenumber-labels must begin at QGIS's 1:1,000 scale "
            f"(z{qgis_scale.zoom_at_scale(1000):.3f})"
        )

    enabled_qgis_layers = effectively_enabled_qgis_layers(root)
    qgis_tables = {
        table
        for layer in enabled_qgis_layers
        if (table := table_name(layer)) is not None
    }
    maplibre_tables = {
        layer.get("source-layer") for layer in style["layers"] if layer.get("source-layer")
    }
    represented = qgis_tables & maplibre_tables
    missing = sorted(qgis_tables - maplibre_tables)
    coverage = len(represented) / len(qgis_tables) if qgis_tables else 1
    warnings.append(
        f"whole-project table coverage: {len(represented)}/{len(qgis_tables)} "
        f"({coverage:.0%}); missing: {', '.join(missing)}"
    )
    warnings.append(
        "non-solid landuse categories need separate pattern/effect layers: "
        + ", ".join(sorted(unsupported_landuse))
    )

    represented_qgis_layers = [
        layer for layer in enabled_qgis_layers if table_name(layer) in maplibre_tables
    ]
    effect_gaps = sorted(
        {
            (
                table_name(layer) or "",
                layer.findtext("layername", ""),
                ",".join(sorted(enabled_effect_types(layer))),
            )
            for layer in represented_qgis_layers
            if enabled_effect_types(layer)
        }
    )
    if effect_gaps:
        warnings.append(
            "enabled QGIS effects on represented source tables are not verified: "
            + "; ".join(
                f"{table}/{name} [{effect_types}]"
                for table, name, effect_types in effect_gaps
            )
        )

    technique_gaps_set: set[tuple[str, str, str]] = set()
    for layer in represented_qgis_layers:
        table = table_name(layer) or ""
        name = layer.findtext("layername", "")
        unresolved = {
            technique
            for technique in symbol_layer_classes(layer) & NON_NATIVE_SYMBOL_CLASSES
            if (table, name, technique) not in verified_non_native
        }
        if unresolved:
            technique_gaps_set.add((table, name, ",".join(sorted(unresolved))))
    technique_gaps = sorted(technique_gaps_set)
    if technique_gaps:
        warnings.append(
            "non-native QGIS techniques on represented source tables need an explicit "
            "sprite/SQL/custom-renderer implementation: "
            + "; ".join(
                f"{table}/{name} [{techniques}]"
                for table, name, techniques in technique_gaps
            )
        )

    scale_band_gaps = sorted(
        {
            (
                table_name(layer) or "",
                layer.findtext("layername", ""),
                layer.get("minScale", ""),
                layer.get("maxScale", ""),
            )
            for layer in represented_qgis_layers
            if layer.get("hasScaleBasedVisibilityFlag") == "1"
            and (
                table_name(layer) or "",
                layer.findtext("layername", ""),
            )
            not in verified_scale_bands
        }
    )
    if scale_band_gaps:
        warnings.append(
            "scale-banded QGIS layer configs on represented tables require boundary "
            "verification: "
            + "; ".join(
                f"{table}/{name} [{maximum}..{minimum}]"
                for table, name, maximum, minimum in scale_band_gaps
            )
        )

    qgis_layered_tables = {
        table_name(layer)
        for layer in represented_qgis_layers
        if re.search(r'\"layer\"\s*(?:=|>=|<=)', layer.findtext("datasource", ""))
    }
    expected_strata = (
        ("low", "<= -2", ["<=", ["coalesce", ["get", "layer"], 0], -2]),
        ("minus-1", "= -1", ["==", ["coalesce", ["get", "layer"], 0], -1]),
        ("ground", "= 0 or NULL", ["==", ["coalesce", ["get", "layer"], 0], 0]),
        ("plus-1", "= 1", ["==", ["coalesce", ["get", "layer"], 0], 1]),
        ("plus-2", "= 2", ["==", ["coalesce", ["get", "layer"], 0], 2]),
        ("high", ">= 3", [">=", ["coalesce", ["get", "layer"], 0], 3]),
    )
    stratum_errors: list[str] = []
    declared_layer_strata = set(
        style.get("metadata", {}).get("strassenraumkarte:layer-strata", [])
    )
    expected_layered_tables = {table for table in qgis_layered_tables if table}
    if declared_layer_strata != expected_layered_tables:
        stratum_errors.append(
            f"declared tables {sorted(declared_layer_strata)!r} != "
            f"QGIS {sorted(expected_layered_tables)!r}"
        )
    declared_order = style.get("metadata", {}).get(
        "strassenraumkarte:layer-strata-order", []
    )
    layered_group = next(
        (
            group
            for group in root.findall(".//layer-tree-group")
            if group.get("name") == "highway (layered)"
        ),
        None,
    )
    qgis_draw_order = (
        [
            (
                "= 0 or NULL"
                if child.get("name", "").removeprefix("layer ") == "= 0"
                else child.get("name", "").removeprefix("layer ")
            )
            for child in reversed(list(layered_group))
            if child.tag == "layer-tree-group"
        ]
        if layered_group is not None
        else []
    )
    expected_declared_order = [qgis_filter for _, qgis_filter, _ in expected_strata]
    if declared_order != expected_declared_order or declared_order != qgis_draw_order:
        stratum_errors.append(
            f"draw order {declared_order!r} != QGIS bottom-to-top {qgis_draw_order!r}"
        )

    indexed_layers = list(enumerate(style["layers"]))
    generated_strata_layers = [
        (index, layer)
        for index, layer in indexed_layers
        if layer.get("source-layer") in expected_layered_tables
    ]
    base_ids = sorted({base_layer_id(layer) for _, layer in generated_strata_layers})
    for base_id in base_ids:
        clones = [
            layer
            for _, layer in generated_strata_layers
            if base_layer_id(layer) == base_id
        ]
        actual_names = [
            layer.get("metadata", {}).get("strassenraumkarte:stratum")
            for layer in clones
        ]
        wanted_names = [name for name, _, _ in expected_strata]
        if sorted(actual_names) != sorted(wanted_names):
            stratum_errors.append(
                f"{base_id}: strata {actual_names!r} != {wanted_names!r}"
            )
        for name, _, expected_filter in expected_strata:
            matches = [
                layer
                for layer in clones
                if layer.get("metadata", {}).get("strassenraumkarte:stratum") == name
            ]
            if len(matches) != 1 or not contains_expression(
                matches[0].get("filter") if matches else None, expected_filter
            ):
                stratum_errors.append(f"{base_id}: missing exact {name} filter")

    previous_max = -1
    source_draw_order = (
        "highway_service",
        "highway_area",
        "road_marking_polygon",
        "road_marking_way",
    )
    for name, _, _ in expected_strata:
        members = [
            (index, layer)
            for index, layer in generated_strata_layers
            if layer.get("metadata", {}).get("strassenraumkarte:stratum") == name
        ]
        indices = [index for index, _ in members]
        if not indices or min(indices) <= previous_max:
            stratum_errors.append(f"{name}: stratum groups overlap or are out of order")
            continue
        previous_max = max(indices)
        family_positions = {
            source: [index for index, layer in members if layer.get("source-layer") == source]
            for source in source_draw_order
        }
        for lower, upper in zip(source_draw_order, source_draw_order[1:]):
            if (
                not family_positions[lower]
                or not family_positions[upper]
                or max(family_positions[lower]) >= min(family_positions[upper])
            ):
                stratum_errors.append(
                    f"{name}: {lower} must draw below {upper} as in QGIS"
                )

    layer_order_gaps = sorted(expected_layered_tables) if stratum_errors else []
    if stratum_errors:
        warnings.append(
            "QGIS bridge/tunnel strata are not faithfully reproduced: "
            + "; ".join(stratum_errors[:20])
        )

    if args.require_full_coverage and missing:
        errors.append("full coverage requested, but enabled QGIS tables are missing")
    if args.require_full_parity:
        if missing:
            errors.append("full parity requested, but enabled QGIS tables are missing")
        if effect_gaps:
            errors.append("full parity requested, but enabled QGIS effects are unverified")
        if technique_gaps:
            errors.append("full parity requested, but non-native QGIS techniques are unresolved")
        if scale_band_gaps:
            errors.append("full parity requested, but scale-band boundaries are unverified")
        if layer_order_gaps:
            errors.append("full parity requested, but bridge/tunnel layer order is unresolved")

    for message in warnings:
        print(f"WARN: {message}")
    if errors:
        for message in errors:
            print(f"ERROR: {message}", file=sys.stderr)
        print(f"FAIL: {len(errors)} parity error(s)", file=sys.stderr)
        return 1
    print(
        "PASS: audited direct QGIS values and declared tile properties match; "
        "warnings above remain outside that scope"
    )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qgis-project", type=Path, default=DEFAULT_QGZ)
    parser.add_argument("--style", type=Path, default=DEFAULT_STYLE)
    parser.add_argument("--martin-config", type=Path, default=DEFAULT_MARTIN)
    parser.add_argument("--require-full-coverage", action="store_true")
    parser.add_argument("--require-full-parity", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(audit(parse_args()))
