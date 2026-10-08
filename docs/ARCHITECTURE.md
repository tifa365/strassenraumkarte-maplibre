# Architecture

A deep technical walkthrough of how the Straßenraumkarte pipeline turns raw OSM
data into rendered street-space tiles. `README.md` covers *usage* (commands,
options); `CLAUDE.md` gives a terse orientation for coding agents; this
document explains the *design and algorithms* — for when you need to modify
or debug the pipeline itself, not just run it.

The pipeline has four stages, run in this order:

1. **Import** — `osm2pgsql` (flex output) driven by `data/lua/osm_import.lua`
   and `data/lua/lanes.lua` turns raw OSM elements into PostGIS tables,
   including per-lane geometry.
2. **SQL processing** — ~30 scripts in `data/processing/sql/`, run in a fixed
   dependency order by `data/data_preparation.sh`, turn those raw tables into
   render-ready geometry (carriageway areas, road markings, labels, etc.).
3. **Styling** — `style/strassenraumkarte.qgz`, a QGIS project mapping those
   tables to symbology. `style/update_highway_layered.py` mechanically
   generates repeated layer-group copies for bridge/tunnel layering.
4. **Rendering** — `render/xyz_tiles.py`, a custom PyQGIS metatile loop
   invoked by `render/render_tiles.sh`, rasterizes the QGIS project to XYZ
   tiles. `render/preview_server.py` is a local control UI on top of it.

---

## 1. Import: `data/lua/osm_import.lua` + `data/lua/lanes.lua`

`osm2pgsql` runs once, in flex-output mode, with `osm_import.lua` as the
entry script. It `require`s `lanes.lua` as a plain Lua module — there is no
separate invocation; lane derivation happens synchronously inline during the
same import pass.

### Table generation

Rather than writing individual `osm2pgsql.define_table()` calls,
`osm_import.lua` declares one Lua table, `layers`, listing each layer's
`attributes` (columns) and `geometries` (`polygon`/`way`/`node`). A generic
`define_tables()` walks this once at load time and, for each
`(layer, geometry type)` pair:

- creates a PostGIS table named `<layer>` if the layer has only one geometry
  type, or `<layer>_<geomtype>` if it has several (e.g. `feature_polygon` /
  `feature_way` / `feature_node`, `road_marking_polygon` / `_way` / `_node`)
- defaults every column to `text` unless a separate `types` table overrides
  it to numeric/integer/real (`width`, `height`, `layer`, `hierarchy`,
  `lane_index`, `capacity`, …) — `direction` is special-cased back to `text`
  for `lanes`/`stop_positions` since it stores directional *words*, not
  degrees
- attaches the geometry column with `projection = crs` and `not_null = true`
- sets `ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' }`
  so every row traces back to its source OSM element

Resulting table families:

| Group | Tables |
|---|---|
| Street furniture | `housenumber`, `tree`, `feature_{polygon,way,node}`, `playground_{polygon,way,node}`, `pitch`, `traffic_sign_{way,node}`, `barrier_{polygon,way,node}`, `stop_positions`, `crossing` |
| Buildings | `building`, `roof_line` |
| Road network (core) | `highway` (line), `highway_area` (polygon), `lanes` (per-lane line), `road_marking_{polygon,way,node}` |
| Rail / water / land | `railway_{way,node}`, `bridge`, `landscape_{way,node}`, `water_body`, `waterway`, `landuse`, `place_{polygon,node}` |
| QA | `_mapping_issues` (populated later, in SQL processing) |

**CRS**: `local crs = tonumber(os.getenv("CRS")) or 3857`, read once at load,
applied to every geometry column so osm2pgsql reprojects on the fly during
import.

### Element dispatch

`osm2pgsql.process_way` / `.process_relation` / `.process_node` each start by
excluding underground/indoor features (`location=indoor`/`underground` or
`indoor=*`) outright. Beyond that, each is a long sequence of independent
`if`-blocks, one per target table — **a single OSM element commonly fans out
into multiple tables** (a `highway=primary` way with `road_marking=yes`
produces rows in both `highway` and `road_marking_*`).

Classification is mostly done via explicit tag-value whitelists near the top
of the file:

- **`feature`** (generic street furniture): `feature_amenity`,
  `feature_emergency`, `feature_highway`, `feature_historic`,
  `feature_leisure`, `feature_man_made`, `feature_sport`, `feature_tourism`,
  `feature_waterway`, `feature_advertising` — each an explicit list of
  accepted values. Both the live tag and its `disused:` variant are checked
  (the latter sets `entry.disused='yes'`, so decommissioned furniture still
  renders, flagged).
- **`highway` / `highway_area`**: four disjoint value lists —
  `highway_motorway_list`, `highway_road_list`, `highway_service_list`,
  `highway_path_list` — decide both *whether* a way is imported and its
  coarse `type` (`motorway`/`road`/`service`/`path`), plus a `hierarchy`
  rank via `highway_hierarchy` (motorway=1 … parking=150; lower = higher
  rendering priority). `highway=construction` is reclassified by its
  `construction=` sub-value. `area:highway=*` polygons (or `highway=* +
  area=yes`) become `highway_area`; `amenity=parking`/etc. also feed
  `highway_area` when the parking sits in the carriageway (checked via
  `parking:lane`/`street_side` position), else falls through to `landuse`.
- **`landuse` vs `landscape`**: both use value-list matching but read
  different tag namespaces (`landuse`/`landcover`/`natural`/`leisure`/
  `amenity` vs. `man_made`/`natural` for cliffs/embankments etc.).
- **`building`**: any closed way/multipolygon with `building=*` or
  `building:part=*`.
