# MapLibre parity status

## Honest status

`web/style.json` is a **vector-only, verified subset** of the QGIS project. It is not yet a 1:1 port of the complete map.

- 44 Martin/PostGIS sources are represented by 530 MapLibre style layers. One
  source is SQL-derived sharks-teeth polygon geometry for the represented
  `road_marking_way` table.
- The QGIS layer tree has 39 distinct enabled source tables (223 enabled layer instances; most of the repeated instances are bridge/tunnel `layer=*` clones).
- Current source-table coverage is 39/39 (100%). The port includes 107,370
  feature-node icons, 407,413 late-zoom house-number labels, 59,381
  SQL-derived tactile-paving markers, 22,441 separation markers, 131,521
  barrier-node markers, and 29,839 QGIS-sized road arrows. Run
  `python3 scripts/audit_maplibre_parity.py --require-full-parity` to make
  missing tables, effects, non-native techniques, scale-boundary checks, and
  unresolved bridge/tunnel order fail together.
- There are no MapLibre `raster` or `raster-dem` sources. Geometry and attributes arrive as MVT (`application/x-protobuf`). The tree crowns are the original QGIS PNG marker artwork in a MapLibre sprite; that is an icon applied to vector points, not a raster basemap/tile layer.

The preview deliberately says “verified subset.” Do not describe it as 1:1 until the strict coverage audit passes and matched-extent render comparisons pass at every supported zoom.

**The audits check the style against the QGIS XML, not against pixels.** Between
2026-09-08 and 2026-10-04 `web/style.json` was rejected outright by MapLibre
(42 `fill-pattern` expressions used `["zoom"]` inside `concat`), so the preview
rendered nothing while every audit passed. Always load the style in a real
MapLibre (`scripts/capture_maplibre_block.js` reports style errors) and look at a
side-by-side with `scripts/compare_render_blocks.py`.

## Zoom convention

QGIS tiles are 256 px raster tiles; MapLibre uses a 512 px world, so MapLibre
zoom Z has the ground resolution of raster zoom Z + 1. Everything derived from the
QGIS map (ground-metre sizes, scale-based visibility, texture bands) is authored
in raster zoom units and stored in `web/style.json` shifted by one:
`style_maplibre(Z) = style_raster(Z + 1)`, i.e. `0.34385 px/m` sits at stop 14, not
15. Without the shift every ground-metre size (tree crowns, line widths, dashes,
markers) rendered at half size and every threshold appeared one zoom too late.

- `scripts/zoom_convention.py` holds the transform; the file records its convention in
  `metadata["strassenraumkarte:zoom-convention"]` (`maplibre-512`).
- `scripts/build_maplibre_strata.py` authors its templates in raster units and converts
  them; it refuses a style that is not `maplibre-512`.
- The audits load the style converted back to raster units (their QGIS-scale logic is
  unchanged) and `audit_maplibre_parity.py` additionally checks the stored file against
  real 512 px geometry (`check_ground_scale_convention`).
- To compare with a QGIS raster tile at zoom z, view MapLibre at zoom z - 1
  (`capture_maplibre_block.js` does this by default).
- `label_min_zoom` (SQL, raster units) is compensated inside the two filters that
  compare it with `["zoom"]`.

## What is verified

The parity audit derives its expectations from `style/strassenraumkarte.qgz` rather than duplicating them in test fixtures. It currently verifies:

- every style source is vector;
- every `get` property is explicitly exposed in `render/mvt/martin-config.yaml`;
- the `landuse` categorized renderer reads the real `class` column;
- every solid, enabled `landuse` category has the direct QGIS symbol-layer RGBA value;
- disabled/non-solid categories and unmatched values do not receive a plausible-looking fallback color;
- `highway_area` rule colors and unmatched-value behavior;
- direct building/water/building-shade fill colors and building symbol opacity;
- waterway and service-road colors, opacity, and ground-metre line widths;
- QGIS label font/halo colors, point-to-CSS-pixel sizes, and the scale-dependent place/highway opacity changes;
- all five `highway_area` RasterFill rules: original texture file, alpha, ground-unit size, direction versus direction+45, z14-z20 pattern bands, and all 15-degree sprite buckets;
- pitch-surface RasterFill categories, sandpit, wetland, fountain, and water
  overlays:
  exact source images, QGIS opacity, pixel-versus-ground-unit scaling, and
  paving-stone rotation buckets;
- QGIS's six bridge/tunnel strata in bottom-to-top order (`<=-2`, `-1`, ground, `+1`, `+2`, `>=3`), with service lines, highway fills/textures, marking polygons, marking lines, and derived marking symbols interleaved inside every stratum;
- the sharks-teeth MarkerLine's dash-derived count/interval/initial offset, 4-map-unit averaging window (a ±2-map-unit radius), 180-degree normalized QGIS triangle, rotated quarter-size offset, colour fallback, and stratum selection;
- effect-stack colors cannot be mistaken for source symbol colors, because the extractor only reads direct `layer/Option/Option` values.

