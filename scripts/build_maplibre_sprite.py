#!/usr/bin/env python3
"""Build MapLibre sprites from the exact raster assets used by QGIS.

Run this with QGIS's bundled Python so ``qgis.PyQt`` is available.  The tree
PNGs are the exact raster markers referenced by the QGIS project; putting
them in a sprite preserves their texture and transparent margins instead of
replacing them with guessed flat circles.

QGIS RasterFill scales surface textures in ground metres and rotates them by
the feature's ``direction``.  MapLibre has neither ground-unit patterns nor
``fill-pattern-rotate``, so this builder also creates one pattern per z14-z20
scale band and 15-degree SQL rotation bucket.  The original PNG pixels remain
the source of truth.  Rotated variants sample an infinite QBrush texture into
an opaque crop, avoiding transparent corners; the unavoidable axis-aligned
sprite seam is kept infrequent and the QGIS opacities are only 0.06-0.35.
"""

from __future__ import annotations

import json
import math
import os
import re
from pathlib import Path

import marker_sprites
from qgis.PyQt.QtCore import QByteArray, Qt
from qgis.core import QgsApplication
from qgis.PyQt.QtGui import QBrush, QColor, QImage, QPainter, QTransform
from qgis.PyQt.QtSvg import QSvgRenderer


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "web" / "sprite"
TREE_IMAGES = (
    ("tree-broadleaved", ROOT / "style" / "symbols" / "trees" / "broadleaved.png"),
    ("tree-needleleaved", ROOT / "style" / "symbols" / "trees" / "needleleaved.png"),
)
# Pre-shrunk crown sprites per MapLibre zoom band (1x pixel width). The GPU
# samples sprites without mipmaps, so drawing the 339 px crown at ~11 px picks
# individual source pixels: the artwork's red-brown details (21 % of its pixels)
# showed as red speckle and the crowns looked grainy, where QGIS averages them
# away. Each band is ~4x the on-screen width of an 8 m crown and keeps the
# full image's logical size via a fractional pixelRatio, so icon-size is
# unchanged; the style switches image by zoom.
TREE_BAND_WIDTHS = {14: 6, 15: 12, 16: 25, 17: 50, 18: 99, 19: 198}
_LOGICAL_WIDTH: dict[str, int] = {}
FEATURE_ICON_IMAGES = (
    ("icon-tourism-artwork", ROOT / "style" / "symbols" / "tourism" / "artwork.svg"),
    ("icon-amenity-bench", ROOT / "style" / "symbols" / "amenity" / "bench.svg"),
    ("icon-amenity-bench-backrest-no", ROOT / "style" / "symbols" / "amenity" / "bench_backrest_no.svg"),
    ("icon-amenity-bicycle", ROOT / "style" / "symbols" / "amenity" / "bicycle.svg"),
    ("icon-amenity-bicycle-rental", ROOT / "style" / "symbols" / "amenity" / "bicycle_rental.svg"),
    ("icon-amenity-small-electric-vehicle", ROOT / "style" / "symbols" / "amenity" / "small_electric_vehicle.svg"),
    ("icon-amenity-fountain", ROOT / "style" / "symbols" / "amenity" / "fountain.svg"),
    ("icon-tourism-guidepost", ROOT / "style" / "symbols" / "tourism" / "guidepost.svg"),
    ("icon-man-made-manhole", ROOT / "style" / "symbols" / "man_made" / "manhole.svg"),
    ("icon-leisure-picnic-table", ROOT / "style" / "symbols" / "leisure" / "picnic_table.svg"),
    ("icon-amenity-post-box-green", ROOT / "style" / "symbols" / "amenity" / "post_box_green.svg"),
    ("icon-amenity-post-box-yellow", ROOT / "style" / "symbols" / "amenity" / "post_box_yellow.svg"),
    ("icon-amenity-recycling", ROOT / "style" / "symbols" / "amenity" / "recycling.svg"),
    ("icon-leisure-table-tennis", ROOT / "style" / "symbols" / "leisure" / "table_tennis.svg"),
    ("icon-leisure-table-tennis-net-no", ROOT / "style" / "symbols" / "leisure" / "table_tennis_net_no.svg"),
    ("icon-leisure-table-tennis-net-yes", ROOT / "style" / "symbols" / "leisure" / "table_tennis_net_yes.svg"),
    ("icon-amenity-telephone", ROOT / "style" / "symbols" / "amenity" / "telephone.svg"),
    ("icon-amenity-waste-basket", ROOT / "style" / "symbols" / "amenity" / "waste_basket.svg"),
    ("icon-tourism-information", ROOT / "style" / "symbols" / "tourism" / "information.svg"),
    ("icon-historic-memorial", ROOT / "style" / "symbols" / "historic" / "memorial.svg"),
    ("icon-amenity-toilets", ROOT / "style" / "symbols" / "amenity" / "toilets.svg"),
    ("icon-tourism-viewpoint", ROOT / "style" / "symbols" / "tourism" / "viewpoint.svg"),
    ("icon-tourism-viewpoint-all-directions", ROOT / "style" / "symbols" / "tourism" / "viewpoint_all_directions.svg"),
    ("icon-public-transport-subway", ROOT / "style" / "symbols" / "public_transport" / "subway.svg"),
    ("icon-public-transport-s-train", ROOT / "style" / "symbols" / "public_transport" / "s-train.svg"),
)
PITCH_ICON_IMAGES = tuple(
    (f"pitch-{name}", ROOT / "style" / "textures" / "pitches" / f"{name}.svg")
    for name in (
        "multi", "soccer", "soccer_small", "basketball_1", "basketball_2",
        "tennis", "volleyball", "badminton", "handball", "field_hockey",
        "rugby_league", "rugby_union", "chess",
    )
)
ICON_LOGICAL_SIZE = 64
# QGIS "parking cars": SvgMarker symbols/cars/<model>_<colour>.svg, 2.4 m wide
# (the 250x440 artwork is then 4.2 m long). The sprite keeps the SVG aspect at
# CAR_LOGICAL_WIDTH logical px, so the style's icon-size is ground_width / that.
CAR_DIR = ROOT / "style" / "symbols" / "cars"
CAR_LOGICAL_WIDTH = 25
ARROW_DIR = ROOT / "style" / "symbols" / "traffic_signs" / "arrows"
ARROW_NAMES = (
    "left",
    "left;right",
    "left;through",
    "merge_to_left",
    "merge_to_right",
    "right",
    "slight_left",
    "slight_right",
    "through",
    "through;right",
)
ARROW_LENGTHS = (2, 5)
SURFACE_DIR = ROOT / "style" / "textures" / "surface"
ROTATION_STEP = 15
ALL_ANGLES = tuple(range(0, 360, ROTATION_STEP))
# Plain textures, drawn with normal alpha blending (pitch and landuse surfaces):
# (sprite family, texture, ground width in metres, rotation angles or None).
SURFACE_PATTERNS = (
    ("surface-concrete", SURFACE_DIR / "concrete.png", 3.0, (0,)),
    ("surface-paving-stones", SURFACE_DIR / "paving_stones.png", 4.5, ALL_ANGLES),
    ("surface-sett-11", SURFACE_DIR / "sett.png", 11.0, (0,)),
    ("surface-asphalt", SURFACE_DIR / "asphalt.png", 6.0, None),
    ("surface-woodchips", ROOT / "style" / "textures" / "woodchips.png", 8.0, None),
    ("surface-flowerbed", ROOT / "style" / "textures" / "flowerbed.png", 10.0, None),
    ("water", ROOT / "style" / "textures" / "water.png", 35.0, None),
    ("wetland", ROOT / "style" / "textures" / "wetland.png", 30.0, None),
)
# highway_area draws its grey textures with QGIS's Multiply blend mode, which
# only darkens the carriageway; MapLibre has no blend modes and would lighten it
# instead (concrete came out ~15 RGB too light). Multiplying by a grey texel t at
# opacity a gives dst * (1 - a * (1 - t)), which is exactly normal blending of
# black at alpha a * (1 - t): these sprites are black with alpha 1 - t, and the
# layer keeps the QGIS opacity a. (Asphalt is not grey; its plain texture is
# close enough because it is dark and drawn at 0.06.)
MULTIPLY_SURFACE_PATTERNS = (
    ("surface-concrete-multiply", SURFACE_DIR / "concrete.png", 3.0),
    ("surface-paving-stones-multiply", SURFACE_DIR / "paving_stones.png", 4.5),
    ("surface-sett-6-multiply", SURFACE_DIR / "sett.png", 6.0),
    ("surface-sett-8_5-multiply", SURFACE_DIR / "sett.png", 8.5),
    ("surface-sett-11-multiply", SURFACE_DIR / "sett.png", 11.0),
)
PIXEL_TEXTURES = (
    ("texture-grass", ROOT / "style" / "textures" / "grass.png"),
    ("texture-sand", ROOT / "style" / "textures" / "sand.png"),
    ("texture-gravel", ROOT / "style" / "textures" / "gravel.png"),
)
ZOOMS = range(14, 21)
PIXELS_PER_GROUND_METRE_Z15 = 0.34385
MAX_ATLAS_WIDTH = 4096
ATLAS_PADDING = 1