- **`road_marking`**: driven by `road_marking=*`, with a legacy fallback
  converting `area:highway=prohibited` → `road_marking=restriction`. Node-
  level `road_marking:forward`/`:backward` take precedence over a plain
  `road_marking` tag.
- **`lanes`**: derived inside `process_highway` whenever `derive_lanes` is
  true (see below).

**Relations**: only `type=multipolygon` is handled. `object:as_multipolygon()`
is iterated and each resulting polygon geometry replays the same
per-table classification logic as `process_way` — multipolygons are
"dismantled" into independent rows carrying the parent relation's tags.

### Notable normalization

- `tometricnumber` — parses `"2.3 m"` / `"150 cm"` / bare numbers into
  metres.
- `directiontodegree` / `cardinaltodegree` — normalizes `direction=*`:
  numeric degrees, English cardinal words (`ne`, `northeast`,
  `north-east`, …), semicolon-separated opposite pairs (`"255;75"` → 255),
  and numeric ranges (`"300-80"` → mean angle via `mid_angle`, handling
  wraparound past 180°).
- `process_tree` — fills missing crown diameter/height/circumference from
  each other using regression constants calibrated against ~400k Berlin
  tree-cadastre records (`diameter_crown = height×0.6 = circumference×7.6 =
  age_years×0.2`), with plausibility clamps, plus a random fallback (5–9 m
  trees, 3–6 m shrubs) and a random `rotation` purely to avoid uniform
  rendering.
- `process_traffic_sign` — strips noise values (`none`/`no`/`yes`/
  `street_name_sign`), extracts an optional country-code prefix, splits on
  `;`/`,`, and translates convenience values (`stop`, `give_way`,
  `maxspeed`, `city_limit`, `overtaking`, …) into real `DE:` sign IDs (e.g.
  `maxspeed` + `maxspeed=30` → `274-30`).
- `process_feature` — per-class subclass derivation (bench
  backrest/armrest/direction folded into one string; bicycle parking merges
  `cargo_bike=designated`; entrances merge multiple
  `entrance_marker:<mode>=yes`; hydrant diameter reads
  `fire_hydrant:diameter` in mm instead of the generic `diameter` tag).
- `process_road_marking` — defaults `stroke` (dashed for dividers/crossing
  edges, solid otherwise), `width` (0.5 m stop lines, 0.12 m divider/edge),
  and `colour` (yellow if `temporary=*`, else white, except signs/crossings
  which stay uncoloured); traffic-sign markings split their sign ID into
  `class`/`symbol` on the first colon.

### `lanes.lua`: per-lane geometry

Called as `get_lanes(object)` from inside `process_highway`, for motorway/
road-class highways, `highway=cycleway`, or anything with `road_marking=yes`
or a `turn`/`turn:lanes*` tag (excluding `cycleway=link`). It's pure
tag→data-structure logic — no DB access — returning `lane_list` (ordered
**left-to-right across the cross-section**, independent of each lane's OSM
travel direction) plus scalar `width`, `placement_offset`, `left_offset`,
`transition`, `width_effective`, `width_effective_source`, which
`osm_import.lua` writes onto the parent `highway` row while the lane list
becomes individual `lanes` rows.

Algorithm outline:

1. **Motorized lane count** — from `lanes`/`lanes:forward`/`lanes:backward`/
   `lanes:both_ways`, with class-based defaults when tags are missing
   (primary/secondary → 2/direction or 1 if oneway; minor oneway → 1; minor
   two-way unmarked → 1 shared `both_ways` lane; marked two-way → 1 each
   way). Right-hand-traffic is hardcoded via `traffic_directions =
   {'backward','forward'}`.
2. **`*:lanes` cycle-lane schema** (`cycleway:lanes[:forward|:backward|:both_ways]`)
   is merged into the positional lane count, distinct from side-tagged
   `cycleway=lane` handled later.
3. **Per-lane attribute loop** over `directions_order` resolves, per lane:
   type (`bus`/`bicycle`/`vehicle`, or fixed `bicycle`/`foot` for standalone
   paths), width (per-lane tag → way width / lane count → class defaults:
   `lane_width_default=3`, `_bothways=5`, `cycleway_width_default=1.5`/`2`
   two-way, `path_width_default=2`, crossing-specific widths), surface/
   colour/turn, and left/right markings (inferred from `overtaking*`,
   adjacent turn lanes forcing a solid centerline, `change`/`change:lanes`).
   Backward-direction lanes have left/right swapped before insertion so the
   final list reads consistently left-to-right in map space.
4. **`cycleway=lane`/`:left`/`:right`/`:both`** lanes are appended per side
   (unless already covered by the `*:lanes` schema), resolved via a
   `side:key → both:key → key` fallback chain. A `traffic_mode:left/right`
   check detects parking tagged *between* the bike lane and the carriageway
   centre and flags `bicycle_parking_*_switch` to reorder at insertion.
5. **Parking lanes** are appended last, from `parking:left/right/both`
   (`yes`→`lane`; recognized values: `lane`, `half_on_kerb`, `on_kerb`,
   `street_side`, `shoulder`, `separate`). Orientation defaults to
   `parallel`, driving default widths (`parking_width_parallel_default=2`,
   `_diagonal_default=4.5`, `_perpendicular_default=5`).
6. **Placement/offset/transition** — `parse_placement` converts
   `placement`/`placement:forward`/`:backward` (and `:start`/`:end`
   variants) like `"left_of:1"→0`, `"right_of:2"→2`, `"middle_of:1"→0.5`
   into the shared left-to-right coordinate system (adjusted by
   `lanes_left_uncounted` for uncounted bike/parking lanes), then computes
   each lane's perpendicular `offset` and, when `placement:end` differs
   from `:start`, a `transition` value — this is what lets a road's
   centerline slide sideways along its length (lane tapering).
