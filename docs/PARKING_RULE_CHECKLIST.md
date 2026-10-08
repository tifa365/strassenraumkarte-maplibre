# Berlin parking calculation checklist

The calculation is a PostGIS port of `SupaplexOSM/street_parking.py` at
`96debe3635ff7c63800d968270db7ae3b21c48e0` (SHA-256 is recorded in each
generation manifest).  Source objects are imported by
`data/lua/parking_import.lua` into an isolated `parking_<generation>` schema.

## Current generation

Generation `1b18769b037e648a63ce9c8e` is the current published build. It was
created from the Berlin PBF with SHA-256
`f3484f6d580c989b3d61f5c591e7b13d56b7a978b0c5ff7f04e193421e793094` and header
timestamp `2026-08-24T20:20:50Z`. The generation contains 1,494,401 points,
1,494,787 final lane-capacity spaces, and 83,553 post-cut line fragments.
Structural contract checks, car-asset checks, database geometry checks, and
renderer preflight passed. Source counts, diagnostics, timings, tool versions,
and output digest are recorded in its manifest.

The fixture harness compares output by source identity and nearest position;
the upstream coordinate-product identifier is not used as a key. The pinned
QGIS reference comparison remains a separate gate for future rule changes.

| Upstream function / stage | PostGIS implementation | Verification |
| --- | --- | --- |
| `fillBaseAttributes`, `getSideAttribute` | `parking_01_normalize.sql`, `parking_get_side` | side/both precedence, widths, defaults |
| `prepareParkingLane` | `parking_01_normalize.sql` | orientation and restriction fixtures |
| `getConditionClass`, `getSubCondition` | `parking_condition_class` | conditional restriction fixtures |
| virtual kerbs, offsets, grouping | `parking_02_lanes.sql` | reversed ways, both sides, one-way |
| `bufferCrossing`, `bufferTurningCircles`, `bufferBusStop` | `parking_03_obstructions.sql` | crossing, turning and bus-stop fixtures |
| `processObstacles`, driveway/intersection cuts | `parking_03_obstructions.sql` | obstacle and driveway fixtures |
| `processSeparateParkingNodes` | `parking_04_separate.sql` | mapped roadside points |
| `processSeparateParkingAreas` | `parking_04_separate.sql` | boundary conversion and diagnostics |
| duplicate inferred parking removal | `parking_04_separate.sql` | overlap fixture |
| `getCapacity` | `parking_05_points.sql` | explicit, estimated, short and split capacity |
| point chain and vehicle-centre translation | `parking_05_points.sql` | three orientations and one-space fixture |
| vehicle appearance | deterministic SHA-256 selection in `parking_05_points.sql` | asset audit and repeatability |

Reference harness patches are limited to removing the two redundant
unconditional `remove('offset')` calls, replacing GUI-only setup with a command
line input/output harness, and creating output directories/checking writes.
The pinned file is retained verbatim under `data/parking/reference/upstream/`;
no parking rule or default is changed by these patches.

## Session fixes (2026-09-08)

Verifying a prior generation (`870b00f319d44bcbcb8b715d`, published then, since
superseded) surfaced four defects, fixed in order and rebuilt/re-validated
against the full Berlin PBF after each fix. The superseding generation currently
published is `1b18769b037e648a63ce9c8e`, 1,494,401 points, with
`capacity_total` 1,494,787. The point count and lane capacity are recorded
separately; the residual is 11 `inferred` lines
with a genuinely undefined azimuth — see below.

1. **`data/build_parking.sh:110` (manifest `capacity_total`).** Summed the
   exported points' `capacity` property across every point, but that property
   is each line's *total* capacity duplicated onto every one of its points —
   so the sum was roughly Σcapacity² per line, not a real total (was
   42,664,508 against 1,124,094 actual points). Fixed to
   `SELECT sum(capacity) FROM parking_lines`, computed once per line.
