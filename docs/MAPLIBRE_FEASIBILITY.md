# MapLibre GL JS feasibility research

This document records findings from an investigation into whether/how the
Straßenraumkarte QGIS style could be ported to a web-based interactive map
(MapLibre GL JS + vector tiles), as an alternative or complement to the
current PyQGIS raster-tile pipeline (see `ARCHITECTURE.md`).

## Why this investigation happened

A generic ("could this be done at all") assessment initially concluded a
MapLibre port would need to "substantially reimplement" the visual identity,
with some effects possibly unreproducible, and treated QGIS's project format
as largely opaque. That's too pessimistic in general — `.qgz` is inspectable
XML and QGIS's renderer is open source — but a generic assessment can't say
*how much* of a specific 338k-line, 256-layer project is actually hard to
port versus trivially portable. Two research passes unzipped and empirically
inventoried `style/strassenraumkarte.qgz` to answer that concretely, rather
than relying on general priors about QGIS projects.

**This substantially changed the risk ranking** — see below.

## Key architectural insight

This project's SQL pipeline (`data/processing/sql/`, ~30 scripts) already
does an enormous amount of precomputation before QGIS ever renders anything:
geometry derivation, attribute derivation, even label candidate
selection/deduplication/zoom-banding. The natural MapLibre-porting strategy
is a direct extension of this existing pattern: **push more of what QGIS's
style/expression engine currently computes inline into that same SQL layer
as precomputed columns, and let the client-side renderer (MapLibre) stay
"dumb"** — the same philosophy this codebase already applies to QGIS itself.

## Inventory: `style/strassenraumkarte.qgz`

### Renderers
`RuleRenderer` 95 (mostly trivial `"class"='x'` filters — portable to SQL
columns / MapLibre `match` expressions), `singleSymbol` 94,
`categorizedSymbol` 60, `nullSymbol` 7 (label-only carriers). No
`graduatedSymbol` anywhere.

**256 maplayers ≠ 256 unique styles.** Most highway layers are one template
(`highway (unlayered)`, ~32 layers) cloned 6× by
`style/update_highway_layered.py` for bridge/tunnel `layer=*` SQL filter
bands. Real unique style logic is closer to ~40–50 distinct configs.

### Symbol layer types

| Type | Count | Portability to MapLibre |
|---|---|---|
| SimpleLine | 1058 | Trivial — `line` layer |
| SimpleFill | 835 | Trivial — `fill` layer |
| SimpleMarker | 803 | Trivial — `circle`/`symbol` layer |
| SvgMarker | 185 | Portable — sprite sheet + data-driven `icon-image`/`icon-rotate`. Includes ~42 parked-car SVGs (`style/symbols/cars/`), selected via `model + '_' + colour + '.svg'` string concat, rotated via a closed-form angle expression — confirmed fully portable |
| RasterFill | 133 | Texture fills (`style/textures/`) — portable via `fill-pattern`, except rotation: MapLibre has no `fill-pattern-rotate`. The core `highway_area` case is now implemented with SQL-derived 15° buckets and 849 ground-scaled sprite entries; the remaining RasterFill users still need the same explicit treatment. |
| MarkerLine | 59 | Portable via SQL geometry where a literal marker transform is required. The live `road_marking_way` sharks-teeth case is implemented as 164 polygons with QGIS's exact interval, 4-map-unit averaging window (a ±2-map-unit radius), triangle, offset, colour, and six-stratum order under golden-value audit. |
| LinePatternFill | 44 | Portable |
| HashLine | 42 | Tick marks (railway ties, lane-separator hatching) — no direct MapLibre equivalent. Same class of problem this repo already solves in SQL for crossing stripes (`processing/sql/helper/crossing_stripe_polygons.sql` generates literal stripe geometry) — same approach applies |
| CentroidFill | 42 | Portable via a SQL-computed centroid-point layer + symbol layer |
| RasterMarker | 25 | Portable via sprites |
| PointPatternFill | 15 | Portable |
| FontMarker | 14 | Portable via `text-field` + icon font, or precomputed glyph sprites |
| ShapeburstFill | 4 | Niche (`roof shape`, `water body` only) — no equivalent, low impact |
| GradientFill | 3 | Niche (`roof shape` 3D shading only) — no equivalent, low impact |

Zero `SVGFill`, zero `GeometryGenerator` anywhere — all geometry
manipulation already lives in SQL, none in the style itself.

### Data-defined properties
3,781 active expressions. Vast majority are `@mercator_scale * n` unit
scaling — this exists because QGIS renders in real map-unit metres with a
`1/cos(latitude)` correction; MapLibre's zoom-based paint-property
interpolation is a different mechanism for the same visual goal, so most of
this scaling logic is reconceived rather than ported 1:1.