7. **`width:effective` reconciliation** — explicit tag wins; otherwise
   derived as mapped `width` minus summed parking/bicycle lane widths.
   Vehicle/bus lanes still on default width are then rescaled to consume the
   remaining effective width evenly (min 2 m/lane).
8. Minor post-processing: bicycle lanes sandwiched between same-direction
   motorized lanes become `class='center_running'`; unset bicycle-lane
   markings default to `dashed_line`; adjacent duplicate markings between
   non-bicycle lanes are suppressed to avoid double-rendering one stripe.

Downstream SQL (`lanes_offset.sql`, `lanes_split.sql`,
`highway_area_centerline.sql`, …) consumes the returned offsets/widths to
build the actual lane-polygon and road-marking geometry — `lanes.lua` only
computes numbers, not final geometry.

---

## 2. SQL processing pipeline (`data/processing/sql/`)

Runs in the fixed order encoded in `data/data_preparation.sh`. The dominant
technique throughout: **derive centerlines → offset/buffer into area or
parallel-line geometry → clip against junction/area polygons → merge
connected fragments back into continuous features for rendering.**

### 2.0 CRS foundation

- **`crs_scale.sql`** computes one Web Mercator distortion factor
  (`1/cos(φ)`) for the whole run and stores it in `public._processing_crs`.
  Latitude source priority: `--bbox` mid-latitude → centroid of the first
  existing table among `highway`/`building`/`feature_polygon`/`lanes`/
  `highway_area` → fallback `1.0`. For non-3857 CRS the factor is always
  `1.0`. Must run before anything using `metres()`.
- **`helper/metres.sql`**: `metres(m)`, a `STABLE` wrapper multiplying by
  that stored factor. **Raises an exception** (rather than silently
  defaulting to `1.0`) if `_processing_crs` is missing — a deliberate guard
  against reintroducing a past "map looks too narrow" bug. Convention:
  attribute columns/params stay in ground metres; only values entering
  `ST_Buffer`/`ST_DWithin`/etc. get wrapped in `metres()`.
- Nearly every script's first line is `\i 'processing/sql/params/params.sql'`
  — ~80 `\set` psql variables in 5 numbered sections (Lanes, Road markings,
  Highway areas, Trees, Buildings) mirroring the pipeline's stage order.

### 2.1 Geometric helper library (`helper/`)

- **`line_offset.sql`** — `line_offset(geom, base_offset, transition)` /
  `line_offset_pin_ends(...)`: a **per-vertex normal-shift** offset
  (preferred over `ST_OffsetCurve` for robustness on complex/self-crossing
  lines). Per vertex: compute a tangent (endpoints use the single adjacent
  segment; interior vertices average both adjacent unit vectors, falling
  back to the incoming vector if they cancel), rotate 90° for the normal,
  translate by `base_offset + s·transition` along it, where `s =
  ST_LineLocatePoint` — implementing OSM's `placement:transition` tapering.
  `_pin_ends` keeps start/end vertices at offset 0 so adjoining lane
  geometries stay connected at junctions. This is the core primitive behind
  lane offsetting, separation/divider lines, and crossing edges.
- **`node_road_azimuth.sql`** — for a node touching a road, splits the road
  at the node (`ST_Split`) and computes the centerline's drawn direction
  there; contributing azimuths from ways digitized in opposite senses are
  aligned (flipped 180° if >90° off a reference) before a circular mean
  (`ATAN2(AVG(SIN),AVG(COS))`), since averaging near-opposite raw angles
  would collapse toward an arbitrary value. Reused by stop lines, crossings,
  and buffer markings.
- **`highway_road_area.sql`** — static lookup of `area:highway` values
  counted as carriageway (deliberately excludes `pedestrian`).
- **`crossing_stripe_polygons.sql`** — generates zebra/ladder stripe
  polygons along a crossing centerline: stripe count from length/spacing
  params, evenly distributed with centering offset, each stripe a short
  buffered perpendicular segment, clipped to a buffer zone around the
  crossing line.
- **`road_marking_merge_connected_markings.sql`** — the shared
  **snap → dissolve → line-merge → reattribute** pipeline used by nearly
  every road-marking script: `ST_Snap` each segment's endpoints to nearby
  same-style neighbors (only to a narrower or earlier-indexed segment, to
  avoid double-snapping) → `ST_LineMerge(ST_UnaryUnion(...))` grouped by
  full style-attribute tuple (turn-lane chains use the direction-preserving
  `ST_LineMerge(..., true)`) → re-attach an `osm_id` per merged component
  from the longest contained/overlapping source segment. Converts many short
  OSM-derived fragments into continuous renderable lines.

### 2.2 Highway network topology

- **`highway_preparation.sql`** — the structural backbone: splits every
  `road`/`motorway` centerline at topological junction vertices (graph
  degree > 2), assigns each fragment a `segment_id`, and groups segments
  between junctions into a `road_segment_id` via a **recursive CTE
  connected-components walk** (`WITH RECURSIVE reach AS (...)`) so OSM way
  boundaries don't fragment one street between real junctions. Also computes
  a length-weighted median `placement_offset`/`left_offset` per
  `road_segment_id` (windowed cumulative-length ranking, so it picks an
  actual observed value rather than `PERCENTILE_CONT`) to smooth
  inconsistent per-way tagging along one street.
- **`lanes_split.sql`** — re-clips `lanes.lua`'s lane centerlines
  (`ST_LineSubstring`) to match these new `highway` segment boundaries, so
  everything downstream can join lanes↔highway 1:1 on `segment_id`.
  `lanes_import` (a one-time snapshot made by `data_preparation.sh`)
  preserves the original unclipped geometry for re-runs.

### 2.3 Lane derivation