def read_image(path: Path) -> QImage:
    image = QImage(str(path))
    if image.isNull():
        raise RuntimeError(f"could not read {path}")
    return image


_SVG_PARAM = re.compile(r"param\([A-Za-z-]+\)\s*([^\"']+)")


def read_svg_resolving_params(path: Path) -> QImage:
    """Rasterize a QGIS "parametrised" SVG with its default parameter values.

    QGIS substitutes ``param(outline-width) 5`` with the symbol layer's value at
    render time. Qt does not know the syntax, treats such attributes as invalid
    and draws nothing (pitch tennis.svg was a fully transparent sprite), so
    replace each parameter by its default before rendering.
    """
    text = _SVG_PARAM.sub(lambda match: match.group(1).strip(), path.read_text())
    renderer = QSvgRenderer(QByteArray(text.encode()))
    if not renderer.isValid():
        raise RuntimeError(f"could not parse {path}")
    size = renderer.defaultSize()
    image = QImage(size, QImage.Format.Format_ARGB32_Premultiplied)
    image.fill(Qt.GlobalColor.transparent)
    painter = QPainter(image)
    renderer.render(painter)
    painter.end()
    return image


def square_icon(source: QImage, pixel_ratio: int) -> QImage:
    """Rasterize SVG artwork into a consistent, transparent sprite box."""
    side = ICON_LOGICAL_SIZE * pixel_ratio
    image = source.scaled(
        side,
        side,
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )
    result = QImage(side, side, QImage.Format.Format_ARGB32_Premultiplied)
    result.fill(Qt.GlobalColor.transparent)
    painter = QPainter(result)
    painter.drawImage((side - image.width()) // 2, (side - image.height()) // 2, image)
    painter.end()
    return result


def shrink(source: QImage, width: int) -> QImage:
    """Downscale with averaging: halve repeatedly, then one final smooth step."""
    image = source
    while image.width() > 2 * width:
        image = image.scaled(
            image.width() // 2,
            image.height() // 2,
            Qt.AspectRatioMode.IgnoreAspectRatio,
            Qt.TransformationMode.SmoothTransformation,
        )
    height = max(1, round(width * source.height() / source.width()))
    return image.scaled(
        width, height, Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation
    ).convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)