Additional corrections include deterministic tree crown/rotation fallbacks, an area-derived `place_polygon.label_min_zoom` proxy for QGIS's `$area / @map_scale` condition, and the full live road-marking dash corpus. Served PBFs were decoded to verify the derived fields themselves: a tree retained its real 6.2 m crown and -10° rotation, a square carried `label_min_zoom=17.13797`, a real `paving_stones` polygon carried QGIS direction 52° with the expected `direction+45` bucket `r090`, and a z18 sharks-teeth tile carried and rendered all 11 expected triangle polygons with only the ground stratum selected.

The generated sprite has 939 entries: the original tree crowns, 26 QGIS
feature-node SVG icons, 20 aspect-specific QGIS road-arrow variants, plus the
original QGIS surface PNGs at seven ground-scaled zoom bands and all required
rotations. A live z18 browser probe at Rathausstraße selected the
paving-stones texture layer and reported no MapLibre errors.
`scripts/audit_surface_textures.py` currently checks 2,548 distinct live
combinations covering 90,400 features on both sides of every z14-z20 boundary.
The road-marking audit independently recomputes all 164 sharks-teeth vertices
from the 34 live source lines; its current maximum error is below `1e-9` map
units.

## Bugs found by the audit

The previous preview looked plausible but was not a faithful port:

1. `landuse` initially read a nonexistent `landuse` property instead of `class`.
2. Descendant XML color searches picked colors from nested paint effects for buildings, water, and 11 land-use categories.
3. The QGIS `landuse` categorized renderer has no default category, but MapLibre painted all unmatched values tan. This incorrectly affected `construction`, `motorcycle_parking`, and 7,379 `scrub` features in the current database. `scrub` is explicitly disabled in that renderer and styled by a separate QGIS layer.
4. `highway_area` also had no QGIS ELSE fill, but MapLibre painted unmatched categories gray. This incorrectly filled thousands of `parking_space` and `traffic_island` features.
5. `outdoor_seating` was painted solid blue even though blue belongs to a `SimpleFill` whose fill style is `no`; the visible QGIS symbol is a pale-green line pattern.
6. `shoal` lost its 50% alpha, buildings lost their 0.7 symbol opacity, and tree stumps received fake 6 m crowns.
7. Road-marking widths in ground metres were passed directly to MapLibre as pixels, and polygon restrictions were blanket-filled instead of following QGIS rules.
8. Place labels ignored QGIS value/scale rules, so suburb labels such as Britz/Buckow/Rudow appeared at z12 even though their QGIS band starts at z13.
9. Place, highway, and waterway labels initially omitted QGIS's 2 pt, 75%-opacity buffer; waterway foreground/background colors also need to invert for stream/ditch/drain.
10. Double-line handling missed the live `barred_area;solid` stroke and treated mixed `dashed;solid`/`solid;dashed` sides symmetrically.

These are exactly the sort of errors a screenshot from one plausible-looking area will not reliably expose.

## Remaining gaps

Every enabled QGIS source table is now represented. Remaining parity work is
the QGIS renderer techniques enumerated below, not source-table coverage.

Even on represented tables, these QGIS techniques still need separate MapLibre layers, sprites, or SQL-derived geometry:

- remaining land-use pattern work: exact 65 m gravel scale, surface rotations,
  `outdoor_seating`/construction hatches, scrub effects, and dog-park symbols;
- restriction hatching/crosshatching/chessboards (sharks-teeth markers are now SQL-derived and verified);
- highway surface **inner shadows** (the RasterFill textures and six-layer bridge/tunnel interleaving are now represented);
- building shade and non-flat roof-shape rendering;
- remaining labels and icon systems;
- barrier-way MarkerLine details are SQL-derived as bollard circles, palisade
  dots, and retaining-wall triangles, with count, dimension, and orientation
  audits against their QGIS configuration;
- barrier-node marker refinements: QGIS semi-circle gates, paired cycle-barrier
  lines, and the rock raster still need literal/sprite shapes; category, size,
  color, outline, and stratum parity is implemented;
- QGIS paint effects. Standard MapLibre has no exact arbitrary-polygon inner-shadow/glow equivalent. A vector-only port must approximate these with extra vector line/fill layers or accept a known visual difference. A raster-hybrid source would violate the current vector-only requirement.

## Parity check tool

`./scripts/parity_check.py --tag NAME [--baseline render/parity-runs/OLD/classes.csv]` runs the
whole six-block measurement in about two minutes (QGIS reference tiles and the original tiles are
cached in `render/parity-reference/`, git-ignored; missing QGIS tiles are rendered on first use).
It captures the MapLibre blocks, runs `compare_feature_classes.py` and prints the pixel-weighted
mean ΔE to QGIS and to the original, the share of pixels at or below ΔE 2.3, the classes above 5,
and with `--baseline` every class that moved by 0.5 or more. `--paint '{"layer": {"fill-opacity":
0.5}}'` and `--hide 'layer-*'` try an idea without editing `web/style.json`, `--base URL` captures
a copy of another style (serve `git archive HEAD web` on another port) for a same-session A/B.
Restart Martin after any database change: it caches tiles.