1. **`lanes_spread_dual_carriageway.sql`** — at a dual-carriageway
   branch/merge point, the two lanes should visually separate rather than
   meet at one vertex. Finds the best-matching adjoining single-carriageway
   way (`ST_Equals` on shared endpoint + smallest azimuth difference,
   preferring same name) and translates the endpoint sideways by
   `left_offset`.
2. **`lanes_offset.sql`** — applies `line_offset()` (per-lane `offset`/
   `transition` from `lanes.lua`) to produce each lane's actual positioned
   line, using the spread geometry above for dual-carriageway segments
   lacking explicit placement/transition tags.
3. **`lanes_connectivity.sql`** — determines which lane continues into which
   at the next road segment, for continuous rendering across junctions.
   Builds junction candidate pairs from shared endpoints filtered by azimuth
   continuity, then lane-level candidates filtered by type-group
   (`vehicle`/`bus` unified as `motor`), direction-consistency, width
   tolerance, and turn-restriction rules (turning lanes only match other
   turning lanes). A greedy 1:1 nearest-distance match assigns `prev`/`next`.
4. **`lanes_connect_endpoints.sql`** — snaps connected lane endpoints
   together (multi-phase: dual-carriageway "exit" endpoints first, then
   entry-to-predecessor's-exit when the local lane count is ≤ predecessor's,
   then a fallback reverse-direction pass) so junction rendering has no
   gaps.

### 2.4 Highway carriageway areas

- **`highway_area_centerline.sql`** — synthesizes carriageway area polygons
  where OSM doesn't map them: clips centerlines against existing
  `area:highway` polygons, buffers each side of the placement-aware
  centerline (`width/2 ± placement_offset`, `side=left`/`right` mitred
  buffers), unions per `(road_segment_id, highway, surface, layer, tunnel,
  sett:length)`, and does a buffer-then-shrink pass (`+5`/`-5`) to close
  small gaps and smooth outlines. `highway_junctions` is built the same way
  but only from intersections between *different* `road_segment_id`s on the
  same layer — a reusable junction footprint for later clipping.
- **`highway_area_centerline_junctions.sql`** — punches junction footprints
  out of the areas, rebuilds each junction as one merged polygon per
  clipping zone, and picks dominant attributes (`surface`, etc.) by
  area-weighted majority vote.
- **`highway_area_merge.sql`** — folds the resulting synthetic
  (`source='centerline'`) polygons into `highway_area` alongside real OSM
  (`source='osm_feature'`) polygons.
- **`highway_area_surface.sql`** — for OSM polygons missing `surface`, clips
  intersecting `highway` centerlines of matching class and assigns the
  length-weighted dominant surface.
- **`highway_area_parking_class.sql`** — classifies street-parking polygons
  by the predominant overlapping non-parking `highway_area` (area-weighted,
  same-layer preferred), falling back to nearest centerline (`<->` KNN)
  within a search radius.
- **`highway_area_direction.sql`** — a rendering-only orientation for
  texture alignment on `highway_area`, `landuse` (paving_stones/sett), and
  `road_marking_polygon`. Uses `ST_OrientedEnvelope` for long/short axis
  candidates, then nearest-road azimuth (`ST_ShortestLine`) to pick the
  aligned axis; `pattern='zigzag'` picks the specific envelope edge closest
  to the road bearing; restriction/barred-area adds a fixed +45°.

### 2.5 Road markings — the largest subsystem

All feed the shared `road_marking_way`/`road_marking_polygon`/
`road_marking_node` tables, and most funnel raw segments through
`helper/road_marking_merge_connected_markings.sql`. **Order matters** —
later scripts clip against junction/crossing footprints built by earlier
ones.

- **`road_marking_lanes_prepare.sql`** — computes shared clipping
  infrastructure once: `highway_junctions_clipping_base` (junction
  footprints ∪ convex hulls linking nearby stop-lines to their nearest
  junction, absorbing short stubs), `highway_junctions_clipping_areas`
  (+ explicit junction/crossing `highway_area` polygons, excluding ones
  tagged `markings=yes`), and a `markings_yes`-only variant for arrow
  clipping. Produces `lanes_clipped`/`lanes_clipped_for_arrows`, consumed by
  every later lane-marking script instead of raw `lanes`.
- **`road_marking_stop_lines.sql`** (~2400 lines, the most complex script) —
  generates stop lines from generic stop/signal nodes (perpendicular
  projection onto the matched road, clipped to buffered approach lanes) and,
  more elaborately, from junction-area outlines: explodes each junction
  polygon boundary into azimuth-tagged segments, computes an "outline
  azimuth" at each stop node, punches out kerb/landuse/restriction geometry,
  regroups remaining fragments into gap-separated "anchor chains" (via
  `DENSE_RANK`), assigns each chain to the nearest stop-node/azimuth group
  within ±25°, classifies by lane-touch, and merges/extends survivors per
  stop node. The one script with genuinely complex ring/graph bookkeeping
  rather than plain buffer/clip geometry.
- **`road_marking_barred_area.sql`** — derives hatched barred-area polygons
  from lane `marking_left/right` where no OSM polygon already covers the
  spot, cutting the buffer where lanes cross narrow service ways.
- **`road_marking_separation.sql`** — offsets separation lines (e.g.
  physically separated cycle lanes) from lane `separation_left/right`, with
  a bollard-suppression pass: real OSM bollard nodes covering ≥1/3 of a
  generic line's length suppress the generic line in favour of the bollards.
- **`road_marking_lane_divider.sql`** (~1500 lines) — the main narrow/wide
  stroke divider-line generator from `marking_left/right`, plus separate
  handling at junctions and lane-count-transition zones (dashed→solid
  heuristics for bicycle lanes near junctions).
