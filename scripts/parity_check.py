#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow", "numpy", "scipy"]
# ///
"""Six-block MapLibre-vs-QGIS parity check with same-session A/B support.

    ./scripts/parity_check.py --tag mychange [--baseline runs/base/classes.csv]
                              [--paint '{"layer-id": {"fill-opacity": 0.5}}'] [--hide 'tree-*']

What it does (all in one process, one environment, which is what makes before/after
comparable; numbers from different sessions drift by ~0.03 in the mean):

1. makes sure the reference tiles exist under ``--ref-dir`` (default render/parity-reference,
   git-ignored): QGIS renders of the six blocks (render_tiles.sh, advanced effects, retried once
   because QGIS 4.2.1 intermittently fails a metatile) and the original tiles
   (tiles.osm-berlin.org, fetched politely and cached);
2. captures each block with capture_maplibre_block.js, optionally with ``--paint`` / ``--hide``
   overrides (experiments without touching web/style.json) or ``--base`` (another server, e.g. a
   copy of a committed style for A/B);
3. runs compare_feature_classes.py and prints the pixel-weighted mean dE to QGIS and to the
   original, the share of pixels at or below dE 2.3 and the classes above dE 5; with
   ``--baseline`` also every class whose dE moved by 0.5 or more.

Prerequisites: PostGIS with the pipeline data, Martin on :3000, ``web/`` served on :8080 (or
``--base``), QGIS bundle for render_tiles.sh (only when reference tiles are missing).
The blocks: Werbellinstr. z17, Hermannplatz z15-z18, Karl-Marx-Str./bridges z17.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UA = "strassenraumkarte-parity-check (local dev)"
# (name, z, x0, y0): 3x3 tiles each
BLOCKS = (
    ("werbellinstr", 17, 70425, 43010),
    ("hermannplatz15", 15, 17604, 10750),
    ("hermannplatz16", 16, 35210, 21501),
    ("hermannplatz17", 17, 70422, 43004),
    ("hermannplatz18", 18, 140846, 86010),
    ("bridges", 17, 70441, 43017),
)


def extra_blocks(zooms: list[int]) -> tuple[tuple[str, int, int, int], ...]:
    """Blocks at other zooms, centred on the middle of the three z17 areas."""
    result = []
    for name, z, x0, y0 in (BLOCKS[0], BLOCKS[3], BLOCKS[5]):
        lon, lat = tile_lonlat(z, x0 + 1.5, y0 + 1.5)
        for zoom in zooms:
            n = 2**zoom
            x = (lon + 180) / 360 * n
            y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
            result.append((f"{name}-z{zoom}", zoom, int(x - 1.5 + 0.5), int(y - 1.5 + 0.5)))
    return tuple(result)


def tile_lonlat(z: int, x: float, y: float) -> tuple[float, float]:
    n = 2**z
    return x / n * 360 - 180, math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))


def block_bbox(z: int, x0: int, y0: int) -> str:
    west, north = tile_lonlat(z, x0, y0)
    east, south = tile_lonlat(z, x0 + 3, y0 + 3)
    # a margin keeps the metatile renderer from dropping edge tiles
    return f"{west + 1e-5:.6f},{south + 1e-5:.6f},{east - 1e-5:.6f},{north - 1e-5:.6f}"


def ensure_qgis(ref: Path) -> list[str]:
    """Render missing reference blocks; return the names of extra-zoom blocks that failed."""
    failed = []
    for name, z, x0, y0 in BLOCKS:
        # one output directory per block: render_tiles.sh refuses to mix configurations
        # (the project's @mercator_scale depends on the block's latitude)
        tiles = [ref / "qgis" / name / str(z) / str(x0 + i) / f"{y0 + j}.png" for i in range(3) for j in range(3)]
        if all(t.exists() for t in tiles):
            continue
        print(f"rendering QGIS reference for {name} (z{z})", flush=True)
        for attempt in (1, 2):
            command = [
                str(ROOT / "render" / "render_tiles.sh"), "--bbox", block_bbox(z, x0, y0),
                "--zmin", str(z), "--zmax", str(z), "--format", "png", "--advanced-effects",
                "--out", str(ref / "qgis" / name),
            ] + (["--resume"] if attempt == 2 else [])
            result = subprocess.run(command, capture_output=True, text=True)
            if all(t.exists() for t in tiles):
                break
            print(f"  attempt {attempt} did not produce all tiles", flush=True)
        else:
            if "-z" not in name:
                sys.exit(f"could not render the QGIS reference for {name}; see render_tiles.sh output")
            print(f"  skipping {name}: QGIS 4.2.1 fails this metatile (QPainter engine == 0)", flush=True)
            failed.append(name)
    return failed


def ensure_original(ref: Path) -> None:
    for _name, z, x0, y0 in BLOCKS:
        for i in range(3):
            for j in range(3):
                path = ref / "original" / str(z) / str(x0 + i) / f"{y0 + j}.jpg"
                if path.exists():
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                url = f"https://tiles.osm-berlin.org/strassenraumkarte/{z}/{x0 + i}/{y0 + j}.jpg"
                try:
                    request = urllib.request.Request(url, headers={"User-Agent": UA})
                    path.write_bytes(urllib.request.urlopen(request, timeout=30).read())
                except Exception as error:  # noqa: BLE001 - blank tiles outside the original's extent are fine
                    print(f"  original {z}/{x0 + i}/{y0 + j} unavailable: {error}", flush=True)
                time.sleep(0.2)


def capture(out: Path, args: argparse.Namespace) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for name, z, x0, y0 in BLOCKS:
        command = ["node", str(ROOT / "scripts" / "capture_maplibre_block.js"), str(z), str(x0), str(y0),
                   "3", "3", str(out / f"{name}.png"), "--paint", args.paint]
        if args.hide:
            command += ["--hide", args.hide]
        if args.base:
            command += ["--base", args.base]
        result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
        if result.returncode:
            sys.exit(f"capture of {name} failed:\n{result.stdout}{result.stderr}")


def read_classes(path: Path) -> dict[tuple[str, str], dict[str, str]]:
    return {(r["table"], r["class"]): r for r in csv.DictReader(path.open())}


def summarize(rows: dict[tuple[str, str], dict[str, str]], baseline: dict | None) -> None:
    total = sum(int(r["pixels"]) for r in rows.values())

    def mean(rows_: dict, key: str) -> float:
        n = sum(int(r["pixels"]) for r in rows_.values())
        return sum(float(r[key]) * int(r["pixels"]) for r in rows_.values() if r[key]) / n

    q = mean(rows, "dE_maplibre_qgis")
    o = mean(rows, "dE_maplibre_original")
    share = sum(int(r["pixels"]) for r in rows.values() if float(r["dE_maplibre_qgis"]) <= 2.3) / total
    big = sorted((r for r in rows.values() if int(r["pixels"]) >= 500 and float(r["dE_maplibre_qgis"]) > 5),
                 key=lambda r: -float(r["dE_maplibre_qgis"]))
    line = f"{len(rows)} classes, {total} px | mean dE to QGIS {q:.3f}, to original {o:.3f} | {share:.1%} of px <= dE 2.3"
    if baseline:
        line += f" | baseline {mean(baseline, 'dE_maplibre_qgis'):.3f} / {mean(baseline, 'dE_maplibre_original'):.3f}"
    print(line)
    print(f"classes with >= 500 px above dE 5 to QGIS: {len(big)}")
    for r in big:
        print(f"  {r['table']}/{r['class']:32s} to QGIS {r['dE_maplibre_qgis']:>5}   to original {r['dE_maplibre_original']:>5}"
              f"   (QGIS vs original {r['dE_qgis_original']})")
    if baseline:
        moved = []
        for key, r in rows.items():
            b = baseline.get(key)
            if b and abs(float(r["dE_maplibre_qgis"]) - float(b["dE_maplibre_qgis"])) >= 0.5 and int(r["pixels"]) >= 300:
                moved.append((float(r["dE_maplibre_qgis"]) - float(b["dE_maplibre_qgis"]), key, b, r))
        print("classes whose dE to QGIS moved by 0.5 or more (300+ px):")
        for delta, (table, cls), b, r in sorted(moved):
            print(f"  {delta:+5.1f} {table}/{cls:32s} {b['dE_maplibre_qgis']:>5} -> {r['dE_maplibre_qgis']:>5}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", required=True, help="run name; results go to --runs-dir/<tag>")
    parser.add_argument("--ref-dir", type=Path, default=ROOT / "render" / "parity-reference")
    parser.add_argument("--runs-dir", type=Path, default=ROOT / "render" / "parity-runs")
    parser.add_argument("--baseline", type=Path, help="classes.csv of an earlier run to compare with")
    parser.add_argument("--paint", default="{}", help="JSON of paint overrides per layer id")
    parser.add_argument("--hide", default="", help="comma-separated layer ids to hide (trailing * = prefix)")
    parser.add_argument("--zooms", default="", help="extra zooms, e.g. 19,20: blocks at the centres of three areas")
    parser.add_argument("--base", default="", help="serve the style from another URL (A/B of a committed copy)")
    args = parser.parse_args()

    global BLOCKS
    if args.zooms:
        BLOCKS = BLOCKS + extra_blocks([int(z) for z in args.zooms.split(",")])
    failed = ensure_qgis(args.ref_dir)
    BLOCKS = tuple(block for block in BLOCKS if block[0] not in failed)
    ensure_original(args.ref_dir)
    out = args.runs_dir / args.tag
    capture(out, args)
    blocks = [
        {"z": z, "x0": x0, "y0": y0, "qgis": str(args.ref_dir / "qgis" / name),
         "maplibre": str(out / f"{name}.png"), "original": str(args.ref_dir / "original")}
        for name, z, x0, y0 in BLOCKS
    ]
    (out / "blocks.json").write_text(json.dumps(blocks, indent=1))
    csv_path = out / "classes.csv"
    result = subprocess.run(
        [str(ROOT / "scripts" / "compare_feature_classes.py"), str(out / "blocks.json"),
         "--top", "400", "--csv", str(csv_path)], capture_output=True, text=True)
    if result.returncode or not csv_path.exists():
        sys.exit(f"comparison failed:\n{result.stdout}{result.stderr}")
    (out / "classes.txt").write_text(result.stdout)
    summarize(read_classes(csv_path), read_classes(args.baseline) if args.baseline else None)
    print(f"results in {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