def car_icon(source: QImage, pixel_ratio: int) -> QImage:
    """Rasterize a car SVG at CAR_LOGICAL_WIDTH logical px, keeping its aspect."""
    width = CAR_LOGICAL_WIDTH * pixel_ratio
    height = round(width * source.height() / source.width())
    return source.scaled(
        width,
        height,
        Qt.AspectRatioMode.IgnoreAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    ).convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)


def arrow_icon(source: QImage, length_m: int, pixel_ratio: int) -> QImage:
    """Apply QGIS's independent SvgMarker width and height expressions."""
    logical_height = ICON_LOGICAL_SIZE
    logical_width = round(
        logical_height
        * 0.3
        * max(1.0, min(2.0, 2.0 - length_m / 5.0))
    )
    result = source.scaled(
        logical_width * pixel_ratio,
        logical_height * pixel_ratio,
        Qt.AspectRatioMode.IgnoreAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    ).convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)
    # Every live arrow uses QGIS's data-defined white fill. QImage renders the
    # SVG parameter fallback (#d0d0d0), so retain its antialias alpha only.
    for y in range(result.height()):
        for x in range(result.width()):
            alpha = result.pixelColor(x, y).alpha()
            result.setPixelColor(x, y, QColor(255, 255, 255, alpha))
    return result


