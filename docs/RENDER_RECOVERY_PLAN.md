# Raster renderer review and recovery plan

Reviewed 2026-09-08. Scope: `render/xyz_tiles.py`, its launcher and extent helper,
the QGIS project XML, tree import/generation, and lightweight database/runtime
checks. No map render was started, no running process was stopped, and no tile,
style, or database content was changed during this review.

## Root cause found (2026-09-08, follow-up session): ShapeburstFill OOM

**This explains the unresolved "reason the process stopped" below and is very
likely the actual cause of the original stalled full-Berlin render**, not
merely "another allocation/QPicture error."

Reproduced with a bisection harness (render one layer, or one contiguous
range of layers, in isolation and see whether the process survives — see
`git log` / ask for `layer_bisect.py` and `range_test.py`, written to a
scratch dir and not committed, easy to reconstruct from this description):
rendering a single small (13.4395–13.4498°E, 52.4722–52.4759°N, ~700m×400m,
z18, one 8+1 metatile = 40 tiles) scene is killed by the OS (`SIGKILL`,
exit 137) even with the tree layer disabled and even when the 679MB parking
GeoJSON layer is swapped for a 6,500-feature/4.2MB subset — ruling out both
trees and (today's much larger) parking data as the cause. `/usr/bin/time -l`
on a direct `xyz_tiles.py` invocation (bypassing the shell launcher) shows
**"peak memory footprint" of ~97.5GB** against a maximum resident set size of
only ~3.5GB — i.e. the process asked the kernel for a single huge allocation
that was mostly never touched, and macOS's jetsam killed it outright. This
machine has 16GB RAM / 2GB swap.

Bisecting the project's 222 visible layers (binary search over contiguous
ranges, each range rendered fresh in its own process) isolates it to exactly
two layers, both otherwise-ordinary layers on the small `water_body_dissolved`
table (1,559 features citywide; the specific features intersecting the test
scene are tiny — 5 to 317 m², 20–50m across, ruling out "one huge polygon" as
the trigger):

- `water body (depth effect)` (layer id
  `water_body_dissolved_668c3ad1_be0c_49db_b0d9_9c918b8aee0f`) — crashes
  **on its own**, alone, with no other layer active.
- `water body` (layer id
  `water_body_dissolved_524b39dc_514a_4c06_870a_d21db3dbf3de`) — also crashes
  **on its own**.

Both layers' symbol stacks include a `ShapeburstFill` symbol layer (a
distance-gradient fill; `water body (depth effect)`'s has
`use_whole_shape=1`, `distance_unit=MM`, `max_distance=100`,
`blur_radius=18`). No other layer in the project (confirmed by exhaustively
covering the other 220 with passing contiguous-range tests) reproduces this.
**`ShapeburstFill` itself is the trigger**, independent of feature size.

This strongly correlates with QGIS's own load-time warning: *"Loading a file
that was saved with an older version of qgis (saved in 3.34.4-Prizren, loaded
in 4.2.1-Belém do Pará). Problems may occur."* `style/strassenraumkarte.qgz`
has been unchanged since the initial commit (2026-08-01) — this is a
long-standing, pre-existing landmine in the base cartography that nothing in
today's parking or MapLibre work touched; it simply hadn't been exercised
against this QGIS 4.2.1 build before. The most likely explanation is a
regression in this QGIS dev build's `ShapeburstFill` implementation (a
long-known-expensive, less-common symbol layer type) versus the QGIS 3.34
the project was authored and tested against.

**Addendum 2026-09-10, closest known match — but not a confirmed identical
bug.** [QGIS issue #67142](https://github.com/qgis/QGIS/issues/67142) (opened
2026-08-24, against QGIS 4.2.0) reports QGIS Server hanging while rendering
`ShapeburstFill` with non-zero blur strength, reproducible with a single
triangle — no large/complex geometry required, and QGIS's own docs describe
blur strength as a standard `ShapeburstFill` option, not something unique to
our water styling. That's a materially more precise characterization than
"a general QGIS bug drawing water" and is worth keeping: it's a bug in one
specific, identifiable symbol-layer feature, and water is only one of many
things people style with it (this project's own "roof shape" layer also uses
`ShapeburstFill`, with `blur_radius=0`, and does not crash).

