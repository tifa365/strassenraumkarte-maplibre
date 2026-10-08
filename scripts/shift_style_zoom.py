#!/usr/bin/env python3
"""Convert web/style.json between zoom conventions (see zoom_convention.py).

    python3 scripts/shift_style_zoom.py --to maplibre   # raster-256 -> maplibre-512 (once)
    python3 scripts/shift_style_zoom.py --to raster     # inverse, for inspection

The file records its convention in metadata, so converting to the convention
it is already in is a no-op.
"""

import argparse
import json
from pathlib import Path

import zoom_convention as zc

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--style", type=Path, default=ROOT / "web" / "style.json")
    parser.add_argument("--to", choices=("maplibre", "raster"), required=True)
    args = parser.parse_args()
    target = zc.MAPLIBRE if args.to == "maplibre" else zc.RASTER
    style = json.loads(args.style.read_text())
    if zc.convention_of(style) == target and zc.CONVENTION_KEY in style.get("metadata", {}):
        print(f"{args.style.name} is already {target}; nothing to do")
        return
    args.style.write_text(json.dumps(zc.convert_style(style, target), indent=2) + "\n")
    print(f"converted {args.style.name}: {zc.convention_of(style)} -> {target}")


if __name__ == "__main__":
    main()