## Verification workflow

For every ported QGIS layer:

1. Identify the actual QGIS datasource table, SQL subset, renderer, rule order, scale band, and layer-tree draw position.
2. Read renderer options only from the direct symbol layer. Inspect effects separately.
3. Check each referenced property against both `information_schema.columns` and the decoded MVT payload.
4. Use transparent fallback unless QGIS has an explicit ELSE/default symbol.
5. Run `node scripts/capture_maplibre_block.js --check-only` (fails if MapLibre rejects the style or a tile errors), then `python3 scripts/audit_maplibre_parity.py`, `python3 scripts/audit_road_markings.py`, `python3 scripts/audit_surface_textures.py`, and MapLibre’s official style validator.
6. Compare QGIS and MapLibre renders at identical bounds and pixel size at every scale transition, including examples containing every newly ported category and sharp double-line junctions. A one-location screenshot is not sufficient.

Reference tiles must include QGIS effects, unlike normal headless production
tiles. PyQGIS works with the QGIS app bundle's Python (`render_tiles.sh` bootstraps it;
pin a bundle with `QGIS_APP=/Applications/QGIS-final-4_2_1.app`):

```bash
./render/render_tiles.sh --bbox xmin,ymin,xmax,ymax --zmin 17 --zmax 17 \
  --format png --advanced-effects --out /tmp/strassenraumkarte-qgis-reference
```

`--advanced-effects` still disables the two water ShapeburstFill layers, which exhaust
memory in QGIS 4.2.1 (see `docs/RENDER_RECOVERY_PLAN.md`), so reference renders lack
the water depth gradient.

**Colour ground truth.** The original project publishes its own tiles at
`https://tiles.osm-berlin.org/strassenraumkarte/{z}/{x}/{y}.jpg` (JPEG). They are
the reference for what "identical" means; fetch only small blocks. Notes:

- The committed QGIS project has `roof shape` and `building_shade` unchecked, so its
  buildings are flat grey like the original. `docs/example.png` was made with
  `roof shape` on (pink roofs) and is not the target look.
- QGIS 4.2.1 renders the committed project almost exactly like the original (building
  colour 194 vs 202, ground, grass and carriageway within 1-2 levels).

Measured comparison (same 3x3 block, mean absolute RGB difference vs the original):

```bash
node scripts/capture_maplibre_block.js 17 70425 43010 3 3 /tmp/ml.png
./scripts/compare_render_blocks.py <dir with 17/x/y.jpg> 17 70425 43010 3 3 /tmp/ml.png /tmp/cmp
```

Fine detail (labels, crowns, kerb cars) is a few pixels off by nature, so judge area tone
on blurred images as well. The audit also hard-codes two deliberate departures from the
QGIS XML, both measured against the original: opaque building fill (the original's 202 is not
reproduced by the XML's 0.7 alpha without QGIS's layer effect stack) and no
`building_shade`/`roof shape` layers.

## QGIS scale to zoom

Scale-based QGIS rules (label bands, label opacity steps, the `$area / @map_scale` and waterway
label conditions, the 1:1000 housenumber limit) are converted to zoom with the scale the renderer
really uses: `render/xyz_tiles.py` renders EPSG:3857 at 96 dpi and QGIS takes the scale from the
extent in map units, so the scale at tile zoom z is `156543.034 / 2^z * 96 / 0.0254`, i.e. **1:9028
at z16** (`scripts/qgis_scale.py`, `\set qgis_scale_at_z16` in `params_web.sql`). The earlier
convention "z16 == 1:8000" put every boundary 0.174 zoom levels too low, so e.g. the
1:4000-1:16000 neighbourhood labels showed at z15 although QGIS (1:18056 there) hides them. The
label layers' `minzoom`/`maxzoom`, the opacity steps and the SQL-derived `label_min_zoom`
(place_polygon, label_waterway) use the corrected value; the audit and the SQL read one constant.
Fractional `minzoom` values are intended (MapLibre supports them).

## Thin lines

QGIS draws a line thinner than a pixel with coverage proportional to its width; MapLibre's
line shader adds a half-pixel antialiasing outset, so a 2 cm building seam or a 15 cm road
marking is drawn at about 50 % alpha across ~1 px, two to three times heavier than QGIS (31 of
the 50 line layers are thinner than 0.5 px at z17). `scripts/thin_lines.py` multiplies each line
layer's opacity by `w / (w/2 + 0.5)^2` for `w < 1 px` (one interpolation stop per integer zoom,
generated from the layer's own width stops); `build_maplibre_strata.py` applies it to every line
layer except those with offset/blur/gap-width/pattern/gradient. The QGIS opacity stays in
`metadata["strassenraumkarte:line-opacity-base"]`, which the audit reads. Measured on three areas
at z15-z18 it lowered the raw difference to the original everywhere (e.g. Hermannplatz z17 10.2 -> 8.7).

## QGIS layer opacity

