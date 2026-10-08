#!/usr/bin/env python3
"""Rewrite web/style.json's vector-tile source URLs to a different martin base URL.

serve_mvt.sh's --listen flag changes where martin actually binds, but
web/style.json bakes in the base URL (default http://127.0.0.1:3000) at
generation time and is never updated to match. Run this after starting
martin on a non-default address so the style keeps pointing at it:

  ./render/serve_mvt.sh --listen 127.0.0.1:4000
  python3 scripts/set_maplibre_tile_base.py --base-url http://127.0.0.1:4000
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_STYLE = ROOT / "web" / "style.json"
DEFAULT_BASE_URL = "http://127.0.0.1:3000"
_ORIGIN_RE = re.compile(r"^https?://[^/]+")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--style", type=Path, default=DEFAULT_STYLE, help="Path to style.json (default: web/style.json)")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="New tile server origin, e.g. http://127.0.0.1:4000")
    args = parser.parse_args()

    style = json.loads(args.style.read_text(encoding="utf-8"))
    changed = 0
    for name, source in style.get("sources", {}).items():
        for i, url in enumerate(source.get("tiles", [])):
            new_url = _ORIGIN_RE.sub(args.base_url, url, count=1)
            if new_url != url:
                source["tiles"][i] = new_url
                changed += 1

    args.style.write_text(json.dumps(style, indent=2) + "\n")
    print(f"Rewrote {changed} tile URL(s) in {args.style} to base {args.base_url}")


if __name__ == "__main__":
    main()
