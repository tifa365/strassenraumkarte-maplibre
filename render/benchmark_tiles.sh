#!/bin/bash
# Controlled one-metatile benchmark. Outputs are independent generations.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
METATILE="${1:-17:70536:43016}"
OUT_ROOT="${2:-$ROOT/render/benchmarks/$(date +%Y%m%d-%H%M%S)}"
BBOX="${BBOX:-13.0539063,52.329403499095,13.764543,52.68178599908448}"
mkdir -p "$OUT_ROOT"

run_case() {
  local name="$1"
  shift
  set +e
  "$ROOT/render/render_tiles.sh" --bbox "$BBOX" --zmin 17 --zmax 17 --metatile 8 --gutter 1 \
    --only-metatile "$METATILE" --worker-metatiles 0 --out "$OUT_ROOT/$name" "$@"
  local status=$?
  set -e
  echo "$status" > "$OUT_ROOT/$name.exit-status"
}

run_case trees-only --tree-mode only
run_case full-effects-off --tree-mode full
run_case full-effects-on --tree-mode full --advanced-effects
run_case without-trees --tree-mode off

python3 - "$OUT_ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
rows = []
for directory in sorted(root.iterdir()):
    if not directory.is_dir():
        continue
    records = directory / '.render-completions.jsonl'
    status = int((root / f'{directory.name}.exit-status').read_text())
    row = {'case': directory.name, 'exit_status': status}
    if records.exists():
        record = json.loads(records.read_text().splitlines()[-1])
        row.update({'render_seconds': record.get('render_seconds'), 'rss_mb': record.get('rss_mb'), 'diagnostics': record.get('diagnostics', [])})
    rows.append(row)
(root / 'benchmark-summary.json').write_text(json.dumps(rows, indent=2) + '\n')
print(json.dumps(rows, indent=2))
raise SystemExit(1 if any(row['exit_status'] for row in rows) else 0)
PY
