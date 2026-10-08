#!/usr/bin/env python3
"""Audit an existing XYZ tile tree without modifying it.

The renderer's manifest-backed generation is the source of truth for new work.
This tool inventories older trees so they can be retained as rollback material
while corrupt or incomplete metatiles are selected for replacement.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
from pathlib import Path


def image_dimensions(path: Path) -> tuple[int, int] | None:
    with path.open("rb") as fh:
        header = fh.read(32)
        if header.startswith(b"\x89PNG\r\n\x1a\n") and len(header) >= 24:
            return struct.unpack(">II", header[16:24])
        if not header.startswith(b"\xff\xd8"):
            return None
        fh.seek(2)
        while True:
            marker = fh.read(2)
            if len(marker) != 2:
                return None
            while marker[0] != 0xFF:
                marker = marker[1:] + fh.read(1)
                if len(marker) != 2:
                    return None
            kind = marker[1]
            if kind in {0xD8, 0xD9}:
                continue
            length_bytes = fh.read(2)
            if len(length_bytes) != 2:
                return None
            length = struct.unpack(">H", length_bytes)[0]
            if kind in set(range(0xC0, 0xC4)) - {0xC4}:
                data = fh.read(5)
                if len(data) != 5:
                    return None
                height, width = struct.unpack(">HH", data[1:5])
                return width, height
            fh.seek(length - 2, os.SEEK_CUR)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    root = args.directory.resolve()
    results = {"directory": str(root), "valid": 0, "invalid": [], "by_zoom": {}}
    for path in sorted(root.glob("*/*/*.*")):
        if path.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
            continue
        dimensions = image_dimensions(path)
        zoom = path.relative_to(root).parts[0]
        results["by_zoom"][zoom] = results["by_zoom"].get(zoom, 0) + 1
        if dimensions == (256, 256) and path.stat().st_size > 0:
            results["valid"] += 1
        else:
            results["invalid"].append({"path": str(path.relative_to(root)), "dimensions": dimensions, "bytes": path.stat().st_size})
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"audited {results['valid'] + len(results['invalid'])} tiles: {results['valid']} structurally valid, {len(results['invalid'])} invalid")
    return 1 if results["invalid"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