2. **`render/render_tiles.sh:251`.** Called bare `python3` for
   `project_extent.py` instead of the resolved `$QGIS_PYTHON_BIN`, so any run
   without `--bbox` (including `--preflight`) crashed immediately on a
   non-QGIS Python (`AssertionError: SRE module mismatch`). The renderer's own
   `docs/RENDER_RECOVERY_PLAN.md` documents exactly this class of bug under
   "Runtime reproducibility"; this specific call site had just been missed.
3. **`parking_04_separate.sql`, boundary segmentation.** `ST_Dump(ST_Boundary(polygon))`
   does not decompose a polygon ring into its individual sides — for a single
   ring it returns the whole closed ring as one "edge" whose start point
   equals its end point, so `ST_Azimuth` is undefined and every such row is
   dropped by the point generator's `angle IS NOT NULL` filter. All 44,367
   `separate_area` lines in the prior generation were silently empty (0
   points from a nominal 494,142 capacity) because of this. Fixed by walking
   consecutive `ST_DumpPoints` pairs to build real edges.
4. **`parking_04_separate.sql`, polygon eligibility.** Accepted any
   `amenity=parking` polygon (i.e. every off-street lot, ~60,502 of them),
   when the pinned upstream (`street_parking.py:1461`,
   `processSeparateParkingAreas`) requires `amenity=parking AND parking IN
   (street_side, lane, on_kerb, half_on_kerb, shoulder)` — this is exactly
   the "do not expand into off-street car parks" boundary from the project
   plan. Also missing upstream's `location NOT IN (lane_centre, median)`
   exclusion. Fixed to match the upstream expression exactly (44,600 lines
   after the fix, vs. the over-inclusive 149,522 before it).
5. **`parking_04_separate.sql`, per-polygon dissolve.** Upstream dissolves a
   polygon's near-parallel ("outer") boundary edges into as few pieces as
   possible before generating points (`native:dissolve` +
   `native:multiparttosingleparts`); the port originally treated each
   qualifying edge independently, which double-counts capacity for a lot with
   two connected qualifying sides. Fixed with
   `ST_LineMerge(ST_Collect(edge)) GROUP BY osm_id`. This reintroduced defect
   3's closed-ring problem for small/round lots where the *entire* boundary
   qualifies as "outer" (81% of `separate_area` lines had `angle IS NULL`
   after this change) — fixed by opening any resulting closed ring with
   `ST_RemovePoint(merged, ST_NPoints(merged)-1)` before storing it.

**Known residual gap, not fixed this session:** the per-polygon dissolve
still assigns the *same* area-derived capacity
(`floor(ST_Area(poly)/12)`) to every disjoint piece a polygon happens to
split into (rare — most polygons dissolve to one piece), which matches the
observed behaviour of the pinned upstream script's own `capacity_dict[id]`
reuse rather than a bug introduced here, but has not been fixed against a
regression fixture. Left as upstream-faithful per the plan's "preserve even
suspicious defaults until a regression test justifies a separately documented
correction" rule.

Superseded intermediate generations from this session
(`308034ea2db12e9f8230923f` boundary-fix-only/over-inclusive,
`1ede83c4ac87e81948662462` eligibility-fix-only/pre-ring-fix) and their
`parking_<id>` schemas were kept for inspection rather than dropped
automatically — see "Reproduction and rollback" below for full-rebuild steps
if disk space needs reclaiming instead.

## Reproduction and rollback

From the repository root, run `./data/build_parking.sh --data
data/osm/berlin-latest.osm.pbf` (add `--bbox xmin,ymin,xmax,ymax` to select an
export extent). The command prints the immutable generation ID; resume it with
`--data ... --resume ID`, then publish with `./data/build_parking.sh --publish
ID`. Publication preserves the previous file under `data/parking/rollback/`.
To roll back, move the desired timestamped file back to
`data/parking/street_parking_points_processed.geojson` while no renderer is
running, then rerun renderer preflight.
