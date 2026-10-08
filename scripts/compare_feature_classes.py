#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow", "numpy", "scipy"]
# ///
"""Rank map feature classes by how differently QGIS and MapLibre draw them.

    ./scripts/compare_feature_classes.py blocks.json [--top 40] [--csv out.csv]

blocks.json lists comparison blocks of 3x3 tiles that were rendered by both
renderers (and optionally fetched from the original tiles):

    [{"z": 17, "x0": 70425, "y0": 43010,
      "qgis": "<dir with z/x/y.png>",          # render_tiles.sh --format png output
      "maplibre": "<capture.png>",             # capture_maplibre_block.js for the same block
      "original": "<dir with z/x/y.jpg>"}]     # optional

For every table/class in CLASSES the features inside each block are taken from
PostGIS: polygons are rasterised and sampled inside (eroded by a pixel so edges
and antialiasing do not count), lines are sampled along their centreline and
points at the point. Pixels are pooled per class over all blocks.

Reported per class: sampled pixels, median colour in QGIS / MapLibre /
original, the colour bias between the medians as CIE76 Delta E (Lab), and an
impact score = bias x share of all sampled pixels, which is the sort key. A
class whose QGIS-vs-original Delta E is large differs because of data age or
the project, not because of the MapLibre port.

Medians are robust against labels and icons on top, but a class is always seen
through whatever is drawn above it (trees over lawns, markings over roads), in
both renderers alike. Read the ranking as "look here first", then inspect.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

TILE = 256
BLOCK = 3 * TILE
WORLD_HALF = 20037508.342789244

# (table, geometry kind, SQL class expression)
CLASSES: tuple[tuple[str, str, str], ...] = (
    ("landuse", "polygon", "class"),
    ("building_parts_dissolved_height", "polygon", "'building'"),
    ("highway_area", "polygon", "\"area:highway\" || coalesce('/' || surface, '')"),
    ("water_body_dissolved", "polygon", "'water'"),
    ("feature_polygon", "polygon", "class"),
    ("pitch", "polygon", "coalesce(sport, '-') || '/' || coalesce(surface, '-')"),
    ("playground_polygon", "polygon", "playground"),
    ("road_marking_polygon", "polygon", "road_marking || coalesce('/' || colour, '')"),
    ("barrier_polygon", "polygon", "barrier"),
    ("bridge", "polygon", "'bridge'"),
    ("highway", "line", "highway || coalesce(':' || class, '')"),
    ("highway_service", "line", "class"),
    ("road_marking_way", "line", "road_marking || coalesce('/' || colour, '')"),
    ("barrier_way", "line", "barrier"),
    ("railway_way", "line", "railway"),
    ("waterway_clipped", "line", "waterway"),
    ("landscape_way", "line", "class"),
    ("feature_way", "line", "class"),
    ("playground_way", "line", "playground"),
    ("tree", "point", "\"natural\""),
    ("feature_node", "point", "class"),
    ("barrier_node", "point", "barrier"),
    ("road_marking_node", "point", "road_marking"),
    ("parking_cars", "point", "'car'"),
)


def psql(query: str) -> list[list[str]]:
    env = os.environ
    command = [
        "psql", "--no-psqlrc", "-XAt", "-F", "\t",
        "-h", env.get("DB_HOST", "localhost"), "-p", env.get("DB_PORT", "5433"),
        "-U", env.get("DB_USER", "postgres"), "-d", env.get("DB_NAME", "strassenraumkarte"),
        "-c", query,
    ]
    out = subprocess.run(command, check=True, text=True, capture_output=True).stdout
    return [line.split("\t") for line in out.splitlines() if line]


def block_frame(z: int, x0: int, y0: int) -> tuple[float, float, float]:
    """(left, top, metres per pixel) of the block in EPSG:3857."""
    tile_m = 2 * WORLD_HALF / 2**z
    return -WORLD_HALF + x0 * tile_m, WORLD_HALF - y0 * tile_m, tile_m / TILE


def stitch(directory: str, z: int, x0: int, y0: int) -> np.ndarray:
    image = Image.new("RGB", (BLOCK, BLOCK), (255, 0, 255))
    for dx in range(3):
        for dy in range(3):
            for ext in ("png", "jpg"):
                path = Path(directory) / str(z) / str(x0 + dx) / f"{y0 + dy}.{ext}"
                if path.exists():
                    image.paste(Image.open(path).convert("RGB"), (dx * TILE, dy * TILE))
                    break
    return np.asarray(image).astype(float)


def to_lab(rgb: np.ndarray) -> np.ndarray:
    """sRGB (0-255) -> CIE Lab (D65)."""
    c = rgb / 255.0
    c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    xyz = c @ np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]).T
    xyz /= np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def delta_e(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.linalg.norm(to_lab(a) - to_lab(b)))


def features(table: str, kind: str, expression: str, frame: tuple[float, float, float]) -> list[tuple[str, dict]]:
    left, top, mpp = frame
    right, bottom = left + BLOCK * mpp, top - BLOCK * mpp
    envelope = f"ST_MakeEnvelope({left}, {bottom}, {right}, {top}, 3857)"
    geometry = f"ST_Intersection(geom, ST_Expand({envelope}, {4 * mpp}))" if kind != "point" else "geom"
    rows = psql(
        f"SELECT {expression}, ST_AsGeoJSON({geometry}, 2) FROM {table} "
        f"WHERE geom && {envelope} AND {expression} IS NOT NULL"
    )
    return [(cls, json.loads(geojson)) for cls, geojson in rows]


def to_pixels(coords, frame) -> list[tuple[float, float]]:
    left, top, mpp = frame
    return [((x - left) / mpp, (top - y) / mpp) for x, y, *_ in coords]


def polygon_rings(geometry: dict):
    kind = geometry["type"]
    if kind == "Polygon":
        yield geometry["coordinates"]
    elif kind == "MultiPolygon":
        yield from geometry["coordinates"]
    elif kind == "GeometryCollection":
        for part in geometry["geometries"]:
            yield from polygon_rings(part)


def line_parts(geometry: dict):
    kind = geometry["type"]
    if kind == "LineString":
        yield geometry["coordinates"]
    elif kind == "MultiLineString":
        yield from geometry["coordinates"]
    elif kind == "GeometryCollection":
        for part in geometry["geometries"]:
            yield from line_parts(part)


def sample_mask(kind: str, geometries: list[dict], frame) -> np.ndarray:
    mask = Image.new("1", (BLOCK, BLOCK), 0)
    draw = ImageDraw.Draw(mask)
    if kind == "polygon":
        for geometry in geometries:
            for rings in polygon_rings(geometry):
                if not rings or len(rings[0]) < 3:   # empty/degenerate clip result
                    continue
                draw.polygon(to_pixels(rings[0], frame), fill=1)
                for hole in rings[1:]:
                    if len(hole) >= 3:
                        draw.polygon(to_pixels(hole, frame), fill=0)
        return ndimage.binary_erosion(np.asarray(mask, dtype=bool), iterations=1)
    result = np.zeros((BLOCK, BLOCK), dtype=bool)
    if kind == "line":
        for geometry in geometries:
            for part in line_parts(geometry):
                points = to_pixels(part, frame)
                for (ax, ay), (bx, by) in zip(points, points[1:]):
                    steps = max(1, int(math.hypot(bx - ax, by - ay) * 2))
                    xs = np.round(np.linspace(ax, bx, steps + 1)).astype(int)
                    ys = np.round(np.linspace(ay, by, steps + 1)).astype(int)
                    ok = (xs >= 0) & (xs < BLOCK) & (ys >= 0) & (ys < BLOCK)
                    result[ys[ok], xs[ok]] = True
    else:
        for geometry in geometries:
            if geometry["type"] == "Point":
                x, y = to_pixels([geometry["coordinates"]], frame)[0]
                xi, yi = int(round(x)), int(round(y))
                if 0 <= xi < BLOCK and 0 <= yi < BLOCK:
                    result[yi, xi] = True
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("blocks", type=Path)
    parser.add_argument("--top", type=int, default=40)
    parser.add_argument("--min-pixels", type=int, default=150)
    parser.add_argument("--csv", type=Path)
    args = parser.parse_args()

    pooled: dict[tuple[str, str], dict[str, list[np.ndarray]]] = defaultdict(lambda: defaultdict(list))
    for block in json.loads(args.blocks.read_text()):
        z, x0, y0 = block["z"], block["x0"], block["y0"]
        frame = block_frame(z, x0, y0)
        renders = {
            "qgis": stitch(block["qgis"], z, x0, y0),
            "maplibre": np.asarray(Image.open(block["maplibre"]).convert("RGB")).astype(float),
        }
        if block.get("original"):
            renders["original"] = stitch(block["original"], z, x0, y0)
        valid = np.all(renders["qgis"] != [255, 0, 255], axis=-1)
        if "original" in renders:
            # The original tiles are blank (#ededed) outside their extent.
            valid &= np.any(np.abs(renders["original"] - 237) > 3, axis=-1)
        for table, kind, expression in CLASSES:
            try:
                rows = features(table, kind, expression, frame)
            except subprocess.CalledProcessError as error:
                print(f"skip {table}: {error.stderr.strip()[:120]}", file=sys.stderr)
                continue
            by_class: dict[str, list[dict]] = defaultdict(list)
            for cls, geometry in rows:
                by_class[cls].append(geometry)
            for cls, geometries in by_class.items():
                mask = sample_mask(kind, geometries, frame) & valid
                if mask.any():
                    for name, image in renders.items():
                        pooled[(table, cls)][name].append(image[mask])

    total = sum(np.concatenate(v["qgis"]).shape[0] for v in pooled.values())
    rows = []
    for (table, cls), samples in pooled.items():
        qgis = np.concatenate(samples["qgis"])
        if qgis.shape[0] < args.min_pixels:
            continue
        maplibre = np.concatenate(samples["maplibre"])
        q_med, m_med = np.median(qgis, axis=0), np.median(maplibre, axis=0)
        bias = delta_e(q_med, m_med)
        original = np.concatenate(samples["original"]) if samples.get("original") else None
        o_med = np.median(original, axis=0) if original is not None and len(original) else None
        rows.append({
            "table": table, "class": cls, "pixels": qgis.shape[0],
            "qgis": tuple(int(round(v)) for v in q_med),
            "maplibre": tuple(int(round(v)) for v in m_med),
            "original": tuple(int(round(v)) for v in o_med) if o_med is not None else None,
            "dE_maplibre_qgis": round(bias, 1),
            "dE_qgis_original": round(delta_e(q_med, o_med), 1) if o_med is not None else None,
            "dE_maplibre_original": round(delta_e(m_med, o_med), 1) if o_med is not None else None,
            "impact": round(bias * qgis.shape[0] / total * 100, 2),
        })
    rows.sort(key=lambda row: -row["impact"])
    print(f"{len(rows)} classes, {total} sampled pixels; sorted by impact = dE(MapLibre, QGIS) x pixel share (%)")
    print(f"{'table / class':52s} {'pixels':>7} {'QGIS':>15} {'MapLibre':>15} {'original':>15} {'dE ML-Q':>7} {'dE Q-orig':>9} {'impact':>7}")
    for row in rows[: args.top]:
        print(
            f"{(row['table'] + ' / ' + row['class'])[:52]:52s} {row['pixels']:7d} {str(row['qgis']):>15} "
            f"{str(row['maplibre']):>15} {str(row['original']):>15} {row['dE_maplibre_qgis']:7.1f} "
            f"{'' if row['dE_qgis_original'] is None else row['dE_qgis_original']:>9} {row['impact']:7.2f}"
        )
    if args.csv:
        with args.csv.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(f"wrote {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