- **`road_marking_crossing_edge.sql`** — edge lines along centerline-derived
  crossings (extended past crossing width, skipped where a connected
  bicycle lane already has its own marking) and cycleway-polygon boundaries
  at junctions; also sets `dasharray` on all `road_marking_way` rows.
- **`road_marking_arrows.sql`** — merges turn-lane centerline segments into
  arrow lines, computes each line's signed distance to its nearest
  junction-only stop line (`end_offset`), places turn-arrow point symbols on
  a 12 m grid anchored relative to that offset; converts OSM arrow ways
  directly to midpoint nodes.
- **`road_marking_nodes.sql`** — snaps directional OSM `road_marking_node`
  points (forward/backward-only, or `both_ways` lanes offset via
  `line_offset`) onto the matching lane centerline; fills default
  width/length for `traffic_sign` markings (`length = width ×
  distortion_factor`).
- **`road_marking_colour.sql`** — buffers lane centerline colours and
  `highway_area` surface colours into filled polygons
  (`road_marking='surface_colour'`); later clipped at crossings.
- **`road_marking_restriction.sql`** — converts `restriction`-pattern
  polygons into line patterns: `pattern='x'` draws oriented-bounding-box
  diagonals + boundary; `pattern='zigzag'` draws stepped lines between the
  OBB's front/back edges (step size capped at 7 m).
- **`road_marking_crossing.sql`** (~2400 lines, largest script) — full
  crossing-marking pipeline: road azimuth per crossing node (via the shared
  helper), classifies crossing nodes/tagged path ways, derives centerlines
  by scoring candidate path segments per side, merges/extends them,
  generates zebra stripes via `helper/crossing_stripe_polygons.sql`,
  computes multi-layer clip zones, and clips `road_marking_way`/`_polygon`
  and separation lines against those footprints so markings don't paint
  through crossings.
- **`road_marking_buffer_marking.sql`** (~1900 lines) — painted
  kerb-extension "buffer marking" areas at crossings tagged
  `crossing:buffer_marking=left/right/both`: road-facing reference point per
  side (optionally relocated past a conflicting parallel bike lane),
  trapezoid areas from front/back-edge length + depth params, clipped to
  carriageway `highway_area`, merged with compatible overlapping restriction/
  barred-area polygons, then cuts a pedestrian "tunnel" (with a footway
  symbol point) wherever a crossing line actually passes through.
- **`road_marking_parking.sql`** — builds parking-lot outline lines from
  parking `highway_area`/`feature_polygon` boundaries (excluding kerb-
  covered/shared-edge segments), places `parking_space` symbol points with
  geometry-derived orientation.

### 2.6 Other feature derivation

- **`tree.sql`** — synthesizes plausible tree points inside forest/wood
  `landuse` polygons on a **hexagonal grid** (`ST_HexagonGrid`), sized by
  forest area class, skipping cells already occupied by a real OSM tree
  node, then assigning randomized leaf type/crown diameter/rotation.
  Synthetic rows get negative `osm_id`s and `source='forest_generated'`.
- **`feature_direction.sql`** — orients street furniture (cabinets, lamps,
  vending machines, guard stones, …) toward the nearest road
  (`ST_ClosestPoint` + `ST_Azimuth`), two-pass (major roads first, then
  any way); guard stones always use the nearest way regardless of class.
- **`pitch.sql`** — for near-rectangular sports pitches (area ratio to
  `ST_OrientedEnvelope` > 0.9), derives centroid, side lengths, and
  orientation for texture/marking rendering.
- **`table_tennis.sql`** — converts small table-tennis pitch areas into
  point nodes so they render as symbols, not tiny polygons.
- **`building.sql`** — height/floating-part pipeline: derives height from
  `building:levels×3` or class defaults (3 m roof/service, 5 m else), with
  cascading fallback for `building:part`s not cleanly nested in an outline;
  determines a `floating` flag; rebuilds the footprint via a
  **polygon-arrangement technique** — union all part+outline boundaries into
  a "blade," `ST_Polygonize` it into atomic faces, reattach height/floating
  per face by spatial overlap — guaranteeing one polygon per
  (height, floating) combination even where OSM parts overlap messily. Also
  extrudes shade polygons via `CG_Extrude` (SFCGAL) with a fixed-angle
  offset and an asymptotic length curve, and derives covered/uncovered
  outline lines.
- **`housenumber.sql`** — nudges housenumber label points inward from a
  building's inner boundary (buffered -2 m) if within 3.5 m, for label
  clarity.
- **`tactile_paving.sql`** — derives tactile-paving lines along kerb ways
  touching tagged kerb nodes, buffered by the intersecting crossing's
  mapped width (default 5 m), plus separate paths for tagged kerb ways and
  `footway`/`path` lines (excluding crossings, where `tactile_paving=yes`
  means "at the edges").
- **`service.sql`** — dissolves `highway=service` ways by
  `(class, width, layer)` for cleaner parking-aisle/driveway rendering.
- **`bridge.sql`** — bridge "shadow" areas shrunk only where a bridge is
  actually crossed by a highway/railway (not at its free ends): explodes the
  outline into segments, groups collinear ones (<30° change) into logical
  edges, buffers only edges intersecting a same-layer highway/railway (5 m),
  subtracts those buffers from the bridge polygon.
- **`water_body.sql`** / **`waterway.sql`** — dissolve water polygons into
  single parts, then clip waterway *lines* to remove portions already
  covered by water-body *polygons* (avoids double-rendering a river's
  centerline inside its own lake widening); the clip script dynamically
  re-projects all `waterway` columns via `information_schema` +
  `EXECUTE format(...)` rather than a hardcoded column list.

### 2.7 Label geometry

