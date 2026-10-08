# Repository Guidelines

## Project Structure & Module Organization

Straßenraumkarte processes OpenStreetMap data through osm2pgsql/Lua, PostGIS SQL, and QGIS/PyQGIS to produce street-space maps.

- `data/lua/`: OSM import definitions and lane derivation.
- `data/processing/sql/`: geometry processing; `helper/` contains reusable functions and `params/` shared tunables. Preserve the dependency order in `data/data_preparation.sh`.
- `style/`: QGIS project (`strassenraumkarte.qgz`), symbols, and textures.
- `render/`: tile rendering, local preview server, and Martin configuration; generated raster tiles go in `render/tiles/`.
- `web/`: MapLibre preview, style JSON, and sprites.
- `scripts/`: MapLibre generators and validation audits. `docs/` explains architecture and parity limitations.

## Build, Test, and Development Commands

Run commands from the repository root. Install PostgreSQL/PostGIS, osm2pgsql, and QGIS with Python bindings; Martin is needed for vector previews.

- `./run.sh --check`: verify tools and database connectivity.
- `./run.sh --setup-db`: create the database and enable PostGIS.
- `./run.sh --data data/osm/berlin-latest.osm.pbf --bbox 13.439498,52.472155,13.449776,52.475932 --zmax 19`: process and render a small extract.
- `./render/render_tiles.sh --zmin 16 --zmax 19`: render existing database contents.
- `./render/preview_server.py`: serve the raster preview at `http://127.0.0.1:8000/preview.html`.
- `./render/serve_mvt.sh` and, in another terminal, `python3 -m http.server 8080 --directory web`: launch the vector preview.
- `./data/load_parking_cars.sh`: load the street-parking car points (`data/parking/street_parking_points_processed.geojson`) into `public.parking_cars` for the MapLibre car layer (several minutes; needs `ogr2ogr`).
- `QGIS_APP=/Applications/QGIS-final-4_2_1.app ./render/render_tiles.sh ...`: pin the QGIS bundle when several are installed.
- `node scripts/capture_maplibre_block.js --check-only`: load `web/style.json` in a real headless MapLibre and exit 1 on any style or tile error. Run this first after any style change; the audits cannot tell whether MapLibre accepts the style.
- `node scripts/capture_maplibre_block.js Z X0 Y0 NX NY out.png` and `./scripts/compare_render_blocks.py <tile dir> Z X0 Y0 NX NY out.png prefix`: capture the MapLibre preview for a tile block and compare it with QGIS or the original tiles (`https://tiles.osm-berlin.org/strassenraumkarte/{z}/{x}/{y}.jpg`). Look at the side-by-side image; the audits alone do not prove the preview renders.
- `./scripts/compare_feature_classes.py blocks.json`: rank every table/class (landuse class, highway class, barrier type, ...) by how differently QGIS and MapLibre colour it, over several comparison blocks (QGIS tiles + MapLibre capture + optional original tiles per block). Start parity work from the top of this list.
- `python3 scripts/build_maplibre_strata.py` / `python3 scripts/shift_style_zoom.py --to maplibre`: regenerate the bridge/tunnel strata; the style is stored in the MapLibre zoom convention (see `docs/MAPLIBRE_PARITY.md`, "Zoom convention").

## Coding Style & Naming Conventions

Match surrounding formatting; use four-space Python indentation, descriptive `snake_case` identifiers, and uppercase SQL keywords. Preserve SQL filename families such as `lanes_*` and `road_marking_*`. No repository-wide formatter or linter is configured. Edit QGIS styling through QGIS or the supplied scripts.

## Testing Guidelines

There is no conventional unit-test framework or coverage threshold. Run applicable audits:

```bash
python3 scripts/audit_maplibre_parity.py
python3 scripts/audit_road_markings.py
python3 scripts/audit_surface_textures.py
```

The latter two require populated PostGIS tables. Validate pipeline changes on a small bounding box, inspect resulting tables, and compare rendered tiles. Full MapLibre parity remains incomplete; consult `docs/MAPLIBRE_PARITY.md`.

## Commit & Pull Request Guidelines

The short Git history uses concise, descriptive subjects, such as “Add licence notes, example map image, and README context.” Follow that style. Include the change’s purpose, validation commands, affected extent/zooms, linked issues when applicable, and before/after screenshots for visual changes.

## Configuration & Data Safety

Override `data/db_config.sh` defaults through environment variables; keep credentials in `~/.pgpass`. Maintain EPSG:3857 consistently. `--refresh` drops and recreates the schema. Keep downloaded PBFs, generated tiles, credentials, and temporary QGIS databases out of commits.
