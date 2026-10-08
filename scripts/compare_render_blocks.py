#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow", "numpy"]
# ///
"""Compare a QGIS raster tile block with a MapLibre capture of the same block.

    ./scripts/compare_render_blocks.py QGIS_TILE_DIR Z X0 Y0 NX NY MAPLIBRE.png OUT_PREFIX

QGIS_TILE_DIR holds {z}/{x}/{y}.png or .jpg (render_tiles.sh output, or the original
https://tiles.osm-berlin.org/strassenraumkarte tiles).
MAPLIBRE.png comes from scripts/capture_maplibre_block.js for the same block.
Writes OUT_PREFIX_side_by_side.png, OUT_PREFIX_diff.png and prints per-tile
and overall difference metrics. Metrics are descriptive, not a pass/fail
parity verdict: look at the images.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

TILE = 256
THRESHOLD = 12  # max per-channel difference counted as "visibly different"


def stitch(tile_dir: Path, z: int, x0: int, y0: int, nx: int, ny: int) -> Image.Image:
    out = Image.new("RGB", (nx * TILE, ny * TILE), (255, 0, 255))  # magenta = missing tile
    for dx in range(nx):
        for dy in range(ny):
            path = next((tile_dir / str(z) / str(x0 + dx) / f"{y0 + dy}.{ext}"
                         for ext in ("png", "jpg") if (tile_dir / str(z) / str(x0 + dx) / f"{y0 + dy}.{ext}").exists()),
                        tile_dir / str(z) / str(x0 + dx) / f"{y0 + dy}.png")
            if path.exists():
                out.paste(Image.open(path).convert("RGB"), (dx * TILE, dy * TILE))
            else:
                print(f"missing QGIS tile: {path}", file=sys.stderr)
    return out


def main() -> int:
    if len(sys.argv) != 9:
        print(__doc__)
        return 2
    tile_dir, z, x0, y0, nx, ny, ml_path, prefix = sys.argv[1:]
    z, x0, y0, nx, ny = map(int, (z, x0, y0, nx, ny))
    qgis = stitch(Path(tile_dir), z, x0, y0, nx, ny)
    ml = Image.open(ml_path).convert("RGB")
    if ml.size != qgis.size:
        print(f"SIZE MISMATCH: qgis {qgis.size} vs maplibre {ml.size}", file=sys.stderr)
        return 1

    a = np.asarray(qgis).astype(int)
    b = np.asarray(ml).astype(int)
    delta = np.abs(a - b).max(axis=2)
    differs = delta > THRESHOLD

    side = Image.new("RGB", (qgis.width * 2 + 8, qgis.height), (255, 255, 255))
    side.paste(qgis, (0, 0))
    side.paste(ml, (qgis.width + 8, 0))
    side.save(f"{prefix}_side_by_side.png")
    Image.fromarray(np.clip(delta * 4, 0, 255).astype(np.uint8)).save(f"{prefix}_diff.png")

    print(f"{'tile':>16} {'mean|d|':>8} {'%>thr':>7}")
    for dx in range(nx):
        for dy in range(ny):
            sl = (slice(dy * TILE, (dy + 1) * TILE), slice(dx * TILE, (dx + 1) * TILE))
            print(f"{z}/{x0 + dx}/{y0 + dy:<6} {delta[sl].mean():8.2f} {100 * differs[sl].mean():7.1f}")
    print(f"{'overall':>16} {delta.mean():8.2f} {100 * differs.mean():7.1f}  (threshold {THRESHOLD}/255)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