However, **directly tested and ruled out as our specific trigger**: forcing
`blur_radius=0` on both water layers (together, and each individually, all
other properties — `use_whole_shape`, `distance_unit=MM`, `max_distance` —
left unchanged) still gets `SIGKILL`ed at the same point. Notably, "water
body" (`use_whole_shape=0`, `max_distance=3`, i.e. already small and bounded,
not the "whole polygon" mode) crashes too, with or without blur — smaller
than the working "roof shape" instance's `max_distance=5`. So our crash is
not explained by #67142's blur-strength trigger alone; it's a related-but-
distinct `ShapeburstFill` problem in this QGIS build, and the exact trigger
(gradient rendering itself? something about the water table's geometry mix
even for small on-screen features?) remains unidentified. The "disable
`ShapeburstFill` entirely for headless renders" fix below is therefore still
the correct fix — a narrower "just zero the blur" fix does not work.

**Fixed 2026-09-09:** implemented option 2 below. Options 1 and 3 are recorded
for context but weren't taken.
1. ~~Render with a QGIS 3.34.x install instead of this 4.2.1 dev build~~ — an
   environment change outside this repo, not attempted.
2. **Done.** `resolve_project_path()` in `xyz_tiles.py` now calls a new
   `disable_shapeburst_fill()` on the disposable extracted project, right
   alongside the existing per-symbol-effect stripping, whenever
   `--advanced-effects` is off (i.e. every normal tile render): it sets
   `enabled="0"` on every `<layer class="ShapeburstFill">` element in the
   extracted `.qgs` XML, the same mechanism QGIS itself uses to skip a
   disabled symbol layer at paint time. `style/strassenraumkarte.qgz` itself
   is untouched — QGIS-Desktop still gets the original depth-gradient water
   styling. **Update 2026-10-05:** the ShapeburstFill disabling (on the two
   crashing water layers only) now applies to `--advanced-effects`
   reference renders too. Previously they skipped it and reproduced the
   original OOM hang (RSS climbing past 2.5 GB with no tiles written), which
   made matched-extent reference renders impossible; with the fix a 12-tile
   z17 reference render completes in about a minute. Reference renders
   therefore lack the water depth gradient. Verified: the exact bbox/zoom that
   previously got `SIGKILL`ed (13.4395–13.4498°E, 52.4722–52.4759°N, z18,
   `--tree-mode off` no longer even needed) now completes in ~31s and 40/40
   tiles decode; a stitched, zoomed crop shows parking car icons correctly
   lined up along kerb edges (small evenly-spaced marks parallel to the
   street, matching parallel-parking placement).
3. ~~Leave `ShapeburstFill` in place and accept headless rendering can't
   include it~~ — superseded by (2), which keeps it for desktop/reference use
   while unblocking headless rendering.

This was the answer to "the reason the process stopped has not been
established" a few lines below.

## Current state and evidence

- At 07:47 CEST on September 8, neither PID 3581 nor another `xyz_tiles.py` or
  `render_tiles.sh` process was running. The resumed log ends at global metatile
  862/1192, followed by another allocation/QPicture error, without a completion
  record. The reason the process stopped has not been established.
- The configured extent contains 3,445 tiles at z15, 13,780 at z16, and 55,120
  at z17: 72,345 tiles across all zooms. Corresponding metatile counts are 63,
  238, and 891. Log counters are cumulative across zooms.
- PostgreSQL catalogs estimate about 2.33 million tree rows and confirm a GiST
  index on `tree.geom`. A representative tile query's EXPLAIN uses that index.
  This does not establish query timing or the plan for every actual QGIS query.
- The installed QGIS 4.2.1 runtime reproduced the project-folder error using
  an otherwise empty project; no database layers or map images were loaded.

## Confirmed defects

### P0: Resource expressions resolve against the extraction directory

`resolve_project_path()` loads the QGS from a temporary directory (line 522).
`run()` then sets `setPresetHomePath(style_directory)` (line 576), assuming this
repairs `@project_folder`. In QGIS, `project_folder` comes from the project
filename; `project_home` is a separate variable.

The installed runtime returned:

```text
project_folder: /tmp/strassenraumkarte-review-placeholder
project_home: <repo>/style
icon path: /tmp/strassenraumkarte-review-placeholder/symbols/trees/broadleaved.png
```

Restoring the original project filename made `project_folder` resolve to
`<repo>/style`.

Fix: preserve original project identity after extraction, set the intended home
directory, and construct expression contexts/path resolvers afterward. Validate
static relative assets as well: paths already resolved during project loading
may need a resolver configured before the read. Manage extraction with an
explicit lifetime and clean it up after QGIS releases its project resources.
Preflight evaluated raster/SVG paths, including both tree species, and fail on
missing or unreadable required resources. Checking file existence alone does
not prove successful image decoding.

This is a confirmed resource-path defect, not proof that it explains the
512 MB rejection or every historical corrupt tile.

### P0: Render and write failures can be recorded as success

