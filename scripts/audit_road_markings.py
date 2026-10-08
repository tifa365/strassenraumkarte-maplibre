#!/usr/bin/env python3
"""Check every real road-marking stroke/dash combination against MapLibre.

The QGIS renderer has overlapping rules for normal, zigzag, double, zebra,
and sharks-teeth markings.  This audit asks PostGIS for the distinct live
combinations, evaluates the MapLibre filters, and checks the normalized dash
lengths.  It catches plausible-looking leaks where a special marking also
matches a generic line layer.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import zoom_convention as zc


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_STYLE = ROOT / "web" / "style.json"
UNRESOLVED_SPECIAL_GEOMETRY_STROKES = {"zebra", "ladder"}
QGIS_AVERAGE_ANGLE_WINDOW_MAP_UNITS = 4.0
QGIS_AVERAGE_ANGLE_RADIUS_MAP_UNITS = QGIS_AVERAGE_ANGLE_WINDOW_MAP_UNITS / 2.0


def point_at_distance(
    points: tuple[tuple[float, float], ...], distance: float
) -> tuple[float, float]:
    """Interpolate a point along a simple fixture polyline."""
    remaining = distance
    for start, end in zip(points, points[1:]):
        length = math.dist(start, end)
        if remaining <= length:
            fraction = remaining / length
            return (
                start[0] + (end[0] - start[0]) * fraction,
                start[1] + (end[1] - start[1]) * fraction,
            )
        remaining -= length
    return points[-1]


def qgis_average_angle_fixture_errors() -> list[str]:
    """Lock QGIS's half-window MarkerLine behavior with fixed geometry cases.

    QGIS converts ``average_angle_length=4 MapUnit`` to a two-map-unit radius
    before collecting the start and end angle points. These values are fixed
    from QGIS's MarkerLine implementation, not derived from the SQL table.
    """
    corner = ((0.0, 0.0), (4.0, 0.0), (4.0, 4.0))
    fixtures = (
        # At distance 3, QGIS samples (1, 0) and (4, 1): ±2 produces this
        # tangent, while the former ±4 implementation would sample the line
        # ends and produce (4, 3) instead.
        (
            "bent line with asymmetric average window",
            corner,
            3.0,
            (3.0 / math.sqrt(10.0), 1.0 / math.sqrt(10.0)),
        ),
        ("open-line start clamp", corner, 0.0, (1.0, 0.0)),
        ("open-line end clamp", corner, 8.0, (0.0, 1.0)),
    )
    errors: list[str] = []
    for name, points, marker_distance, expected in fixtures:
        line_length = sum(
            math.dist(start, end) for start, end in zip(points, points[1:])
        )
        start = point_at_distance(
            points, max(0.0, marker_distance - QGIS_AVERAGE_ANGLE_RADIUS_MAP_UNITS)
        )
        end = point_at_distance(
            points,
            min(line_length, marker_distance + QGIS_AVERAGE_ANGLE_RADIUS_MAP_UNITS),
        )
        length = math.dist(start, end)
        actual = ((end[0] - start[0]) / length, (end[1] - start[1]) / length)
        if not all(math.isclose(value, wanted, abs_tol=1e-12) for value, wanted in zip(actual, expected)):
            errors.append(
                f"QGIS average-angle fixture {name!r}: {actual!r} != {expected!r}"
            )
    return errors


def evaluate(expression: Any, feature: dict[str, Any]) -> Any:
    if not isinstance(expression, list):
        return expression
    operator = expression[0]
    if operator == "get":
        return feature.get(expression[1])
    if operator == "has":
        return expression[1] in feature and feature[expression[1]] is not None
    if operator == "!":
        return not bool(evaluate(expression[1], feature))
    if operator == "all":
        return all(bool(evaluate(item, feature)) for item in expression[1:])
    if operator == "any":
        return any(bool(evaluate(item, feature)) for item in expression[1:])
    if operator == "match":
        value = evaluate(expression[1], feature)
        for labels, output in zip(expression[2:-1:2], expression[3:-1:2]):
            if value in labels if isinstance(labels, list) else value == labels:
                return evaluate(output, feature)
        return evaluate(expression[-1], feature)
    if operator == "coalesce":
        for item in expression[1:]:
            value = evaluate(item, feature)
            if value is not None:
                return value
        return None
    if operator in {"==", "!=", "<", "<=", ">", ">="}:
        left = evaluate(expression[1], feature)
        right = evaluate(expression[2], feature)
        if operator == "==":
            return left == right
        if operator == "!=":
            return left != right
        if left is None or right is None:
            return False
        if operator == "<":
            return left < right
        if operator == "<=":
            return left <= right
        if operator == ">":
            return left > right
        return left >= right
    raise ValueError(f"unsupported filter operator {operator!r}")


def query_json(args: argparse.Namespace, query: str) -> Any:
    command = [
        "psql",
        "--no-psqlrc",
        "-XAt",
        "-h",
        args.host,
        "-p",
        str(args.port),
        "-U",
        args.user,
        "-d",
        args.database,
        "-c",
        query,
    ]
    completed = subprocess.run(command, check=True, text=True, capture_output=True)
    return json.loads(completed.stdout)


def query_combinations(args: argparse.Namespace) -> list[dict[str, Any]]:
    result = query_json(
        args,
        """
        SELECT json_agg(r ORDER BY feature_count DESC, stroke, dasharray, width)
        FROM (
            SELECT
                COALESCE(stroke, '') AS stroke,
                COALESCE(dasharray, '') AS dasharray,
                width,
                COALESCE(road_marking, '') AS road_marking,
                COALESCE(pattern, '') AS pattern,
                COALESCE(layer, 0) AS highway_layer,
                count(*) AS feature_count
            FROM road_marking_way
            GROUP BY stroke, dasharray, width, road_marking, pattern, layer
        ) r
        """,
    )
    return result or []


def query_sharks_teeth(args: argparse.Namespace) -> dict[str, Any]:
    """Golden-value audit for the SQL translation of QGIS MarkerLine.

    This deliberately recomputes QGIS's marker count, interval positions,
    QGIS's four-map-unit average-angle window (a two-map-unit radius),
    normalized triangle, rotation, and rotated
    marker offset from road_marking_way. It does not trust the derived table's
    own values.
    """
    return query_json(
        args,
        r"""
        WITH source AS (
            SELECT
                rm.source,
                rm.osm_type,
                rm.osm_id,
                COALESCE(rm.layer, 0) AS layer,
                COALESCE(NULLIF(rm.colour, ''), 'white') AS colour,
                rm.geom::geometry(LineString, 3857) AS line_geom,
                string_to_array(rm.dasharray, ';')::double precision[] AS dash,
                ST_Length(rm.geom) AS line_length
            FROM road_marking_way rm
            WHERE rm.stroke = 'sharks_teeth'
        ),
        expected AS (
            SELECT
                source.*,
                dash[1] AS size_m,
                dash[2] AS offset_m,
                (SELECT sum(value) FROM unnest(dash) AS values_(value)) AS interval_m,
                GREATEST(
                    0,
                    floor(
                        (
                            line_length - metres(dash[2]) - 1e-9
                        ) / metres(
                            (SELECT sum(value) FROM unnest(dash) AS values_(value))
                        )
                    )::integer + 1
                ) AS expected_count
            FROM source
        ),
        actual_counts AS (
            SELECT source, osm_type, osm_id, count(*)::integer AS actual_count
            FROM road_marking_sharks_teeth
            GROUP BY source, osm_type, osm_id
        ),
        metric_base AS (
            SELECT
                tooth.*,
                exp.line_geom,
                exp.layer AS expected_layer,
                exp.colour AS expected_colour,
                exp.size_m AS expected_size_m,
                exp.offset_m AS expected_offset_m,
                exp.interval_m AS expected_interval_m,
                exp.expected_count,
                metres(exp.size_m) AS size_mu,
                ST_LineInterpolatePoint(
                    exp.line_geom,
                    tooth.distance_along / exp.line_length
                )::geometry(Point, 3857) AS marker_point,
                ST_PointN(ST_ExteriorRing(tooth.geom), 1) AS actual_base_1,
                ST_PointN(ST_ExteriorRing(tooth.geom), 2) AS actual_base_2,
                ST_PointN(ST_ExteriorRing(tooth.geom), 3) AS actual_tip,
                ST_LineInterpolatePoint(
                    exp.line_geom,
                    GREATEST(0.0, tooth.distance_along - 2.0) / exp.line_length
                )::geometry(Point, 3857) AS angle_p1,
                ST_LineInterpolatePoint(
                    exp.line_geom,
                    LEAST(exp.line_length, tooth.distance_along + 2.0)
                        / exp.line_length
                )::geometry(Point, 3857) AS angle_p2
            FROM road_marking_sharks_teeth tooth
            JOIN expected exp USING (source, osm_type, osm_id)
        ),
        vectors AS (
            SELECT
                metric_base.*,
                (
                    ST_X(angle_p2) - ST_X(angle_p1)
                ) / ST_Distance(angle_p1, angle_p2) AS tx,
                (
                    ST_Y(angle_p2) - ST_Y(angle_p1)
                ) / ST_Distance(angle_p1, angle_p2) AS ty
            FROM metric_base
        ),
        expected_vertices AS (
            SELECT
                vectors.*,
                ST_SetSRID(ST_MakePoint(
                    ST_X(marker_point) + ty * size_mu * 0.25
                        + tx * size_mu * 0.5 - ty * size_mu * 0.5,
                    ST_Y(marker_point) - tx * size_mu * 0.25
                        + ty * size_mu * 0.5 + tx * size_mu * 0.5
                ), 3857) AS expected_base_1,
                ST_SetSRID(ST_MakePoint(
                    ST_X(marker_point) + ty * size_mu * 0.25
                        - tx * size_mu * 0.5 - ty * size_mu * 0.5,
                    ST_Y(marker_point) - tx * size_mu * 0.25
                        - ty * size_mu * 0.5 + tx * size_mu * 0.5
                ), 3857) AS expected_base_2,
                ST_SetSRID(ST_MakePoint(
                    ST_X(marker_point) + ty * size_mu * 0.75,
                    ST_Y(marker_point) - tx * size_mu * 0.75
                ), 3857) AS expected_tip
            FROM vectors
        ),
        metrics AS (
            SELECT
                expected_vertices.*,
                GREATEST(
                    ST_Distance(actual_base_1, expected_base_1),
                    ST_Distance(actual_base_2, expected_base_2),
                    ST_Distance(actual_tip, expected_tip)
                ) AS vertex_error
            FROM expected_vertices
        )
        SELECT json_build_object(
            'rendered_source_features', (
                SELECT count(*) FROM expected WHERE expected_count > 0
            ),
            'actual_source_features', (
                SELECT count(DISTINCT (source, osm_type, osm_id))
                FROM road_marking_sharks_teeth
            ),
            'expected_teeth', (SELECT COALESCE(sum(expected_count), 0) FROM expected),
            'actual_teeth', (SELECT count(*) FROM road_marking_sharks_teeth),
            'count_mismatches', (
                SELECT count(*)
                FROM expected exp
                LEFT JOIN actual_counts act USING (source, osm_type, osm_id)
                WHERE COALESCE(act.actual_count, 0) <> exp.expected_count
            ),
            'metric_mismatches', (
                SELECT count(*)
                FROM metrics
                WHERE marker_index < 0
                   OR marker_index >= expected_count
                   OR abs(marker_size_m - expected_size_m) > 1e-6
                   OR abs(offset_m - expected_offset_m) > 1e-6
                   OR abs(interval_m - expected_interval_m) > 1e-6
                   OR abs(average_angle_map_units - 4.0) > 1e-6
                   OR abs(
                       distance_along - metres(
                           expected_offset_m + marker_index * expected_interval_m
                       )
                   ) > 1e-7
                   OR layer <> expected_layer
                   OR colour <> expected_colour
                   OR ST_GeometryType(geom) <> 'ST_Polygon'
                   OR NOT ST_IsValid(geom)
                   OR ST_NPoints(geom) <> 4
                   OR abs(ST_Area(geom) - 0.5 * size_mu * size_mu) > 1e-6
                   OR vertex_error > 1e-6
            ),
            'max_vertex_error', (SELECT COALESCE(max(vertex_error), 0) FROM metrics),
            'layers', (
                SELECT COALESCE(
                    json_agg(json_build_object('layer', layer, 'feature_count', n) ORDER BY layer),
                    '[]'::json
                )
                FROM (
                    SELECT layer, count(*) AS n
                    FROM road_marking_sharks_teeth
                    GROUP BY layer
                ) grouped
            )
        )
        """,
    )


def expected_dash(row: dict[str, Any]) -> list[float] | None:
    dasharray = row.get("dasharray", "")
    width = row.get("width") or 0.12
    if not dasharray:
        return None
    return [float(value) / float(width) for value in dasharray.split(";")]


def dash_equal(actual: Any, expected: list[float] | None) -> bool:
    if expected is None:
        return actual is None
    return (
        isinstance(actual, list)
        and len(actual) == len(expected)
        and all(
            math.isclose(float(left), float(right), abs_tol=1e-5)
            for left, right in zip(actual, expected)
        )
    )


def expected_double_side_dash(row: dict[str, Any], side: str) -> list[float] | None:
    stroke = row["stroke"]
    dash = expected_dash(row)
    if not dash:
        return None
    if ";" not in stroke:
        return dash
    token = stroke.split(";")[0 if side == "left" else -1]
    return dash if token == "dashed" else None


def expected_stratum(layer: int) -> str:
    if layer <= -2:
        return "low"
    if layer == -1:
        return "minus-1"
    if layer == 0:
        return "ground"
    if layer == 1:
        return "plus-1"
    if layer == 2:
        return "plus-2"
    return "high"


def audit(args: argparse.Namespace) -> int:
    style = zc.load_style(args.style, zc.RASTER)  # audited in QGIS raster-zoom units
    marking_layers = [
        layer
        for layer in style["layers"]
        if layer.get("source-layer") == "road_marking_way"
    ]
    sharks_layers = [
        layer
        for layer in style["layers"]
        if layer.get("source-layer") == "road_marking_sharks_teeth"
    ]
    rows = query_combinations(args)
    errors = qgis_average_angle_fixture_errors()
    unresolved_features = 0

    for row in rows:
        row["layer"] = int(row["highway_layer"])
        matching = [
            layer
            for layer in marking_layers
            if evaluate(layer.get("filter", True), row)
        ]
        stroke = row["stroke"]
        description = (
            f"stroke={stroke!r}, dasharray={row['dasharray']!r}, "
            f"width={row['width']!r}, pattern={row['pattern']!r}, "
            f"layer={row['highway_layer']!r}"
        )
        wanted_stratum = expected_stratum(int(row["highway_layer"]))
        wrong_strata = [
            layer["id"]
            for layer in matching
            if layer.get("metadata", {}).get("strassenraumkarte:stratum")
            != wanted_stratum
        ]
        if wrong_strata:
            errors.append(
                f"{description}: selected wrong bridge/tunnel strata {wrong_strata!r}"
            )

        if stroke == "sharks_teeth":
            if matching:
                errors.append(
                    f"{description}: derived sharks-teeth geometry leaks into "
                    + ", ".join(layer["id"] for layer in matching)
                )
            continue

        if stroke in UNRESOLVED_SPECIAL_GEOMETRY_STROKES:
            unresolved_features += int(row["feature_count"])
            if matching:
                errors.append(
                    f"{description}: special geometry leaks into "
                    + ", ".join(layer["id"] for layer in matching)
                )
            continue

        is_double = "double" in stroke or ";" in stroke
        if is_double:
            left = [layer for layer in matching if "double-left" in layer["id"]]
            right = [layer for layer in matching if "double-right" in layer["id"]]
            if len(left) != 1 or len(right) != 1 or len(matching) != 2:
                errors.append(
                    f"{description}: expected exactly one left and one right layer, got "
                    + ", ".join(layer["id"] for layer in matching)
                )
                continue
            for side, layers in (("left", left), ("right", right)):
                actual_dash = layers[0].get("paint", {}).get("line-dasharray")
                wanted_dash = expected_double_side_dash(row, side)
                if not dash_equal(actual_dash, wanted_dash):
                    errors.append(
                        f"{description}: {side} dash {actual_dash!r} != {wanted_dash!r}"
                    )
            continue

        if len(matching) != 1:
            errors.append(
                f"{description}: expected one QGIS single/zigzag line, got "
                + ", ".join(layer["id"] for layer in matching)
            )
            continue
        actual_dash = matching[0].get("paint", {}).get("line-dasharray")
        wanted_dash = expected_dash(row)
        if not dash_equal(actual_dash, wanted_dash):
            errors.append(
                f"{description}: dash {actual_dash!r} != normalized QGIS {wanted_dash!r}"
            )

    sharks = query_sharks_teeth(args)
    source_features = int(sharks["rendered_source_features"])
    actual_source_features = int(sharks["actual_source_features"])
    expected_teeth = int(sharks["expected_teeth"])
    actual_teeth = int(sharks["actual_teeth"])
    if source_features != actual_source_features:
        errors.append(
            "sharks_teeth: derived table covers "
            f"{actual_source_features}/{source_features} source features"
        )
    if expected_teeth != actual_teeth:
        errors.append(
            f"sharks_teeth: {actual_teeth} polygons != {expected_teeth} QGIS markers"
        )
    if int(sharks["count_mismatches"]):
        errors.append(
            "sharks_teeth: "
            f"{sharks['count_mismatches']} source rows have the wrong marker count"
        )
    if int(sharks["metric_mismatches"]):
        errors.append(
            "sharks_teeth: "
            f"{sharks['metric_mismatches']} polygons differ in size, spacing, "
            "orientation, offset, colour, layer, or normalized triangle geometry"
        )

    wanted_strata = {
        "low", "minus-1", "ground", "plus-1", "plus-2", "high"
    }
    actual_strata = {
        layer.get("metadata", {}).get("strassenraumkarte:stratum")
        for layer in sharks_layers
    }
    if len(sharks_layers) != 6 or actual_strata != wanted_strata:
        errors.append(
            "sharks_teeth: expected one fill in every QGIS stratum, got "
            + ", ".join(layer["id"] for layer in sharks_layers)
        )
    expected_colour = ["coalesce", ["get", "colour"], "#ffffff"]
    for layer in sharks_layers:
        if layer.get("type") != "fill":
            errors.append(f"{layer['id']}: QGIS triangle geometry must use a fill layer")
        if layer.get("paint", {}).get("fill-color") != expected_colour:
            errors.append(f"{layer['id']}: sharks-teeth fill colour expression drifted")
        if layer.get("minzoom") != 15:
            errors.append(f"{layer['id']}: sharks-teeth visibility must start at z15")

    for grouped in sharks["layers"]:
        highway_layer = int(grouped["layer"])
        feature = {"layer": highway_layer}
        matching = [
            layer
            for layer in sharks_layers
            if evaluate(layer.get("filter", True), feature)
        ]
        wanted = expected_stratum(highway_layer)
        if len(matching) != 1 or matching[0].get("metadata", {}).get(
            "strassenraumkarte:stratum"
        ) != wanted:
            errors.append(
                f"sharks_teeth layer={highway_layer}: expected only {wanted}, got "
                + ", ".join(layer["id"] for layer in matching)
            )

    if unresolved_features:
        print(
            "WARN: "
            f"{unresolved_features} zebra/ladder features require SQL-derived tick geometry"
        )
        if args.require_special_geometries:
            errors.append("special road-marking geometry is required but remains unresolved")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"FAIL: {len(errors)} road-marking corpus error(s)", file=sys.stderr)
        return 1
    print(
        f"PASS: {len(rows)} distinct live road-marking combinations select the expected "
        f"layers and dash values; {actual_teeth} sharks-teeth polygons match QGIS "
        f"counts, spacing, size, offset, orientation, and strata "
        f"(max vertex error {float(sharks['max_vertex_error']):.2g} map units)"
    )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--style", type=Path, default=DEFAULT_STYLE)
    parser.add_argument("--host", default=os.environ.get("DB_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("DB_PORT", "5433")))
    parser.add_argument("--user", default=os.environ.get("DB_USER", "postgres"))
    parser.add_argument(
        "--database", default=os.environ.get("DB_NAME", "strassenraumkarte")
    )
    parser.add_argument("--require-special-geometries", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(audit(parse_args()))
