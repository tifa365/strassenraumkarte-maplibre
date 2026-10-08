#!/usr/bin/env python3
"""Check the QGIS-rendered marker sprites against the database and the sprite atlas.

Every ``feature_node.symbol_name`` that names a marker (``marker_sprites.MARKERS``) must
exist in both sprite atlases at 64 logical px, and ``symbol_size_m`` must equal the
marker's ground-metre box (web_symbol_names.sql keeps a copy of those numbers).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import marker_sprites  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DB = ["psql", "--no-psqlrc", "-XAt", "-h", os.environ.get("DB_HOST", "localhost"),
      "-p", os.environ.get("DB_PORT", "5433"), "-U", os.environ.get("DB_USER", "postgres"),
      "-d", os.environ.get("DB_NAME", "strassenraumkarte")]

boxes = {m.name: m.box for m in marker_sprites.MARKERS}
errors: list[str] = []
rows = subprocess.run(
    DB + ["-c", "select symbol_name, symbol_size_m::numeric(8,3), count(*) from feature_node "
                "where symbol_name = any(string_to_array(%r, ',')) group by 1, 2" % ",".join(boxes)],
    capture_output=True, text=True, check=True).stdout.split()
used: dict[str, int] = {}
for row in rows:
    name, size, count = row.split("|")
    used[name] = used.get(name, 0) + int(count)
    if abs(float(size) - boxes[name]) > 1e-3:
        errors.append(f"{name}: symbol_size_m {size} != marker box {boxes[name]}")
for atlas in ("sprite.json", "sprite@2x.json"):
    sprite = json.loads((ROOT / "web" / atlas).read_text())
    ratio = 2 if "@2x" in atlas else 1
    for name in boxes:
        entry = sprite.get(name)
        if entry is None:
            errors.append(f"{atlas}: sprite {name!r} missing")
        elif entry["width"] != 64 * ratio or entry["height"] != 64 * ratio:
            errors.append(f"{atlas}: {name} is {entry['width']}x{entry['height']}, expected {64 * ratio}")
unused = sorted(set(boxes) - set(used))
if unused:
    # normal for a small --bbox extract; on Berlin every marker is used
    print(f"NOTE: no feature in this database uses: {', '.join(unused)}")
if errors:
    raise SystemExit("FAIL:\n  " + "\n  ".join(errors))
print(f"PASS: {len(boxes)} marker sprites exist at 64 logical px; {sum(used.values())} features use them with the right size")
