#!/bin/bash
#
# Usage:
#   ./serve_mvt.sh [--config path] [--listen host:port]
#
# Runs Martin (https://martin.maplibre.org) as a local MVT tile server for
# the MapLibre port, serving the tables listed in render/mvt/martin-config.yaml.
# Vector-tile counterpart to render/preview_server.py's raster preview.
#
# TileJSON for a source: http://<listen>/<source_name>
# A single tile:          http://<listen>/<source_name>/{z}/{x}/{y}
#
# Requires: martin (brew install martin). Uses the same DB connection
# defaults as the rest of the pipeline (data/db_config.sh).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../data/db_config.sh
source "$REPO_ROOT/data/db_config.sh"

CONFIG="$SCRIPT_DIR/mvt/martin-config.yaml"
LISTEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ -z "${2:-}" || "$2" == --* ]] && { echo "--config requires a path" >&2; exit 1; }
      CONFIG="$2"
      shift 2
      ;;
    --listen)
      [[ -z "${2:-}" || "$2" == --* ]] && { echo "--listen requires host:port" >&2; exit 1; }
      LISTEN="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--config path] [--listen host:port]"
      exit 0
      ;;
    *)
      echo "Unknown parameter: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v martin >/dev/null 2>&1; then
  echo "Missing command 'martin'. Install with: brew install martin" >&2
  exit 1
fi

# martin --config disallows also passing a connection string on the CLI, so
# the only way to honour DB_HOST/DB_PORT/DB_USER/DB_NAME overrides (the same
# ones every other pipeline script respects) is to substitute them into a
# disposable copy of the config before handing it to martin.
CONN_STRING="postgres://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
TMP_CONFIG=$(mktemp "${TMPDIR:-/tmp}/martin-config.XXXXXX")
trap 'rm -f "$TMP_CONFIG"' EXIT
sed -E "s#^([[:space:]]*connection_string:).*#\1 ${CONN_STRING}#" "$CONFIG" > "$TMP_CONFIG"

ARGS=(--config "$TMP_CONFIG")
if [[ -n "$LISTEN" ]]; then
  ARGS+=(--listen-addresses "$LISTEN")
  # Keep web/style.json's baked-in tile URLs pointed at wherever martin is
  # actually about to bind, rather than leaving them at the default.
  python3 "$REPO_ROOT/scripts/set_maplibre_tile_base.py" --base-url "http://$LISTEN"
fi

echo "Starting Martin (config: $CONFIG, DB: ${DB_HOST}:${DB_PORT}/${DB_NAME})..."
exec martin "${ARGS[@]}"