A QGIS layer has an opacity of its own on top of its symbols' alpha (the layer is flattened and
composited at that opacity). The style only carried the symbol alpha, so road markings, separation
markers, path casings (0.67), railway ties (0.4), pitch markings and landscape lines (0.5) and tree
trunks (0.75) were drawn 25-60 % too strong; the red cycle-lane colour was 0.45 instead of
0.45 x 0.67. `scripts/layer_opacity.py` lists the factors (`LAYER_OPACITY`, each tied to a QGIS
layer name) and `build_maplibre_strata.py` multiplies them in, keeping the symbol-level opacity in
layer metadata (idempotent; `thin_lines` includes the factor in its compensated expression). The
audit checks every entry against the project and warns about other enabled QGIS layers with an
opacity below 1 (tree crowns are tuned separately; construction and dog-park are not ported).

## Tree crowns

QGIS applies the `tree crown` layer opacity (0.25) to the *flattened* layer, so a crown is 0.25
over the background however many crowns overlap it. MapLibre has no group opacity: `icon-opacity`
is per icon and k overlapping crowns compound to `1 - (1 - a)^k`. A single value cannot satisfy
both cases: a per-zoom curve tuned on dense woods (Hasenheide) left isolated street trees far too
faint (Werbellinstr. crowns 179,196,169 against QGIS 156,184,140).

`web_tree_overlap.sql` therefore stores `tree.crown_overlap` = k, the mean number of crowns covering
a point of this crown (1 + other crowns' circle-intersection area / own area; effective radius
0.45 * diameter_crown, the extent of the crown artwork), and `tree-crown` uses
`a = 1 - 0.75^(1/k)`: isolated crowns get QGIS's 0.25 and k stacked crowns add up to 0.25 again
(median k is 1.6 in Berlin, dense canopy 2-3). The drop-shadow disc scales with it. Isolated crowns
now match QGIS within 4.4 levels (were 21.6), and dense canopy is closer to QGIS at z15-z18. The
original tiles are lighter than QGIS at low zoom, so against them low zooms got ~1 level worse.

**Group opacity (2026-10-07).** QGIS fades the *flattened* crown layer once (layer opacity 0.25),
so overlapping crowns merge into one canopy and each keeps its branch detail; per-crown opacity in
MapLibre made overlaps visible as darker lenses and washed out crowns in groups. Layers with
`metadata["strassenraumkarte:group-opacity"]` (now `tree-crown`, 0.25) are drawn by `web/index.html`
at full opacity in their own transparent map canvas, stacked in style order between the canvases of
the layers below and above, and faded with CSS opacity; the first canvas is interactive and drives
the others' cameras (`window.__maps`; `capture_maplibre_block.js` waits for and overrides all).
A plain MapLibre client ignores the key and falls back to the per-crown opacity. The crown sprite
bands were also widened 1.5x (now 1.5x the on-screen width of a 12 m crown): the branches had been
lost on larger crowns, which were enlarged from too small an image. Red-dominant crown pixels
z17/z18: QGIS 0.5 / 2.1 %, before 0.3 / 1.1 %, now 0.8 / 4.0 % (2x bands: 1.0 / 4.8 %).