Both label scripts solve the same problem — well-placed, non-duplicated
label lines — with a **build-candidate-then-score-by-overlap** strategy:

- **`label_waterway.sql`** — unifies waterway lines by name+category, cuts
  at lake/water-body boundaries and long tunnels, generates ~300 m "target"
  sub-segments (splitting into ≤1200 m chunks, trimming to a centered 300 m
  window), separately cuts bridges/short-tunnels from the base lines, then
  for each target picks the base-line fragment with the largest
  length-of-intersection overlap (`ROW_NUMBER() OVER (PARTITION BY target
  ORDER BY overlap_length DESC)`).
- **`label_highway.sql`** (~1050 lines, more elaborate) — extracts named
  highways (excluding long tunnels), drops short link/connector fragments
  that aren't a collinear same-name continuation (so `ST_LineMerge` can span
  many short OSM way splits), shifts vertices toward the carriageway center
  via `placement_offset` (pinning endpoints shared with other same-name/
  class segments), then for **dual carriageways** either picks one side
  (high zoom) or computes a skeleton centerline via
  **`CG_ApproximateMedialAxis`** (SFCGAL, low zoom) to avoid duplicate
  parallel labels. Segments merge via a `merge_id` that only groups a
  collinear through-pair (±25°, undirected) at junctions with >2 same-name/
  class arms, so branching junctions don't force disconnected geometry into
  one dissolve group. After dissolving, long lines are split into
  near-equal pieces (1500 m low-zoom / 750 m high-zoom cap, preferring cuts
  near real intersections within 200 m), selectively simplified only where
  offset-pinning introduced sawtooth artifacts, and trimmed 12 m from ends
  meeting another main/minor road (true dead-ends keep full length). Output
  is one `label_highway` table with a `zoom IN ('low','high')` discriminator.

### 2.8 Loose end: unused scripts

`traffic_sign_node.sql` and `traffic_sign_way.sql` exist in
`processing/sql/` but are **not referenced anywhere** — not in
`data_preparation.sh`'s sequence, and not `\i`'d from any other script.
`traffic_sign_node.sql` would derive traffic-sign node direction from the
highway line it sits on; `traffic_sign_way.sql` would dissolve
`traffic_sign_way` into `traffic_sign_centerline_segments`. They're either
leftover from a feature superseded by `road_marking_node`'s `traffic_sign`
handling (see `road_marking_nodes.sql`), or meant to be wired in but
aren't. Worth resolving one way or the other before relying on them.

---

## 3. QGIS style (`style/`)

### `strassenraumkarte.qgz` structure