def surface_pattern(
    source: QImage,
    ground_width: float,
    zoom: int,
    angle: int,
    pixel_ratio: int,
) -> QImage:
    logical_width = (
        ground_width * PIXELS_PER_GROUND_METRE_Z15 * 2 ** (zoom - 15)
    )
    target_width = max(1, round(logical_width * pixel_ratio))
    target_height = max(
        1, round(target_width * source.height() / source.width())
    )
    scaled = source.scaled(
        target_width,
        target_height,
        Qt.AspectRatioMode.IgnoreAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )
    if angle == 0:
        return scaled

    # Crop an infinitely repeated, rotated texture.  Using a QBrush instead
    # of rotating one bitmap means the sprite has no transparent corner gaps.
    side = max(1, math.ceil(math.hypot(target_width, target_height)))
    result = QImage(side, side, QImage.Format.Format_ARGB32_Premultiplied)
    result.fill(Qt.GlobalColor.transparent)
    brush = QBrush(scaled)
    transform = QTransform()
    transform.translate(side / 2, side / 2)
    transform.rotate(angle)
    transform.translate(-side / 2, -side / 2)
    brush.setTransform(transform)
    painter = QPainter(result)
    painter.fillRect(result.rect(), brush)
    painter.end()
    return result


def multiply_equivalent(texture: QImage) -> QImage:
    """Black with alpha 1 - texel: normal blending of it equals Multiply."""
    darkness = texture.convertToFormat(QImage.Format.Format_Grayscale8)
    darkness.invertPixels()
    result = QImage(texture.size(), QImage.Format.Format_ARGB32_Premultiplied)
    result.fill(Qt.GlobalColor.black)
    result.setAlphaChannel(darkness)
    return result


def pixel_texture(source: QImage, pixel_ratio: int) -> QImage:
    """Retain QGIS's pixel-unit RasterFill dimensions at each sprite ratio."""
    if pixel_ratio == 2:
        return source
    return source.scaled(
        max(1, round(source.width() / 2)),
        max(1, round(source.height() / 2)),
        Qt.AspectRatioMode.IgnoreAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )


