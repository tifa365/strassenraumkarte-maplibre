#!/usr/bin/env python3
"""Check live highway surfaces against SQL buckets and MapLibre patterns.

This is the data-side companion to ``audit_maplibre_parity.py``.  It checks
every distinct live surface/direction/sett-length combination, not a small
screenshot sample, then probes both sides of every z14-z20 pattern boundary.
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

from audit_maplibre_parity import evaluate_literal_expression
from audit_road_markings import evaluate as evaluate_filter


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_STYLE = ROOT / "web" / "style.json"
DEFAULT_SPRITE = ROOT / "web" / "sprite.json"
TEXTURED_SURFACES = {
    "asphalt",
    "concrete",
    "concrete:plates",
    "paving_stones",
    "sett",
}


def query_combinations(args: argparse.Namespace) -> list[dict[str, Any]]:
    query = """
        SELECT json_agg(r ORDER BY surface, direction, sett_length)
        FROM (
            SELECT
                surface,
                COALESCE("sett:length", '') AS sett_length,
                COALESCE(layer, 0) AS highway_layer,
                direction,
                texture_rotation_bucket,
                texture_paving_rotation_bucket,
                count(*) AS feature_count
            FROM highway_area
            WHERE surface IN (
                'asphalt', 'concrete', 'concrete:plates', 'paving_stones', 'sett'
            )
            GROUP BY
                surface, "sett:length", layer, direction,
                texture_rotation_bucket, texture_paving_rotation_bucket
        ) r
    """
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
    return json.loads(completed.stdout) or []


def expected_bucket(angle: float) -> str:
    # PostgreSQL round() is half-away-from-zero. Directions are normalized
    # non-negative, so floor(x + .5) is the identical deterministic rule.
    bucket = int(math.floor(angle / 15 + 0.5)) * 15 % 360
    return f"r{bucket:03d}"


def expected_layer_and_family(row: dict[str, Any]) -> tuple[str, str, str | None]:
    surface = row["surface"]
    if surface in {"concrete", "concrete:plates"}:
        return (
            "highway-area-surface-concrete",
            "surface-concrete-multiply",
            "texture_rotation_bucket",
        )
    if surface == "paving_stones":
        return (
            "highway-area-surface-paving-stones",
            "surface-paving-stones-multiply",
            "texture_paving_rotation_bucket",
        )
    if surface == "asphalt":
        return "highway-area-surface-asphalt", "surface-asphalt", None
    if row["sett_length"] == "5 cm":
        return (
            "highway-area-surface-sett-5cm",
            "surface-sett-6-multiply",
            "texture_rotation_bucket",
        )
    if row["sett_length"] == "10 cm":
        return (
            "highway-area-surface-sett-10cm",
            "surface-sett-8_5-multiply",
            "texture_rotation_bucket",
        )
    return (
        "highway-area-surface-sett-default",
        "surface-sett-11-multiply",
        "texture_rotation_bucket",
    )


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
    sprite = json.loads(args.sprite.read_text())
    layers = {
        layer["id"]: layer
        for layer in style["layers"]
        if layer.get("id", "").startswith("highway-area-surface-")
    }
    rows = query_combinations(args)
    errors: list[str] = []
    feature_count = 0

    for row in rows:
        feature_count += int(row["feature_count"])
        direction = float(row["direction"])
        wanted_rotation = expected_bucket(direction)
        wanted_paving = expected_bucket(direction + 45)
        if row["texture_rotation_bucket"] != wanted_rotation:
            errors.append(
                f"{row['surface']} direction {direction}: rotation bucket "
                f"{row['texture_rotation_bucket']!r} != {wanted_rotation!r}"
            )
        if row["texture_paving_rotation_bucket"] != wanted_paving:
            errors.append(
                f"{row['surface']} direction {direction}: paving bucket "
                f"{row['texture_paving_rotation_bucket']!r} != {wanted_paving!r}"
            )

        feature = {
            "surface": row["surface"],
            "sett:length": row["sett_length"] or None,
            "layer": int(row["highway_layer"]),
            "texture_rotation_bucket": row["texture_rotation_bucket"],
            "texture_paving_rotation_bucket": row[
                "texture_paving_rotation_bucket"
            ],
        }
        matching = [
            layer
            for layer in layers.values()
            if evaluate_filter(layer.get("filter", True), feature)
        ]
        wanted_id, family, bucket_property = expected_layer_and_family(row)
        wanted_stratum = expected_stratum(feature["layer"])
        if (
            len(matching) != 1
            or matching[0].get("metadata", {}).get("strassenraumkarte:base-id")
            != wanted_id
            or matching[0].get("metadata", {}).get("strassenraumkarte:stratum")
            != wanted_stratum
        ):
            errors.append(
                f"surface={row['surface']!r}, sett:length={row['sett_length']!r}, "
                f"layer={feature['layer']}: selected "
                f"{[layer['id'] for layer in matching]!r}, expected "
                f"{wanted_id!r}/{wanted_stratum}"
            )
            continue
        layer = matching[0]
        if layer.get("minzoom") != 14:
            errors.append(f"{wanted_id}: minzoom {layer.get('minzoom')} != z14")

        probes = [14.0]
        for boundary in range(15, 21):
            probes.extend((boundary - 0.0001, float(boundary), boundary + 0.0001))
        for zoom in probes:
            band = min(20, max(14, math.floor(zoom)))
            expected_name = f"{family}-z{band}"
            if bucket_property:
                expected_name += f"-{feature[bucket_property]}"
            actual_name = evaluate_literal_expression(
                layer["paint"]["fill-pattern"], feature, zoom
            )
            if actual_name != expected_name:
                errors.append(
                    f"{wanted_id} at z{zoom}: {actual_name!r} != {expected_name!r}"
                )
            if actual_name not in sprite:
                errors.append(f"{wanted_id} at z{zoom}: sprite {actual_name!r} is missing")

    if errors:
        for error in errors[:100]:
            print(f"ERROR: {error}", file=sys.stderr)
        if len(errors) > 100:
            print(f"ERROR: ...and {len(errors) - 100} more", file=sys.stderr)
        print(f"FAIL: {len(errors)} surface-texture error(s)", file=sys.stderr)
        return 1
    print(
        f"PASS: {len(rows)} distinct live combinations ({feature_count} features) "
        "match SQL angle buckets, surface rules, sprite IDs, and every z14-z20 boundary"
    )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--style", type=Path, default=DEFAULT_STYLE)
    parser.add_argument("--sprite", type=Path, default=DEFAULT_SPRITE)
    parser.add_argument("--host", default=os.environ.get("DB_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("DB_PORT", "5433")))
    parser.add_argument("--user", default=os.environ.get("DB_USER", "postgres"))
    parser.add_argument(
        "--database", default=os.environ.get("DB_NAME", "strassenraumkarte")
    )
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(audit(parse_args()))
