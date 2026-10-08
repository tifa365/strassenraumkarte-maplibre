#!/bin/bash
#
# Usage:
#   ./data/load_parking_cars.sh [path/to/street_parking_points_processed.geojson]
#
# Loads the car points that the QGIS "parking cars" layer draws (the processed
# street-parking GeoJSON from data/build_parking.sh) into public.parking_cars,
# then derives the sprite name and rotation for the MapLibre port
# (processing/sql/web/web_parking_cars.sql). Re-running replaces the table.
# The GeoJSON is large (~1 GB for Berlin); expect several minutes.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=db_config.sh
source "$ROOT/data/db_config.sh"

SRC="${1:-$ROOT/data/parking/street_parking_points_processed.geojson}"
[[ -f "$SRC" ]] || { echo "GeoJSON not found: $SRC" >&2; exit 1; }
LAYER=$(basename "$SRC" .geojson)

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Importing $SRC -> $DB_NAME.public.parking_cars"
ogr2ogr -f PostgreSQL "PG:host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER" \
  "$SRC" -overwrite -nln parking_cars -t_srs "EPSG:$CRS" \
  -lco GEOMETRY_NAME=geom -lco FID=gid -lco SPATIAL_INDEX=GIST \
  -dialect OGRSQL -sql "SELECT space_id, angle AS angle_deg, orientation, side, \"highway:oneway\" AS oneway, \"@colour\" AS colour, \"@modell\" AS model FROM $LAYER"

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Deriving icon names and rotation..."
psql_base -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$ROOT/data/processing/sql/web/web_parking_cars.sql"
psql_base -d "$DB_NAME" -c "ANALYZE parking_cars"
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Done."