def build_images(pixel_ratio: int) -> list[tuple[str, QImage]]:
    loaded: list[tuple[str, QImage]] = []
    for name, path in TREE_IMAGES:
        image = read_image(path)
        logical_width = int(image.width() / 2 + 0.5)
        logical_height = int(image.height() / 2 + 0.5)
        target_width = logical_width * pixel_ratio
        target_height = logical_height * pixel_ratio
        if image.width() != target_width or image.height() != target_height:
            image = image.scaled(
                target_width,
                target_height,
                Qt.AspectRatioMode.IgnoreAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
        loaded.append((name, image))
        source = read_image(path)
        for band, band_width in TREE_BAND_WIDTHS.items():
            loaded.append((f"{name}-b{band}", shrink(source, band_width * pixel_ratio)))
            _LOGICAL_WIDTH[f"{name}-b{band}"] = logical_width

    for name, path in FEATURE_ICON_IMAGES:
        loaded.append((name, square_icon(read_image(path), pixel_ratio)))

    for name, path in PITCH_ICON_IMAGES:
        loaded.append((name, square_icon(read_svg_resolving_params(path), pixel_ratio)))

    # QGIS-rendered SimpleMarker symbols of the feature_node layers (marker_sprites.py)
    for marker in marker_sprites.MARKERS:
        loaded.append((marker.name, marker_sprites.render(marker, pixel_ratio, ROOT / "style" / "symbols")))

    for path in sorted(CAR_DIR.glob("*.svg")):
        loaded.append((f"parking-car-{path.stem}", car_icon(read_image(path), pixel_ratio)))

    for arrow_name in ARROW_NAMES:
        source = read_image(ARROW_DIR / f"{arrow_name}.svg")
        sprite_name = arrow_name.replace(";", "-")
        for length_m in ARROW_LENGTHS:
            loaded.append(
                (
                    f"road-arrow-{sprite_name}-l{length_m}",
                    arrow_icon(source, length_m, pixel_ratio),
                )
            )

    source_cache: dict[Path, QImage] = {}
    for family, path, ground_width, rotations in SURFACE_PATTERNS:
        source = source_cache.setdefault(path, read_image(path))
        angles = rotations or (0,)
        for zoom in ZOOMS:
            for angle in angles:
                suffix = f"-r{angle:03d}" if rotations else ""
                name = f"{family}-z{zoom}{suffix}"
                loaded.append(
                    (
                        name,
                        surface_pattern(
                            source, ground_width, zoom, angle, pixel_ratio
                        ),
                    )
                )
    for family, path, ground_width in MULTIPLY_SURFACE_PATTERNS:
        source = source_cache.setdefault(path, read_image(path))
        for zoom in ZOOMS:
            for angle in ALL_ANGLES:
                pattern = surface_pattern(source, ground_width, zoom, angle, pixel_ratio)
                loaded.append((f"{family}-z{zoom}-r{angle:03d}", multiply_equivalent(pattern)))
    for name, path in PIXEL_TEXTURES:
        loaded.append((name, pixel_texture(read_image(path), pixel_ratio)))
    return loaded


def shelf_pack(
    images: list[tuple[str, QImage]],
) -> tuple[int, int, dict[str, tuple[int, int]]]:
    positions: dict[str, tuple[int, int]] = {}
    x = y = row_height = 0
    for name, image in sorted(images, key=lambda item: item[1].height(), reverse=True):
        if image.width() > MAX_ATLAS_WIDTH:
            raise RuntimeError(f"sprite {name} is wider than {MAX_ATLAS_WIDTH}px")
        if x and x + image.width() > MAX_ATLAS_WIDTH:
            x = 0
            y += row_height + ATLAS_PADDING
            row_height = 0
        positions[name] = (x, y)
        x += image.width() + ATLAS_PADDING
        row_height = max(row_height, image.height())
    height = y + row_height
    if height > MAX_ATLAS_WIDTH:
        raise RuntimeError(
            f"packed sprite atlas is {MAX_ATLAS_WIDTH}x{height}; "
            "increase packing efficiency before exceeding common WebGL limits"
        )
    return MAX_ATLAS_WIDTH, height, positions


def is_blank(image: QImage) -> bool:
    """True when no pixel has any alpha (a sprite that rendered as nothing)."""
    alpha = image.convertToFormat(QImage.Format.Format_Alpha8)
    data = alpha.constBits()
    data.setsize(alpha.sizeInBytes())
    return not any(bytes(data))


def pack(suffix: str, pixel_ratio: int) -> None:
    loaded = build_images(pixel_ratio)
    blank = [name for name, image in loaded if is_blank(image)]
    if blank:
        raise RuntimeError(f"sprites rendered fully transparent: {', '.join(blank)}")
    width, height, positions = shelf_pack(loaded)
    atlas = QImage(width, height, QImage.Format.Format_ARGB32_Premultiplied)
    atlas.fill(Qt.GlobalColor.transparent)
    painter = QPainter(atlas)
    metadata: dict[str, dict[str, int | bool]] = {}
    for name, image in loaded:
        x, y = positions[name]
        painter.drawImage(x, y, image)
        metadata[name] = {
            "x": x,
            "y": y,
            "width": image.width(),
            "height": image.height(),
            # Banded tree crowns: fewer pixels, same logical size as the full image.
            "pixelRatio": (
                round(image.width() / _LOGICAL_WIDTH[name], 6)
                if name in _LOGICAL_WIDTH
                else pixel_ratio
            ),
            "sdf": False,
        }
    painter.end()

    png_path = OUTPUT.with_name(OUTPUT.name + suffix).with_suffix(".png")
    json_path = OUTPUT.with_name(OUTPUT.name + suffix).with_suffix(".json")
    if not atlas.save(str(png_path), "PNG"):
        raise RuntimeError(f"could not write {png_path}")
    json_path.write_text(json.dumps(metadata, indent=2) + "\n")
    print(
        f"wrote {png_path.relative_to(ROOT)} and {json_path.relative_to(ROOT)} "
        f"({len(loaded)} images, {width}x{height})"
    )


if __name__ == "__main__":
    # Rasterizing SVGs that contain text (some car artwork) needs a GUI application.
    # A QgsApplication is a QGuiApplication; marker_sprites renders symbols with QGIS itself.
    app = QgsApplication([], True)
    QgsApplication.setPrefixPath(os.environ.get("QGIS_PREFIX_PATH", ""), True)
    app.initQgis()
    # Full source pixels become the Retina atlas.  The 1× version uses the
    # same logical dimensions, so one icon-size expression works on both.
    pack("", 1)
    pack("@2x", 2)
