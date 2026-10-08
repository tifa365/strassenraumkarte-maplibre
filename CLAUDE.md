# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Straßenraumkarte ("Street Space Map") is a QGIS map style plus data pipeline that renders detailed street-space maps (carriageway surfaces, lane markings, parking, street furniture, buildings, land use) from OpenStreetMap data. Pipeline: **osm2pgsql/Lua import → PostGIS/SQL processing → QGIS styling → PyQGIS XYZ tile rendering**. Originally built for Berlin-Neukölln but works for any place. See `README.md` for the full requirements/usage reference (tools, options tables, CRS discussion) — this file only covers what the README doesn't.

## Commands

```bash
# Full pipeline: import + SQL processing + tile rendering
./run.sh --data <geofabrik-url-or-local.osm.pbf> [--bbox xmin,ymin,xmax,ymax] [--refresh]

# Verify tools + DB connectivity only
./run.sh --check

# Create DB + enable PostGIS
./run.sh --setup-db

# Data preparation only (import + SQL processing, no rendering)
./data/data_preparation.sh --data <url|path> [--bbox ...] [--refresh]

# Rendering only (uses existing DB contents)
./render/render_tiles.sh [--bbox ...] [--zmin N] [--zmax N]

# Interactive preview UI (serves tiles, lists local PBFs, can kick off ./run.sh)
./render/preview_server.py
# then open http://127.0.0.1:8000/preview.html
```

There is no test suite, linter, or build step — this is a shell/SQL/Lua/Python data pipeline plus a QGIS project file. Validate changes by running the pipeline against a small `--bbox` extract and checking rendered tiles (or the preview server) and/or inspecting resulting PostGIS tables with `psql`.

Database defaults live in `data/db_config.sh` (`DB_NAME=strassenraumkarte`, `DB_USER=postgres`, `DB_HOST=localhost`, `DB_PORT=5433`, `CRS=3857`), overridable via env vars or `--crs`/`--bbox`/etc. flags. Every shell script in the pipeline sources this file for a shared `psql_base()` wrapper.

## Architecture

**Import (`data/lua/`):** `osm2pgsql` runs in flex output mode driven by `osm_import.lua` (raw OSM → PostGIS tables) and `lanes.lua` (derives per-lane geometry from `highway`/lane tags — this is where most lane-splitting logic lives, not SQL). Both read the `CRS` env var directly via `os.getenv`.

**SQL processing (`data/processing/sql/`):** `data_preparation.sh` runs ~30 SQL scripts in a fixed, dependency-ordered sequence (the order is spelled out with inline `# Dependency:` comments in the script — do not reorder without checking these). Each script is executed via `psql -v ON_ERROR_STOP=1` with `crs` and `bbox_mid_lat` passed in as psql variables. Shared tunables live in `processing/sql/params/params.sql` (`\i`-included by scripts that need them; organized by pipeline section — lanes, road markings, highway areas, trees/buildings). Reusable SQL functions live in `processing/sql/helper/` (notably `metres.sql` for ground-metre↔map-unit conversion and `line_offset.sql` for lane offsetting). Broad script families: `highway_*` (carriageway/area geometry from centerlines), `lanes_*` (per-lane splitting/offsetting/connectivity), `road_marking_*` (crossings, arrows, stop lines, parking, colour fills), plus standalone scripts for buildings, trees, water, bridges, and label geometry generation.

**CRS handling:** EPSG:3857 (Web Mercator) is the CRS used throughout (import, storage, QGIS project, rendering) and normally should not be changed — see the README's "Rendering + CRS" section for the full explanation of `@mercator_scale` / `metres()` and what breaks if you override it without also updating the `.qgz` project.

**Rendering (`render/`):** `xyz_tiles.py` is a custom PyQGIS metatile loop (not `qgis_process`) invoked by `render_tiles.sh`. It renders directly in EPSG:3857, tiling with a configurable metatile core + gutter (gutter tiles are rendered for correct label/symbol crossing then discarded). `project_extent.py` computes the render extent from the QGIS project's combined layer extent when no `--bbox` is given. `preview_server.py` is a small stdlib HTTP server (no framework) that serves `render/tiles/`, lists local PBFs under `data/osm/`, and can launch `./run.sh` from the browser UI at `render/tiles/preview.html`.

**Styling (`style/`):** `strassenraumkarte.qgz` is the QGIS project holding all layer styling — this is binary/XML-in-zip and generally not hand-edited directly. `update_highway_layered.py` is a one-off script that regenerates the "highway (layered)" QGIS layer group from the "highway (unlayered)" template by injecting SQL `layer=` filters per bridge/tunnel layer level — run it after restyling the unlayered highway layer to propagate changes to the layered variants. `symbols/` and `textures/` hold the SVG/PNG assets referenced by the QGIS style (organized by OSM tag category: `amenity`, `highway`, `parking`, `traffic_signs`, etc.).

## Licensing note

Source code (Shell/Lua/SQL/Python, QGIS project, style assets) is Apache-2.0. Imported OSM data and anything derived from it is ODbL — keep these separate in mind when adding new data-derived artifacts (see `LICENSE.md`).