The `.qgz` is a zip of exactly two members: the project XML
(`strassenraumkarte.qgs`, ~338k lines / ~20.8 MB) and a `*_styles.db`
SQLite sidecar (~92 KB, QGIS's saved symbol/colour-ramp library). 256
`<maplayer>` definitions total.

Top-level layer tree: two groups, `label` and `map`. Under `map`:

| Group | Layers |
|---|---|
| `entrance` | 1 |
| `feature (foreground)` | 1 |
| `building` | 5 |
| `tree` (1 subgroup) | 2 |
| `symbol_pattern` | 2 |
| `highway (layered)` | 78 subgroups, 192 layers — generated |
| `highway (unlayered)` | 12 subgroups, 32 layers — hand-styled template |
| `land` (5 subgroups) | 14 |

192 ≈ 6 × 32 confirms the layered group is one full clone of the unlayered
template per `LAYER_FILTERS` band (see below).

### `update_highway_layered.py`

Solves a real maintenance problem: bridges/tunnels need the same highway
styling repeated per OSM `layer=` value (so a `layer=1` bridge draws
correctly over a `layer=-1` tunnel), but hand-maintaining N duplicate style
copies in QGIS would be unmaintainable. Instead one template group,
`highway (unlayered)`, is styled normally in the GUI, and this script
mechanically regenerates the sibling `highway (layered)` group by cloning
the template once per `LAYER_FILTERS` entry (`layer >= 3`, `= 2`, `= 1`,
`= 0`/NULL, `= -1`, `<= -2`) and AND-ing an extra SQL predicate onto each
cloned layer's datasource.

It operates directly on the project XML (`xml.etree.ElementTree` +
`zipfile`, no PyQGIS/QGIS runtime):

1. Unzips the `.qgz`, isolates the `.qgs` XML, keeps other zip members
   (the styles DB) as raw bytes. Writes a `.qgz.bak` backup first.
2. Locates the `highway (unlayered)` and `highway (layered)`
   `layer-tree-group` elements, plus the parallel `legendgroup` element
   (QGIS keeps a separate "legend" tree that must stay in sync).
3. For each of the 6 filter bands, deep-copies every subgroup of the
   template, then rewrites each cloned `layer-tree-layer` node: a fresh
   unique layer id (slugified name + uuid4 hex — QGIS ids must be globally
   unique) and the SQL filter appended to that layer's `source` attribute
   (`(existing sql) AND (new_filter)`, with manual XML-entity
   encode/decode since the filter lives inside an attribute value that is
   itself a datasource string).
4. In parallel, deep-copies the actual `<maplayer>` definition (style/
   renderer) for each cloned id, rewriting its `<id>` and `<datasource>`.
   **Styling XML is preserved verbatim** — this script never touches
   symbology, only ids and the SQL filter.
5. Regenerates the matching `legendgroup`/`legendlayer` XML from the new
   layer-tree structure.
6. Removes all old layered-group `<maplayer>`s and swaps in the new set;
   replaces the old layered `layer-tree-group`/`legendgroup` wholesale.
7. Fixes up every other place a layer id appears: `<layerorder>` and any
   `<custom-order>` (splicing new ids in at the old ids' position, to
   preserve draw order), purges stale ids from `<snapping-settings>`, adds
   fresh (disabled) snapping entries for the new ids.
8. Writes the modified `.qgs` back, re-zips with the untouched sibling
   files into `.qgz.tmp`, and atomically replaces the original `.qgz`.

Run manually — `python3 style/update_highway_layered.py [path]` — whenever
the unlayered template's styling changes and the layered copies need to
catch up. It's a one-shot generator, not part of `run.sh`. Layer ids are
always regenerated fresh (never reused), so re-running is idempotent but
never keeps old ids.

### Symbol / texture assets

`style/symbols/` (mostly SVG, organized by OSM tag category, uneven sizes):
`cars/` is the largest set (42 files — a parked-car symbol set varying by
angle/type, matching the style's emphasis on parked cars), `amenity/` (19),
`parking/` (6), `leisure/`/`tourism/` (5 each), `traffic_signs/` (3),
`highway/`/`public_transport/`/`traffic_calming/`/`rock/`/`trees/` (2 each),
`historic/`/`man_made/` (1 each), plus `empty.svg` (placeholder/no-symbol
fallback) and `map marker.png`.

`style/textures/`: 8 top-level PNGs (`flowerbed`, `forest`, `grass`,
`gravel`, `sand`, `water`, `wetland`, `woodchips`) plus `pitches/` (14 files
— per-sport-surface patterns for `leisure=pitch`, feeding `pitch.sql`) and
`surface/` (4 files — generic ground fills, e.g. paving/sett, feeding
`highway_area_surface.sql`).

---

## 4. Rendering (`render/`)

### `xyz_tiles.py` — the metatile rendering engine

Replaces `qgis_process` with a hand-rolled PyQGIS batch renderer because the
pipeline needs per-metatile progress/ETA, mixed PNG/JPEG output,
gutter-based label bleed, and an `@mercator_scale` project variable set from
the actual render extent — none of which `qgis_process` exposes.

**Tile coordinate math** (standard XYZ/slippy-map tiling, EPSG:3857):
`lon_to_tile_x`/`lat_to_tile_y` implement the classic Web Mercator tile
formulas (`asinh(tan(lat))` form), clamping latitude to ±85.0511° before
conversion. `tile_range_for_bbox` converts a WGS84 bbox to an inclusive
`TileRange` at a given zoom (max tile y is smaller in the north, so `ymax`
maps to `y0`). `tile_bounds_3857(x,y,z)` computes a tile's EPSG:3857 extent
directly from its index using `ORIGIN_SHIFT = 20037508.342789244` (half the
Web Mercator world width) — no reprojection needed since rendering happens
natively in 3857.

**Metatiles and gutter** (`iter_metatiles`): the tile grid at each zoom is
partitioned into `metatile × metatile` blocks aligned to multiples of
`metatile`, clipped to the requested range. Each block has **core** bounds
(the tiles actually written) and **render** bounds (core expanded by
`gutter` tiles per side, clamped to valid tile indices). E.g. with
`metatile=8, gutter=1`: a render pass draws a 10×10-tile canvas but only the
inner 8×8=64 tiles are sliced out and saved — letting labels/symbols near a
metatile boundary draw with full context before being cropped cleanly,
rather than truncated at a hard tile edge. Canvas pixel size =
`render_tiles × 256`.

**`@mercator_scale` resolution**: ground-metre symbol/line widths in the
style are stored as map units scaled by this project variable
(`=1/cos(φ)`). Resolved once per run, priority order: (1) mid-latitude of
the requested render extent; (2) fallback lookup against
`public._processing_crs` (written by `crs_scale.sql`); (3) hard fallback
`1.0`. If the project CRS isn't EPSG:3857, scale is forced to `1.0` with a
warning (the script otherwise hard-errors on non-3857 later).

**QGIS headless bootstrap**: `QT_QPA_PLATFORM=offscreen` set before
importing `qgis.core`; standard `QgsApplication([], False)` +
`app.initQgis()` (no GUI, so no `initGui`). A custom Qt message handler
filters a specific class of `QPainter` cascade warnings known to be noise
once a paint context has already failed for unrelated reasons — real
allocation failures are instead caught explicitly via `QImage.isNull()`.
The project loads once; `collect_visible_layers` walks the layer tree
keeping only valid, checked-visible layers (topmost first) and errors
immediately if none are found — a deliberate sanity check against a broken
DB connection, with the error message pointing at `PGUSER`/`PGPASSFILE`.
`project.presetHomePath()` is force-set to the project directory if unset,
because the style's `@project_folder + '/symbols/...'` expressions only
resolve with a home path set — otherwise SVG/raster fills silently render
as QGIS's "?" placeholder.

**Per-metatile render**: builds a `QgsMapSettings` per metatile (copied from
a shared template), sets extent to the gutter-expanded bounds, renders into
a `QImage` via `QgsMapRendererCustomPainterJob` run synchronously
(`start()` + `waitForFinished()`). It explicitly appends
`QgsExpressionContextUtils.mapSettingsScope(settings)` to the expression
context — a documented workaround, since without it `@map_scale` is `NULL`
and silently breaks label-opacity expressions like `CASE WHEN @map_scale <
2000 …` in the style (always falling to `ELSE`). Several `QgsMapSettings`
flags are pinned for headless correctness: `UseAdvancedEffects=False`
(avoids `QGraphicsEffect` buffers that tend to fail off-screen),
`RenderBlocking=True` (forces synchronous SVG/raster loading — no canvas
refresh loop to retry on), `LosslessImageRendering=True`,
`RenderMapTile=True`. Core tiles are then sliced out of the metatile
`QImage` by pixel offset and saved individually; gutter pixels are simply
never copied out. `save_tile_image`, for JPEG (no alpha channel), composites
the premultiplied ARGB buffer onto an opaque background-filled `QImage` via
`QPainter` before encoding — saving `ARGB32_Premultiplied` directly as JPEG
was found to drop alpha incorrectly and produce flat gray tiles.

**Progress/ETA**: one line rewritten in place with `\r`, updated after every
metatile — `% complete`, `zoom z/zmax`, metatiles/tiles done, elapsed, and a
linear-extrapolation ETA. Totals across the whole zoom range are
precomputed up front so the first progress line is already exact.

**CLI**: `--project`, `--extent` (`"xmin,xmax,ymin,ymax [EPSG:nnnn]"` — note
this field order differs from the shell scripts' `--bbox
xmin,ymin,xmax,ymax`; translated by the caller), `--out`, `--zmin`/`--zmax`
(15/20), `--metatile` (8), `--gutter` (1), `--dpi` (96), `--background`
(#ededed), `--format`/`--quality` (jpg/90).

### `project_extent.py` — extent auto-detection

Used by `render_tiles.sh` only when `--bbox` is omitted. Two-tier, both
shelling out to `psql` (no Python GIS deps):

1. **Preferred**: combined PostGIS layer extent. Checks which of a fixed
   candidate table list (`highway`, `highway_area`, `landuse`, `building`,
   `building_parts`, `lanes`) actually exist, `UNION ALL`s their non-null
   geometries, computes `ST_Extent`, transforms to EPSG:4326 — so the extent
   tracks whatever data was actually imported, not a fixed setting.
2. **Fallback**: the QGIS project's stored map-canvas extent, parsed
   directly from the `.qgs` XML (`<mapcanvas><extent>` +
   `destinationsrs`), reprojected to 4326 (via a one-off `psql`
   `ST_Transform`, or pass-through if the DB connection fails), with a
   stderr warning that a less-authoritative source is being used.

Emits a single line to stdout in the `xyz_tiles.py`-compatible extent
string; errors/warnings go to stderr so `render_tiles.sh` can capture just
the extent cleanly.

### `render_tiles.sh`

Thin orchestration wrapper: validates its own flags, resolves
`--project`/`--out` to absolute paths, sources `data/db_config.sh`. If
`--bbox` was given, reformats it from `xmin,ymin,xmax,ymax` into
`xyz_tiles.py`'s expected `"xmin,xmax,ymin,ymax [EPSG:4326]"`; otherwise
invokes `project_extent.py` and captures stdout as the extent (letting
stderr warnings pass through). Finally `exec`s `python3 xyz_tiles.py` — using
`exec` so the shell process is replaced, letting signals (e.g. `SIGTERM`
from the preview server's stop button) reach the Python process directly
rather than being caught by an intermediate bash layer.

### `preview_server.py` — interactive control plane

A dependency-free `http.server.ThreadingHTTPServer` (stdlib only) serving
three roles: static tile server, static preview-page host, and a JSON
control API that launches/monitors `run.sh` as a subprocess.

Endpoints:

- `GET /api/pbfs` — lists local `*.osm.pbf`/`*.pbf` under `data/osm/`
  (excluding pipeline-generated `extract_*` files) for the UI's data picker.
- `GET /api/tiles/info` — counts `.jpg`/`.png` under `render/tiles/` and
  suggests which format the UI should request.
- `GET /api/run/status?since=N` — run state (`running`, `pid`, timestamps,
  `exit_code`, command line) plus a log-line window `lines[since:]` for
  incremental polling.
- `POST /api/run` — validates `data` (must be a `data/osm/`-relative local
  path that doesn't escape via `..`, verified with `Path.relative_to`, or a
  URL matching a strict `https://download.geofabrik.de/....osm.pbf` regex —
  no arbitrary URLs/paths accepted) and `bbox` (regex + numeric range/order
  check), then launches `./run.sh`.
- `POST /api/run/stop` — sends `SIGTERM` to the subprocess's process group.
- Tile serving: `GET /{z}/{x}/{y}.{jpg|png}`, with automatic fallback to the
  other format if the requested extension is missing.
- `GET /` and `GET /preview.html` both serve `render/tiles/preview.html`
  (static-file root is `render/tiles/`).

Subprocess management: a module-level dict + `threading.Lock` enforces
single-run-at-a-time (409 if already running, no queueing). The subprocess
runs with `start_new_session=True` so `stop_run()` can `os.killpg()` the
whole `run.sh` → `data_preparation.sh`/`render_tiles.sh` →
`psql`/`osm2pgsql`/`python3 xyz_tiles.py` process tree, not just the top
bash process. A daemon reader thread drains merged stdout+stderr line by
line into a capped 5000-line buffer (oldest dropped) to bound memory on long
runs. CORS is permissive (`Access-Control-Allow-Origin: *`) — this is a
`127.0.0.1`-only local dev tool, not meant to be exposed.

---

## Summary: data flow at a glance

```
OSM PBF
  │  osm2pgsql -O flex -S osm_import.lua  (+ lanes.lua inline)
  ▼
raw PostGIS tables (highway, lanes, highway_area, building, feature_*, …)
  │  ~30 SQL scripts, fixed order (data_preparation.sh)
  │    topology → lane offsetting/connectivity → carriageway areas
  │    → road markings → buildings/trees/water → labels
  ▼
render-ready PostGIS tables
  │  QGIS project (strassenraumkarte.qgz) maps tables → symbology
  │  (highway (layered) generated from highway (unlayered) via
  │   update_highway_layered.py)
  ▼
render/xyz_tiles.py  (PyQGIS headless, metatile+gutter loop)
  ▼
render/tiles/{z}/{x}/{y}.{png|jpg}
```
