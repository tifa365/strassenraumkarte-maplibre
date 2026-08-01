# Shared PostgreSQL connection defaults for Straßenraumkarte scripts.
# Override via environment variables if needed.

DB_NAME="${DB_NAME:-strassenraumkarte}"
DB_USER="${DB_USER:-postgres}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5433}"

# Project CRS (EPSG code) for osm2pgsql import / PostGIS storage.
# Must match the QGIS project CRS (default: 3857 = WGS 84 / Pseudo-Mercator).
CRS="${CRS:-3857}"

# https://www.postgresql.org/docs/current/libpq-pgpass.html
export PGPASSFILE="${PGPASSFILE:-$HOME/.pgpass}"

# QGIS project datasources often omit user=; libpq then uses PGUSER for headless rendering.
export PGUSER="${PGUSER:-$DB_USER}"

# Exported so osm2pgsql Lua (osm_import.lua) and helper scripts can read it.
export CRS

psql_base() {
  psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" "$@"
}