Genuinely hard: complex per-feature dash-array/marker-spacing expressions
(`array_foreach`/`string_to_array`/nested `CASE` over a `dasharray` column)
and `$length`-based branching — need precomputing into literal tile
attributes, consistent with this project's existing SQL-precomputation
pattern. ~30 distinct conditional icon/texture-selection expressions
(building file paths from attributes) — bounded work to move into a
precomputed `symbol_name` SQL column.

### Blend modes / opacity / effects
Blend modes: 100% Normal — non-issue. Opacity: simple per-layer constants —
trivial.

**Paint effects (drop shadow / inner shadow / glow): 173 of 214 effect
stacks enabled — the real porting gap, not previously identified.**
`dropShadow` on 93 (mostly street-furniture/POI icons, foreground+
background). `innerShadow` on 63, **including all 7 of the z14–z20
`highway_area` surface-texture zoom-band layers** — this gives carriageway
textures their "recessed pavement" look, which is core to this style's
architectural-plan identity, not decoration. `outerGlow`/`innerGlow` on 9
combined (`landuse` only). MapLibre GL JS has no native equivalent for any
of these. Icon shadows could plausibly be pre-baked into sprite PNGs; the
surface-fill inner-shadow is harder since it's parametric over arbitrary
polygon shapes at every zoom, not a fixed-size icon.

### Zoom-banded raster fills
`highway_area` surface textures use discrete QGIS scale-visibility bands
(z14...z20, 7 layers) rather than one continuous formula — maps naturally
onto MapLibre's inherently zoom-stepped system. The vector preview now uses
the exact QGIS PNGs, direct alpha values, and 3/4.5/6/8.5/11 m pattern widths
at each band. `web_texture_rotation.sql` supplies deterministic angle suffixes
and `scripts/audit_surface_textures.py` checks every live combination on both
sides of each band boundary. The 15° rotation quantization and axis-aligned
sprite seam remain deliberate MapLibre limitations, not continuous-angle 1:1.

### Labeling
~13 distinct label kinds project-wide. `label_highway`/`label_waterway` are
fed pre-dissolved, pre-split-by-zoom-band, pre-deduplicated geometry from
`processing/sql/label_highway.sql`/`label_waterway.sql` — QGIS's labeling
engine barely makes a placement decision beyond "does the curved text fit
along this already-correct line." Project-wide: `priority` takes only 2
values ever (5/7) across 78 instances, `zIndex` always 0 — no elaborate
tuning or draw-order tricks. True multi-candidate search
(`OrderedPositionsAroundPoint`) used exactly once (peak labels), mapping
~1:1 onto MapLibre's native `text-variable-anchor`. Curved line-following
text used by exactly 3 layer kinds — MapLibre's `symbol-placement: line` is
a reasonable native approximation.

The one real cross-engine risk: `place_node`/`place_polygon` can both
produce a label for the same real-world place — needs SQL-side
deduplication (consistent with this project's existing dedup patterns, e.g.
`processing/sql/helper/road_marking_merge_connected_markings.sql`) or an
explicit MapLibre `symbol-sort-key` tie-break.

**Conclusion: labeling is a small practical obstacle here, not the biggest
one** — nearly all the hard placement work already happens in SQL.

## Revised risk ranking

| Technique | Generic/initial assessment | What this project's inventory shows |
|---|---|---|
| Labels | Treated as the biggest obstacle | Smallest — SQL already did the hard work |
| Rotated texture fills | Genuine issue | Source trivial (1 existing column); only the rendering *mechanism* is missing from MapLibre's style spec |
| Car SVG symbols | Solvable | Confirmed fully portable |
| **QGIS paint effects (shadows/glows)** | Not identified | **The real blocker** — touches core carriageway-surface rendering |

## Architectural decision: vector-only output

The earlier investigation proposed a raster-hybrid source for highway inner
shadows. The current product requirement supersedes that proposal: the
MapLibre style must use MVT vector sources, not a raster basemap/overlay.
Accordingly:

1. **Icon/marker shadows (93 layers)**: bake into sprite PNGs at
   authoring time. Zero runtime gap.
2. **Glow effects (9 `landuse` layers)**: flatten to a semi-transparent
   halo/outline layer — narrow, decorative usage, not worth more.
3. **Highway-surface `innerShadow` (7 layers, the actual crux)**: approximate
   with additional vector outline/fill layers, or record the effect as a
   known parity gap. Standard MapLibre cannot reproduce QGIS's parametric
   arbitrary-polygon inner shadow exactly. Do not claim 1:1 parity for these
   layers unless a vector/custom-renderer solution is implemented and matched
   renders prove it.

See `docs/MAPLIBRE_PARITY.md` for current measured coverage, the verification
workflow, and the remaining layer inventory.