`render_metatile()` waits for the job, then writes tiles without checking
`job.errors()` (lines 459–475). The Qt callback discards painter warnings
(lines 118–128), and the allocation/QPicture errors visible in the log do not
invalidate the metatile. `save_tile_image()` ignores the Boolean return from
both image-save calls (lines 401–403).

Fix: collect job errors and per-job Qt diagnostics, retain the first example
and counts of repeated messages, and reject a metatile with known image
allocation/decode or painter failures. Do not raise exceptions from the Qt
callback itself; inspect the recorded failure after the job. Check all image
allocations and save results. Make painter/job cleanup exception-safe.

### P0: Resume has no integrity or provenance check

`metatile_already_rendered()` only calls `os.path.isfile()` (line 406). Writes
go directly to final paths. A truncated image, a valid JPEG containing missing
symbols, or a tile from an older style can all be accepted as finished.

Fix: stage writes on the same filesystem, check encoding/decoding and 256×256
dimensions, atomically replace individual files, and commit a metatile
completion record only after every core tile succeeds. Atomic individual files
alone are not an atomic metatile. Completion records must identify the core
bounds and the rendering configuration: project/assets, code/runtime versions,
data generation, CRS/scale, effects, DPI, gutter, format, and quality.

Treat existing outputs as legacy/unverified. Preserve them, inventory their
decodability, and retain a separate list of suspected metatiles. A JPEG decoder
cannot identify all visually incorrect maps. Use a separate output generation
when changing appearance, so resumed output cannot silently mix styles.

### P1: The effects switch does not implement its stated policy

Line 607 clears `UseAdvancedEffects`, but the tree and shrub raster-marker
symbols each retain an enabled drop-shadow stack in the project. QGIS 4.2's
marker path checks the symbol effect's own enabled state and invokes its effect
painter independently. Renderer-level effects also have a separate execution
path. The log's blanket claim that effects are disabled is therefore unreliable.

Fix: define an explicit effects policy, applying it to renderer and symbol-layer
effects recursively, including nested symbols. Report the effective policy and
number of enabled stacks. Preserve an explicit reference mode. Do not silently
remove shadows from an output generation that previously included them.

Measure the cost with and without tree effects. If shadows are required, test
cached/precomputed variants against the intended image, including rotation and
crown sizing. Such variants are an optimization candidate, not assumed exact
visual equivalents.

### P1: ETA uses historical work as current-session throughput

Line 356 divides current-session elapsed time by `done_tiles`, while the resume
branch increments that counter for skipped tiles. This produces the observed
19-minute ETA after only two newly rendered metatiles took about 52 minutes.

Fix: separate discovered/verified/skipped/newly rendered/failed counters. Use a
monotonic clock and measured new work for throughput, with estimates by zoom
and a range reflecting recent variation. Emit timestamped records with z,
core bounds, elapsed render/write time, warnings, and memory. Keep overall and
per-zoom progress distinct.

## Risks and hypotheses requiring validation

- **Allocation failure:** the log contains `QImageIOHandler: Rejecting image as
  it exceeds the current allocation limit of 512 megabytes`, followed by
  `QPicture::play: Format error`. A full 8×8 core plus one-tile gutter has a
  2560×2560 ARGB image, about 25 MiB. Original tree PNGs are 678×702 and 405×419.
  Identify the failing internal image/effect before considering allocation-limit
  changes. A Qt allocation-limit rejection is not itself proof that physical
  RAM allocation failed.
- **Tree dimensions:** QGIS supports the tree's data-defined `width`; changing
  its name is not an established fix. Generated crowns are about 6.8–21.25 m
  before rounding, or about 9–29 pixels at z17 for this extent. Explicit OSM
  crown values bypass the importer's clamp for inferred values. Audit finite,
  positive values and report outliers before choosing bounds. Exclude stumps
  when checking for missing crowns.
- **Nondeterministic fallbacks:** tree/shrub style expressions still use
  `randf()` for missing/zero diameters. Import and web preparation normally
  populate those fields, but fallback execution can change appearances across
  overlapping metatiles and retries. Use deterministic identity-based fallbacks
  and a consistent invalid-value policy.
- **Memory growth:** the loop keeps one QGIS process alive for the whole run
  and has no memory budget, periodic worker recycling, or timeout. The observed
  pressure does not prove a particular leak. Measure resident/peak memory and
  system pressure across successive jobs. Use a small supervisor and bounded
  worker lifetimes if retention persists; a paused process still occupies RAM.
- **Silently missing layers:** `collect_visible_layers()` discards invalid
  layers, and startup only fails if none remain. Fail with a list when an
  expected visible layer is invalid; distinguish intentionally hidden layers.