**Crown sprites per zoom band.** MapLibre samples sprites without mipmaps, so the 339 px crown
artwork drawn at ~11 px (z17) was point-sampled: its red-brown details (21 % of the artwork's
pixels) showed as red speckle (9.9 % of crown pixels vs 0.1 % in QGIS) and the crowns were twice as
grainy. `build_maplibre_sprite.py` now also emits `tree-*-b14`...`-b19`, the artwork shrunk with
averaging to ~1.5x the on-screen width of an 8 m crown at that MapLibre zoom, each with a
fractional `pixelRatio` so its logical size (and the style's `icon-size`) is unchanged;
`tree-crown` picks the band with a zoom `step`. Red speckle 0.0 %, grain 71 (QGIS 64, was 125).

**Global crown factor (0.7, now 0.9 — see "One texture per pixel").** After the banded sprites (averaged artwork is denser than the
point-sampled one) the crowns were again darker and greener than QGIS (median 151,186,126 vs
159,191,134) and dragged down every class drawn under trees. A grid over a crown-opacity factor
(1.0/0.85/0.7/0.6) and the shadow-disc strength (0.06-0.4) on the Werbellinstr. z17 and
Hermannplatz z16 blocks put the optimum at 0.7 x crown opacity with the shadow unchanged (0.28):
tree ΔE 3.0 -> 1.1, park 3.9 -> 1.6, dog park 6.5 -> 3.7, retaining wall 7.2 -> 6.2. At 0.6 the
crowns overshoot (tree ΔE 2.7, too light).

## Scrub, rocks, paths

- **Scrub** is excluded from the QGIS `landuse` renderer and drawn by its own layer `scrub (width
  shade)` directly above it (fill 196,216,175 plus the grass texture and a drop-shadow "width
  shade"). `landuse-scrub-fill` ports the fill; the shadow effect is not ported. Park borders and
  courtyards that looked white are green again.
- **Rocks** (`barrier=rock`) are a 0.6 m `rock01.png` raster marker at alpha 0.67 in QGIS; the style
  drew them as white circles with a dark outline (dark specks). They are now a 0.3 m-radius grey
  (`#a6a6a6`, the image's mean colour) circle at 0.67 without outline.
- **Paths** follow QGIS's `path (way, fill)` and `path (way, casing)` rules: fill colour by `class`
  (sidewalk/crossing/link `#ebedd6`, other footways the data-defined `#e6e2bc`, cycleways `#bfbecf`,
  informal `#e1e3bd`; a cycleway that is a sidepath (`is_sidepath=yes`, 4,600 ways) matches only
  QGIS's "cycleway fill" rule, which is *grey* `#d2d1d2` at `width` (default 1 m): the lilac
  `#bfbecf` belongs to the footway rule that stand-alone cycleways also match and that excludes
  sidepaths), fill width from the `width` attribute minus 0.2 m, and two 0.2 m edge
  lines (`line-gap-width`): solid light grey at 0.5 for sidewalks/sidepaths, dark dashed 0.6/0.6 m
  for footways, 0.6/2.4 m for informal paths. Only the casing layer has the 0.67 layer opacity.

## Simple-marker street furniture

QGIS draws most `feature_node` street furniture with SimpleMarker layers (ground-metre,
data-defined sizes); MapLibre had nothing for them: 85,000 street lamps, 8,600 street cabinets,
7,000 Stolpersteine, vending machines, advertising columns, wells, charging stations, signs,
clocks and others were missing (the class tables barely show it: the markers are 0.3-1.6 m).
`scripts/marker_sprites.py` lists the 28 symbols and renders each with QGIS itself into a sprite
(64 logical px = the marker's ground-metre `box`); `web_symbol_names.sql` selects the sprite,
box size and rotation (direction + 90 for cabinets/vending machines, + 180 for signs, ...) per
feature, and the new `feature-node-marker-icons` layer draws them from MapLibre z15.5, fading in to full opacity by z18 (QGIS draws the sub-pixel shapes faintly; an un-faded sprite minified without mipmaps looked like black specks; raw diff to QGIS 7.02 -> 7.00 on the Werbellinstr. block). Two QGIS
facts worth knowing: line-shaped markers (`cross2`, `line`) take the *outline* colour, so a lamp's
"red cross" is grey; and marker offsets have y pointing down. `audit_marker_sprites.py` checks
sprite names, 64 px size and SQL box sizes. Fire hydrants: a red "H" (own layer from z17.59, QGIS
draws it only at scales <= 1:1500) for underground hydrants, a red ring for pillar/pipe/wall ones;
QGIS's H on a z19 render is a blurrier ~2 px blob than MapLibre's crisp 3 px glyph. Not ported:
the flagpole's "~" glyph, the vertical-panel and arrow sign SVGs, loading ramps, fountain circles.
Global colour numbers do not move (6-block mean 1.895 → 1.895); the effect is visual.
Other node layers were checked class by class against the project: barrier nodes were complete;
added railway signals (QGIS hexagon, 1 m, `#939393`, drawn as an equal-area circle, 7,300) and
landscape rocks/stones (`rock01.png` at 0.67, as grey circles like the barrier rocks). Not ported:
landscape peaks (an SVG, 89) and the polygon/way layers' scale-limited symbols. The same check for
the polygon and way layers found one gap, `barrier=barrier_board` (429 construction barriers: a
0.35 m dark line with a white 0.2 m line and a red 0.2 m line dashed 0.6 m on top), now ported.

## One texture per pixel (landuse)

QGIS draws the `landuse` layer feature by feature, smaller polygons on top (`$area` order), each
with its opaque fill *and* its texture, so a smaller polygon's fill covers the texture below and
every pixel shows one texture. MapLibre draws all fills, then all textures: 88 % of Berlin's grass
lies inside parks, so grass got the texture twice, and park textures showed through parking lots
and yards drawn on top. `web_landuse_texture.sql` stores the visible part of every textured
polygon (itself minus all smaller overlapping landuse) in `landuse_texture`, which the nine
class-keyed texture layers now read. Mean ΔE to QGIS 1.867 -> 1.723 (grass 2.9 -> 0.4, meadow
4.1 -> 0.5, recreation ground 2.7 -> 0.5); to the original 2.06 -> 1.87.

The 0.7 crown factor below had been tuned while textures were doubled, which had hidden too light
forest canopy. Re-tuned: 0.8 / 0.9 / 1.0 give means of 1.686 / 1.655 / 1.631 to QGIS but
1.877 / 1.915 / 2.015 to the original, isolated trees 1.3 / 2.5 / 3.5 and forest 3.2 / 2.2 / 1.3.
**0.9** is the balance (an overlap-dependent factor or a weaker shadow disc did not help).
The factor is a trade-off, not a fit: street trees and cycleways under them prefer 0.7-0.8
(cycleway 3.7 / 5.3 / 6.3 / 7.9 for 0.7 / 0.8 / 0.9 / 1.0), forests 1.0.

**Final setting (2026-10-07): factor 1.0 and no shadow disc.** Side by side, QGIS's crowns read
greener, more solid and "lusher"; the blurred black shadow disc (an approximation of QGIS's drop
shadow) made MapLibre's crowns duller. Measured inside the crowns of the Werbellinstr. block
(1,622 trees): QGIS 158,187,142, saturation 44.8; factor 0.9 with shadow 160,188,144 / 44.2;
factor 1.0 without shadow 158,189,142 / 46.5. The point-sampled tree and cycleway medians prefer
lighter crowns (3.5 and 7.4 now), the crown interiors, forests (1.5) and the mean (1.646) prefer
these.

The remaining large-area differences (sidewalks ΔE 3.4, landuse parking 3.1) are QGIS's building
drop shadows: rendered without effects, QGIS's sidewalks and parking lots match MapLibre within
1.1 / 2.5 over the six blocks and exactly on the Hermannplatz z18 block.

## Landuse surface textures

QGIS's `landuse surface` layer overlays a texture on every `landuse` polygon with a `surface` tag
(4,300 in Berlin, mostly parking lots): asphalt-like 0.06, concrete 0.15, paving stones 0.07, sett
0.12, sand-like (clay, compacted, dirt, earth, fine gravel, gravel, ground, sand) 0.08, grass 0.06,
woodchips 0.1. The style only had class-keyed landuse textures. The `landuse-surface-*-texture`
layers reuse the pitch-surface patterns and opacities (rotation of paving/sett polygons is not
carried: the landuse tiles have `direction`, but no rotation bucket). Mean ΔE to QGIS 1.887 -> 1.872
(same session), landuse/parking 3.3 -> 3.0.

## Calibrated values (not derived from the QGIS project)

- **Embankment** (`EMPIRICAL_OPACITY` in `build_maplibre_strata.py`): ticks x0.24 and line x0.4 of
  the QGIS-derived opacity. Hiding both layers gives 190,208,166 against QGIS 194,201,162; with the
  QGIS values MapLibre reaches 181,199,146 (ΔE 8.7), with the factors 188,202,157 (ΔE 4.3 on the
  sweep, 5.1 in the final run). The line alone barely matters.
- **Bus-platform line**: opacity 0.4 instead of QGIS's 0.5 (class ΔE 8.0 -> 5.7); the blue channel
  then matches QGIS exactly, red and green remain about 8 levels lighter.
- **Pitch fill** follows QGIS's surface/colour/sport expression except `surface=grass`, which follows
  the original (see below).

## QGIS paint effects

`scripts/effects.py` ports QGIS paint effects as blurred outline lines (`line-blur` = width = 2 x
blur, `line-translate` for the offset) generated by `build_maplibre_strata.py`; no extra tile
data apart from merged outlines where needed. QGIS's `offset_angle` is a compass bearing (0 =
north, clockwise): building shadows fall to the north-east for 40°, measured as the darker side
of a ring around every building on z18/z19 renders. The line opacity is 0.75 x the QGIS effect
opacity, set from the luminance profile next to buildings (0.5 too light at the wall, 1.0 too
dark 2-6 px out).

- **Building drop shadow** (#232323, 0.4, blur 2, offset 1 map unit at 40°) along the merged
  outlines of touching parts (`building_outline`, `web_building_outline.sql`, ~80 s for Berlin;
  per-part outlines left dark dots where shared walls meet the outer wall). Mean ΔE to QGIS
  1.646 -> 1.49, to the original 2.05 -> 1.96; sidewalks 3.8 -> 1.1, landuse parking 3.1 -> 1.5.
  Cost on a software renderer: +12 % time-to-idle on a dense z15 overview, +2 % at z18.
- **Building shadows at height steps.** QGIS draws `building_parts_dissolved_height` ordered by
  `height`, so a taller part's drop shadow falls onto the roofs of lower neighbours. The merged
  outline above has no internal walls. `web_building_height_steps.sql` (~10 s; it adds the GiST
  index building.sql leaves out) stores each shared wall between parts of different height as
  straight edges, with the lower part on the left, plus `facing`: the cosine between the
  direction into the lower part and the 40° shadow bearing. `building-step-shadow` and
  `-soft` are two nested bands on that side: 0.567 m wide (blur 0.182 m) at 0.0886, and 1.705 m
  (blur 1.463 m) at 0.0345. Opacity is scaled by `facing`: 0.25 / 0.6 / 1.05 for -1 / 0 / 1.
  They are fitted to *QGIS's* lower-roof luminance by distance from such walls (z18: 15/7/4
  darker 1-3 px out for north-east-facing walls; QGIS 15/9/4.5). The original tiles are
  about half as dark. A first fit to the original (half these opacities) matched it within ~1,
  but the owner wanted the stronger look because it reads as 3D. Full QGIS strength (0.1265 / 0.0493)
  was then too heavy, so the opacities are 0.7 x QGIS (z18: 11/5/3 darker 1-3 px out). Before
  this, those roofs were flat. Class medians and cost don't change measurably.
- **Road inner shadow** (QGIS z14..z20 "blur" layers: innerShadow, blur 0.2 mm at z14 growing
  x√2 per zoom) as two nested bands that lie fully inside the carriageway (offset = width / 2):
  1.5 px at 0.13 and 5.5 px (blur 3.5) at 0.038 at ML z17, x√2 per zoom, faded in from ML z14
  to z15 (QGIS's 1 px blur there is invisible; the shade only made z15 roads too dark). One
  blurred line centred on the edge matched the profile inside but darkened kerbs and sidewalks
  outside; QGIS clips the effect to the polygon. QGIS applies the effect to the whole rendered
  layer, so seams between touching `highway_area` polygons stay unshaded: the bands follow
  `highway_area_outline` (`web_highway_area_outline.sql`, ~80 s), the union per bridge/tunnel
  layer with QGIS's class filter, stored as clockwise rings split into 256-vertex lines (the
  merged network is one polygon of over a million vertices). Luminance 1-5 px inside the edge
  now within ~3 of QGIS on z16-z19 (before: 8-10 too light at the edge, too dark 3-5 px in).
  Same-session mean ΔE to QGIS 1.507 -> 1.531 (barrier_way/kerb 0.8 -> 2.2, a hairline whose
  median follows its neighbourhood; road surfaces and parking 1-2 better), to the original
  1.975 -> 1.952. Cost within noise (z15 overview 24-25 s both, z18 +3-8 %).
- **Water inner shadow** (#a396d9, multiply, blur 4 map units): not ported, because it isn't visible in QGIS.
  On z18/z19 canal edges, QGIS's water luminance is flat from 2 px inside (207, like MapLibre's).
- **Landuse outer glow** (forest/wood/trees/shrub/shrubbery/tundra #c8dbb6, scrub #c4d8af;
  spread 0.75, blur 0.75 map units) as a band entirely outside the ring (`line-offset` = minus
  half the width), drawn *above* the fill: under it, the neighbouring landuse fills covered it
  (wood unchanged). z18 luminance 2 px outside the edge: forest 190 -> 185 (QGIS 183), wood
  183 -> 179 (176), scrub 218 -> 200 (205). QGIS's drop shadows on the same classes (0.33 at 0.4
  map units, 40°) made it too dark there and in the fill's antialiased edge pixel, so they are
  left out. Same-session mean ΔE 1.531 -> 1.527, to the original 1.952 -> 1.942. Cost: z15
  overview +2-6 %.

## Reference decisions (QGIS vs the original tiles)

Where QGIS's own output and the published original tiles disagree, the project owner chose
(2026-10-06):

- **Sports pitches on grass** follow the *original*: its pitches are a uniform pale green
  (218,228,201) whatever the surface, QGIS paints grass pitches saturated (175,214,160).
  `pitch-fill` uses `#e0e8d4` for `surface=grass` (the 0.06 grass texture on top brings the
  median to 217,228,200; ΔE to the original 0.4, to QGIS 19). Other pitch surfaces keep QGIS's
  `#d1d7c6`; the original is a uniform green for those too (ΔE 5-8) but was not followed.
- **Effects** were first left out (2026-10-06); on 2026-10-07 the user asked to port them where
  cheap, see "QGIS paint effects". The roof grey stays the original's (202).

## Data-defined marker and hash sizes

Several SQL-materialised QGIS markers had been ported from the symbol layers' *static* values,
which QGIS overrides with data-defined `@mercator_scale * ...` expressions (static values are
map units, about 0.61 m; the expressions are ground metres):

- **Landscape ticks** (embankment, cliff, earth_bank only; tree rows, stones and rocks have no
  symbol): 1.6 m triangles every 2.4 m from 0.8 m, offset 0.6 m to the left of the way and
  pointing away from it; all values halved for ways shorter than 20 map units, whose line is also
  0.3 m instead of 0.6 m (`planar_length` in the tiles). The old table had 1-map-unit triangles
  pointing along the line, plus 78,000 ticks on tree rows.
- **Hash lengths**: the project sets HashLine lengths through a data-defined `lineDistance`,
  which HashLine ignores (its key is `hashLength`), so QGIS draws the static lengths in map units
  (railway ties span just the rails on a z19 render, not the 2.5 m of the expression).
- **Steps**: 0.06 m `#979c90` strokes every 0.6 m, 1.8 map units long, on top of the normal
  footway fill and casing (steps were excluded from both). **Access aisles**: 0.5 m `#ffffea`
  strokes every 1 m, 2 map units long.
- **Railway ties**: 0.3 m `#a8a8a7` (disused `#b0b0af`) bars every 0.9 m, 2.6 map units long,
  none in tunnels, layer opacity 0.4. They were 0.04-map-unit grey hairlines.
- **Rails**: two 0.24 m lines at +-gauge/2 (0.7175 m default), drawn as one line with
  `line-gap-width`; `#808080`, disused `#8ea08e`, none in tunnels. The style had one centred line.
- **Bridges**: QGIS fills `bridge` and `bridge_shade` with `#e8e8e8`; the style had used the
  disabled outline colour `#dddddd`.
- **Barred areas / restrictions**: the `LinePatternFill` stripes (0.25 m white every 0.75 m at
  `90 - direction` degrees, crosshatch 1.25 m in two directions) are materialised as clipped
  lines in `road_marking_hatch` (`web_road_marking_hatch.sql`). Chessboard is not ported.
- **Bicycle parking points** (also rental and small-vehicle parking): QGIS always draws a 1.5 m
  `#bfbecf` disc at 0.67 and adds the SVG icon only at scales <= 1:750 (MapLibre zoom 18.59); the
  style drew the black icon at every zoom and no disc. Disc colours at z19 now match QGIS within
  1 level. (The polygon variants' symbols, also <= 1:750, are not ported.)
- **Construction sites**: QGIS's `construction` layer (above the street strata and parked cars,
  below trees) hatches `landuse=construction` with 1 m `#ff5300` lines (alpha 0.35) every 2.2 m at
  67 degrees and a 0.4 m outline (alpha 0.65), layer opacity 0.5. The lines are materialised in
  `construction_hatch` (`web_construction_hatch.sql`); the style layers are `construction-hatch` and
  `construction-outline`.

## Fill antialiasing

MapLibre antialiases a fill by drawing a 1 px outline in the fill colour over its edges, so a
semi-transparent fill is composited twice along them. For marks only a pixel or two wide the
doubled edge dominates. `build_maplibre_strata.py` turns antialiasing off for the embankment
triangles, railway ties, zebra stripes and the 0.6 m retaining-wall/bollard markers (`UNANTIALIASED_FILLS`; retaining wall ΔE 10.2 -> 4.5 once the markers stopped being double-painted, found by hiding layers one by one; embankment ΔE 15.1 -> 9.4; zebra stripe area at z19 274 px against QGIS 287, 393 with antialiasing). Road-marking fills
keep it: at z15 the green/red lane colours are visibly more saturated than in QGIS, but
unantialiased they drop out of most pixels instead of tinting them, which measured worse
(cycleway ΔE 4.6 -> 9.8, mean 1.948 -> 1.964). A zoom ramp of the lane-colour opacity (x0.4 at MapLibre z14 up to 1 at z16-17) was tried and
rejected: it improved the blurred z15/z16 diffs to QGIS by about 1 %, but the class table got worse
(cycleway 5.9 -> 6.9, mean 1.895 -> 1.909) because QGIS's cycleway centrelines carry the full
lane colour. The over-saturation at z15 stays an open, small item.

## Multiply-blended road textures

QGIS draws the `highway_area` surface textures (concrete, paving stones, sett, asphalt) through
an effect stack whose source is composited with **Multiply** (`blend_mode` 13), so a texture
can only darken the carriageway. MapLibre has no blend modes; drawing the light concrete texture
normally at 0.35 lightened concrete roads to RGB 178 where QGIS has ~150. Multiplying by a grey
texel `t` at opacity `a` gives `dst * (1 - a(1 - t))`, which is normal blending of black at
alpha `a(1 - t)`. `build_maplibre_sprite.py` therefore emits `surface-*-multiply-*` sprites
(black, alpha `1 - t`) for the highway-area layers, which keep the QGIS opacity. Asphalt is not
grey and keeps its plain texture (it is dark and drawn at 0.06; within ΔE 0.6 of QGIS). Pitch and
landuse surfaces use normal blending in QGIS and keep the plain sprites. The parity audit reads
the blend mode from the project and expects the matching sprite family. Concrete roads went from
ΔE 12.4 to 3.1 and sett/paving classes to 0–1.5.

## Rebuilding generated assets

- **Sprites** (`web/sprite*.png|json`) need QGIS's bundled Python and Qt environment:

  ```bash
  C=/Applications/QGIS-final-4_2_1.app/Contents; P=$C/Resources/python3.12
  PYTHONPATH="$P/site-packages:$P:$P/lib-dynload" QGIS_PREFIX_PATH="$C/MacOS" \
  QT_PLUGIN_PATH="$C/PlugIns" PROJ_LIB="$C/Resources/qgis/proj" QT_QPA_PLATFORM=offscreen \
  "$C/MacOS/python3.12" scripts/build_maplibre_sprite.py
  ```

  Existing icons come out unchanged (same names and sizes); check with a before/after
  diff of the two `sprite*.json` files.
- **Bridge/tunnel strata** in `web/style.json`: `python3 scripts/build_maplibre_strata.py`
  (idempotent; the style must be in the `maplibre-512` convention).
- **Parked cars** are a snapshot of `data/parking/street_parking_points_processed.geojson`. A fresh
  pipeline run creates an empty `parking_cars` table (`web_parking_cars_placeholder.sql`), because
  Martin refuses to start when a configured table is missing; the cars appear after loading.
  After `data/build_parking.sh --publish`, reload them with `./data/load_parking_cars.sh` and
  restart Martin (it caches the table schema).