- **Extent and scale:** `project_extent.py:197` can return an extent in its
  original CRS after reprojection fails, while `parse_extent()` ignores the CRS
  suffix and treats coordinates as longitude/latitude. Fail on that mismatch.
  Also freeze the render's Mercator scale for diagnostics/subsets: recomputing
  it from each smaller test bbox changes symbol sizes. The current full-run
  factor (1.6428887066) is close to the database factor (1.6428756088); this tiny
  difference does not explain the long runtime.
- **Runtime reproducibility:** the shell launcher invokes generic `python3`.
  Directly invoking the QGIS bundle's Python failed without its library paths;
  the small reproduction succeeded with explicit bundled paths. Add one
  documented bootstrap/preflight for Python, QGIS providers, Qt plugins, and
  PROJ resources. Database connection preflight must inspect the project layer
  connections, not only environment variables used by helper scripts.
  **Fixed 2026-09-08:** `render_tiles.sh` already resolved a QGIS-capable
  interpreter into `$QGIS_PYTHON_BIN` (with the macOS app-bundle fallback) for
  the main renderer invocation, but `project_extent.py` at line ~251 was
  still invoked with bare `python3`, which crashed on this machine's plain
  Homebrew Python (`AssertionError: SRE module mismatch`) — reproducing
  exactly this documented failure mode. Changed that one call site to
  `$QGIS_PYTHON_BIN`; `--preflight` now completes successfully end to end.
  The broader bootstrap/preflight-documentation and DB-connection-preflight
  asks in this bullet are still open.

## Implementation and validation sequence

1. **Make failures observable and completion trustworthy.** Add structured
   job records, error propagation, atomic output/commit records, and truthful
   resume counters. Add focused checks for save failure, interruption between
   tile writes, invalid image dimensions, changed configuration, an invalid
   required layer, and a resumed run's ETA. Preserve existing tiles throughout.
2. **Repair and validate resources.** Restore original project identity and
   verify expressions, decoded assets, static relative paths, CRS, and runtime
   configuration. Validate from a different working directory and with a QGZ
   extracted elsewhere. Exercise tree species and representative SVG/textures.
3. **Isolate the expensive/failing operation.** Use one worker and separate
   diagnostic output. Start with a small sample within the suspect metatile,
   then expand only if necessary. Compare corrected resources with tree effects
   on/off, and the full layer set with the tree layer omitted. Hold bounds,
   output dimensions, scale, and deterministic values constant. Record total
   render time and layer-isolation timings; `perLayerRenderingTime()` is not
   exposed through the documented Python bindings, so do not depend on it.
4. **Validate at production geometry.** The first new metatile after resume
   was global 861: z17 core x70536–70543/y43016–43023; with gutter,
   x70535–70544/y43015–43024. Global 860 was skipped in zero seconds, so its
   following warning must not be attributed to that skipped job. Reproduce at
   the original 8×8 geometry before concluding a small test fixed the problem.
   Include forest, dense urban, and mixed scenes across z15–z17, with neighboring
   metatile comparisons for symbols, effects, and label seams.
5. **Bound memory and optimize from measurements.** Add a graceful stop after a
   completed metatile and supervisor-enforced limits for hung or oversized jobs.
   Retry only a bounded number of times and preserve failure records. Compare
   metatile sizes only after the bottleneck is known: a 4×4 core with the same
   gutter draws 36 tiles for 16 outputs (2.25× area), versus 100 for 64 (1.5625×)
   at 8×8. Smaller jobs reduce buffer size but increase repeated work. Keep one
   worker initially; increase concurrency only with measured memory headroom.
6. **Recover and resume.** Visually audit legacy outputs across all rendered
   zooms, including regions dependent on external assets. Repair affected
   metatiles into a validated generation, retain previous output for rollback,
   then resume remaining work using committed records. Estimate completion
   from representative successful jobs. Do not declare a speedup or healthy
   output from file counts alone.

## Sources

- [QGIS project variables](https://raw.githubusercontent.com/qgis/QGIS/release-4_2/src/core/project/qgsproject.cpp)
- [QGIS marker effect execution](https://raw.githubusercontent.com/qgis/QGIS/release-4_2/src/core/symbology/qgsmarkersymbol.cpp)
- [QGIS raster-marker size/width handling](https://raw.githubusercontent.com/qgis/QGIS/release-4_2/src/core/symbology/qgsmarkersymbollayer.cpp)
- [QGIS renderer job errors and timing API](https://api.qgis.org/api/classQgsMapRendererJob.html)
- [Qt image allocation limit](https://doc.qt.io/qt-6/qimagereader.html#setAllocationLimit)
