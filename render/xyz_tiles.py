#!/usr/bin/env python3
"""
Render XYZ map tiles from a QGIS project using a custom metatile loop.

Renders directly in EPSG:3857 (Web Mercator tile grid). Ground-metre symbol
sizes in the project are scaled via the project variable @mercator_scale
(= 1/cos(φ) under EPSG:3857).

Progress is reported after every metatile (zoom, metatile index, tiles, ETA).
Background colour defaults to #ededed (opaque); override with --background.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import qgis  # noqa: E402
from qgis.core import (  # noqa: E402
    QgsApplication,
    QgsCoordinateReferenceSystem,
    QgsExpressionContext,
    QgsExpressionContextUtils,
    QgsMapRendererCustomPainterJob,
    QgsMapSettings,
    QgsProject,
    QgsProviderRegistry,
    QgsRectangle,
)
from qgis.PyQt.QtCore import QSize, qInstallMessageHandler  # noqa: E402
from qgis.PyQt.QtGui import QColor, QImage, QPainter  # noqa: E402
from qgis.PyQt.QtSvg import QSvgRenderer  # noqa: E402

ORIGIN_SHIFT = 20037508.342789244
TILE_SIZE_PX = 256
DEFAULT_BACKGROUND = "#ededed"
MANIFEST_NAME = ".render-manifest.json"
COMPLETION_NAME = ".render-completions.jsonl"
RESTART_EXIT = 75
# Distinct from RESTART_EXIT so render_tiles.sh's "exit 75 -> restart with
# --resume" loop does not treat a user-requested Ctrl+C/SIGTERM as a routine
# worker recycle and silently keep going.
STOP_EXIT = 130

# Qt stderr spam when painting onto a null QImage (engine == 0, type 3 = Image).
# Empty map data does *not* cause this; QGIS may still emit it for failed internal
# symbol/label buffers while the main metatile image is fine. Real allocation
# failure of the metatile buffer is checked via QImage.isNull() instead.
_QPAINTER_NOISE_RE = re.compile(
    r"^QPainter::("
    r"begin: Paint device returned engine == 0"
    r"|setRenderHint: Painter must be active"
    r"|translate: Painter not active"
    r"|end: Painter not active"
    r"|.+: Painter not active"
    r")"
)
_RENDER_FAILURE_RE = re.compile(
    r"QImageIOHandler: Rejecting image|QPicture::play: Format error|"
    r"QPainter::begin: Paint device returned engine == 0|"
    r"QPainter::.*Painter not active"
)
_qt_messages: List[str] = []
_stop_requested = False

DB_NAME = os.environ.get("DB_NAME", "strassenraumkarte")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5433")


@dataclass(frozen=True)
class TileRange:
    x0: int
    x1: int
    y0: int
    y1: int

    @property
    def count(self) -> int:
        return max(0, (self.x1 - self.x0 + 1) * (self.y1 - self.y0 + 1))


@dataclass(frozen=True)
class MetaTile:
    """Core tiles (x0..x1, y0..y1) are written; rx*/ry* include gutter for render."""

    z: int
    x0: int
    x1: int
    y0: int
    y1: int
    rx0: int
    rx1: int
    ry0: int
    ry1: int

    @property
    def width_tiles(self) -> int:
        return self.x1 - self.x0 + 1

    @property
    def height_tiles(self) -> int:
        return self.y1 - self.y0 + 1

    @property
    def tile_count(self) -> int:
        return self.width_tiles * self.height_tiles

    @property
    def render_width_tiles(self) -> int:
        return self.rx1 - self.rx0 + 1

    @property
    def render_height_tiles(self) -> int:
        return self.ry1 - self.ry0 + 1


def log(level: str, msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  [{level}] {msg}", flush=True)


def _qt_message_handler(mode, context, message: str) -> None:  # noqa: ARG001
    """Record QGIS/Qt diagnostics so failed jobs cannot look successful."""
    _qt_messages.append(message)
    if _QPAINTER_NOISE_RE.match(message) and not _RENDER_FAILURE_RE.search(message):
        return
    sys.stderr.write(message + "\n")
    sys.stderr.flush()


def install_qt_message_filter() -> None:
    """Install a diagnostic handler before starting any map-render jobs."""
    qInstallMessageHandler(_qt_message_handler)


def consume_qt_messages(start: int) -> List[str]:
    return _qt_messages[start:]


def request_stop(signum, frame) -> None:  # noqa: ANN001, ARG001
    """Finish the current metatile, leaving its output either committed or absent."""
    global _stop_requested
    _stop_requested = True
    log("WARN", f"Received signal {signum}; stopping after the current metatile.")


def parse_background_color(value: str) -> Tuple[str, QColor]:
    """Parse '#rrggbb' / 'rrggbb' → (normalised hex, QColor)."""
    raw = value.strip()
    if raw.startswith("#"):
        raw = raw[1:]
    if not re.fullmatch(r"[0-9A-Fa-f]{6}", raw):
        raise ValueError(f"Invalid background colour (expected #rrggbb): {value}")
    hex_str = f"#{raw.lower()}"
    r, g, b = int(raw[0:2], 16), int(raw[2:4], 16), int(raw[4:6], 16)
    return hex_str, QColor(r, g, b)


def format_duration(secs: float) -> str:
    secs_i = max(0, int(secs))
    h, rem = divmod(secs_i, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def parse_extent(extent: str) -> Tuple[float, float, float, float]:
    """Parse 'xmin,xmax,ymin,ymax [EPSG:4326]' → (xmin, ymin, xmax, ymax)."""
    crs = re.search(r"\[EPSG:(\d+)\]", extent)
    if crs is None or crs.group(1) != "4326":
        raise ValueError("Render extent must explicitly be in EPSG:4326")
    m = re.match(
        r"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*"
        r"(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)",
        extent,
    )
    if not m:
        raise ValueError(f"Invalid extent: {extent}")
    xmin, xmax, ymin, ymax = map(float, m.groups())
    if xmin > xmax:
        xmin, xmax = xmax, xmin
    if ymin > ymax:
        ymin, ymax = ymax, ymin
    return xmin, ymin, xmax, ymax


def clamp_lat(lat: float) -> float:
    return max(min(lat, 85.05112878), -85.05112878)


def mercator_scale_from_lat(lat: float) -> float:
    """Web Mercator ground-metre → map-unit factor at geodetic latitude φ."""
    lat = clamp_lat(lat)
    # Slightly tighter than Web Mercator limit for cos stability.
    lat = max(min(lat, 85.0), -85.0)
    return 1.0 / math.cos(math.radians(lat))


def scale_factor_from_processing_crs() -> Optional[Tuple[float, float, str]]:
    """Return (scale_factor, latitude, source) from public._processing_crs if present."""
    env = os.environ.copy()
    if "PGPASSFILE" not in env and os.path.isfile(os.path.expanduser("~/.pgpass")):
        env["PGPASSFILE"] = os.path.expanduser("~/.pgpass")
    sql = (
        "SELECT scale_factor::text, COALESCE(latitude::text, ''), source "
        "FROM public._processing_crs LIMIT 1;"
    )
    try:
        raw = subprocess.check_output(
            [
                "psql",
                "-U", DB_USER,
                "-h", DB_HOST,
                "-p", DB_PORT,
                "-d", DB_NAME,
                "-At",
                "-F", "\t",
                "-c", sql,
            ],
            env=env,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    if not raw:
        return None
    parts = raw.split("\t")
    if len(parts) < 1:
        return None
    try:
        scale = float(parts[0])
    except ValueError:
        return None
    lat = float(parts[1]) if len(parts) > 1 and parts[1] else float("nan")
    source = parts[2] if len(parts) > 2 else "db"
    return scale, lat, source


def resolve_mercator_scale(
    project: QgsProject,
    xmin: float,
    ymin: float,
    xmax: float,
    ymax: float,
) -> Tuple[float, str]:
    """
    Resolve @mercator_scale for this render run.

    Returns (scale, description_for_log).
    """
    project_crs = project.crs()
    if not project_crs.isValid() or project_crs.authid() != "EPSG:3857":
        return 1.0, f"CRS {project_crs.authid() or 'invalid'} → scale 1"

    # 1) Mid-latitude of render extent (WGS84 bbox from --extent / --bbox)
    mid_lat = (ymin + ymax) / 2.0
    if math.isfinite(mid_lat) and abs(mid_lat) <= 90:
        scale = mercator_scale_from_lat(mid_lat)
        return scale, f"extent mid-lat {mid_lat:.5f} → scale {scale:.6f}"

    # 2) Processing table
    db = scale_factor_from_processing_crs()
    if db is not None:
        scale, lat, source = db
        lat_s = f"{lat:.5f}" if math.isfinite(lat) else "?"
        return scale, f"_processing_crs ({source}, lat {lat_s}) → scale {scale:.6f}"

    return 1.0, "fallback → scale 1"


def lon_to_tile_x(lon: float, z: int) -> int:
    n = 2**z
    x = int((lon + 180.0) / 360.0 * n)
    return min(max(x, 0), n - 1)


def lat_to_tile_y(lat: float, z: int) -> int:
    lat = clamp_lat(lat)
    lat_rad = math.radians(lat)
    n = 2**z
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return min(max(y, 0), n - 1)


def tile_range_for_bbox(xmin: float, ymin: float, xmax: float, ymax: float, z: int) -> TileRange:
    x0 = lon_to_tile_x(xmin, z)
    x1 = lon_to_tile_x(xmax, z)
    y0 = lat_to_tile_y(ymax, z)  # north → smaller y
    y1 = lat_to_tile_y(ymin, z)
    if x1 < x0:
        x0, x1 = x1, x0
    if y1 < y0:
        y0, y1 = y1, y0
    return TileRange(x0, x1, y0, y1)


def tile_bounds_3857(x: int, y: int, z: int) -> QgsRectangle:
    n = 2**z
    tile_m = (2 * ORIGIN_SHIFT) / n
    minx = -ORIGIN_SHIFT + x * tile_m
    maxx = -ORIGIN_SHIFT + (x + 1) * tile_m
    maxy = ORIGIN_SHIFT - y * tile_m
    miny = ORIGIN_SHIFT - (y + 1) * tile_m
    return QgsRectangle(minx, miny, maxx, maxy)


def metatile_extent_3857(mt: MetaTile) -> QgsRectangle:
    """Extent of the render area (core + gutter)."""
    nw = tile_bounds_3857(mt.rx0, mt.ry0, mt.z)
    se = tile_bounds_3857(mt.rx1, mt.ry1, mt.z)
    return QgsRectangle(nw.xMinimum(), se.yMinimum(), se.xMaximum(), nw.yMaximum())


def iter_metatiles(tr: TileRange, z: int, metatile: int, gutter: int) -> List[MetaTile]:
    """Build metatile cores on the grid; expand each by gutter for rendering only."""
    tiles: List[MetaTile] = []
    n = 2**z
    max_xy = n - 1
    gx0 = (tr.x0 // metatile) * metatile
    gy0 = (tr.y0 // metatile) * metatile
    for gy in range(gy0, tr.y1 + 1, metatile):
        for gx in range(gx0, tr.x1 + 1, metatile):
            x0 = max(tr.x0, gx)
            x1 = min(tr.x1, gx + metatile - 1)
            y0 = max(tr.y0, gy)
            y1 = min(tr.y1, gy + metatile - 1)
            if x0 > x1 or y0 > y1:
                continue
            rx0 = max(0, x0 - gutter)
            rx1 = min(max_xy, x1 + gutter)
            ry0 = max(0, y0 - gutter)
            ry1 = min(max_xy, y1 + gutter)
            tiles.append(MetaTile(z, x0, x1, y0, y1, rx0, rx1, ry0, ry1))
    return tiles


def collect_visible_layers(project: QgsProject, tree_mode: str) -> List:
    """Return visible layers, failing rather than silently omitting broken data."""
    root = project.layerTreeRoot()
    layers = []
    invalid: List[Tuple[str, str]] = []
    for layer in root.layerOrder():
        if layer is None:
            continue
        node = root.findLayer(layer.id())
        if node is None or not node.isVisible():
            continue
        if not layer.isValid():
            source = layer.source()
            provider_error = layer.dataProvider().error().message() if layer.dataProvider() else ""
            invalid.append((layer.name(), f"{layer.name()} ({source}{': ' + provider_error if provider_error else ''})"))
            continue
        layers.append(layer)
    relevant_invalid = invalid if tree_mode != "only" else [item for item in invalid if item[0] == "tree crown"]
    if relevant_invalid:
        raise RuntimeError("Visible QGIS layer(s) are invalid: " + ", ".join(item[1] for item in relevant_invalid))
    return select_layers(layers, tree_mode)


_progress_line_width = 0


def print_progress(
    *,
    zoom: int,
    zmax: int,
    meta_done: int,
    meta_total: int,
    verified_tiles: int,
    total_tiles: int,
    render_elapsed: float,
    newly_rendered_tiles: int,
    skipped_tiles: int,
) -> None:
    """Overwrite a single progress line via carriage return."""
    global _progress_line_width
    if total_tiles:
        pct = min(100.0, max(0.0, verified_tiles * 100.0 / total_tiles))
    else:
        pct = 100.0
    if newly_rendered_tiles > 0 and verified_tiles < total_tiles and render_elapsed > 0:
        remaining = format_duration(render_elapsed * (total_tiles - verified_tiles) / newly_rendered_tiles)
    elif verified_tiles >= total_tiles:
        remaining = "0s"
    else:
        remaining = "--"
    line = (
        f"{pct:5.1f}%  zoom {zoom}/{zmax}  "
        f"metatiles {meta_done}/{meta_total}  "
        f"verified {verified_tiles}/{total_tiles}  "
        f"new {newly_rendered_tiles} skipped {skipped_tiles}  "
        f"render {format_duration(render_elapsed)}  ETA {remaining}"
    )
    pad = max(0, _progress_line_width - len(line))
    _progress_line_width = max(_progress_line_width, len(line))
    print(f"\r{line}{' ' * pad}", end="", flush=True)


def finish_progress_line() -> None:
    """End the in-place progress line before normal log output."""
    global _progress_line_width
    if _progress_line_width:
        print(flush=True)
        _progress_line_width = 0


def save_tile_image(
    tile: QImage,
    path: str,
    fmt: str,
    quality: int,
    background: QColor,
) -> None:
    """
    Write one tile to disk.

    JPEG has no alpha: composite the premultiplied ARGB buffer onto the opaque
    background before encoding. Saving ARGB32_Premultiplied directly as JPEG
    drops alpha incorrectly and can yield flat gray tiles.
    """
    if fmt == "jpg":
        opaque = QImage(tile.size(), QImage.Format.Format_RGB888)
        if opaque.isNull():
            raise RuntimeError("Failed to allocate JPEG compositing buffer")
        opaque.fill(background.rgb())
        painter = QPainter(opaque)
        painter.drawImage(0, 0, tile)
        painter.end()
        if not opaque.save(path, "JPEG", quality):
            raise RuntimeError(f"Failed to save JPEG tile: {path}")
    else:
        if not tile.save(path, "PNG"):
            raise RuntimeError(f"Failed to save PNG tile: {path}")


def validate_tile_file(path: str, fmt: str) -> None:
    image = QImage(path)
    if image.isNull() or image.size() != QSize(TILE_SIZE_PX, TILE_SIZE_PX):
        raise RuntimeError(f"Invalid {fmt.upper()} tile written: {path}")


def metatile_key(mt: MetaTile) -> str:
    return f"z{mt.z}-x{mt.x0}-{mt.x1}-y{mt.y0}-{mt.y1}"


def manifest_path(out_dir: str) -> str:
    return os.path.join(out_dir, MANIFEST_NAME)


def completion_path(out_dir: str) -> str:
    return os.path.join(out_dir, COMPLETION_NAME)


def atomic_write_json(path: str, value: Dict) -> None:
    directory = os.path.dirname(path)
    fd, temp_path = tempfile.mkstemp(prefix=".render-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(value, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def append_completion(out_dir: str, record: Dict) -> None:
    path = completion_path(out_dir)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, sort_keys=True) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def load_completed_metatiles(out_dir: str, configuration_id: str) -> set[str]:
    completed: set[str] = set()
    path = completion_path(out_dir)
    if not os.path.isfile(path):
        return completed
    with open(path, encoding="utf-8") as fh:
        for line_number, line in enumerate(fh, 1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"Invalid completion record {path}:{line_number}: {exc}") from exc
            if record.get("configuration_id") == configuration_id and record.get("status") == "committed":
                completed.add(record["metatile"])
    return completed


def metatile_already_rendered(mt: MetaTile, out_dir: str, fmt: str, completed: set[str]) -> bool:
    """Require a matching commit record and decodable core tiles before resume."""
    if metatile_key(mt) not in completed:
        return False
    for ty in range(mt.y0, mt.y1 + 1):
        for tx in range(mt.x0, mt.x1 + 1):
            path = os.path.join(out_dir, str(mt.z), str(tx), f"{ty}.{fmt}")
            if not os.path.isfile(path):
                return False
            try:
                validate_tile_file(path, fmt)
            except RuntimeError:
                return False
    return True


def render_metatile(
    settings_template: QgsMapSettings,
    layers: Sequence,
    mt: MetaTile,
    out_dir: str,
    fmt: str,
    quality: int,
    crs_3857: QgsCoordinateReferenceSystem,
    background: QColor,
) -> Tuple[int, float, List[str]]:
    extent_3857 = metatile_extent_3857(mt)
    width_px = mt.render_width_tiles * TILE_SIZE_PX
    height_px = mt.render_height_tiles * TILE_SIZE_PX

    settings = QgsMapSettings(settings_template)
    settings.setDestinationCrs(crs_3857)
    settings.setLayers(list(layers))
    settings.setExtent(extent_3857)
    settings.setOutputSize(QSize(width_px, height_px))
    settings.setBackgroundColor(background)
    # fromMapSettings copies expressionContext() as-is and does not add
    # mapSettingsScope. Without it @map_scale is NULL → label FontOpacity
    # CASE WHEN @map_scale < 2000 … always hits ELSE (full opacity).
    context = QgsExpressionContext(settings.expressionContext())
    context.appendScope(QgsExpressionContextUtils.mapSettingsScope(settings))
    settings.setExpressionContext(context)

    image = QImage(QSize(width_px, height_px), QImage.Format.Format_ARGB32_Premultiplied)
    if image.isNull():
        raise RuntimeError(
            f"Failed to allocate render buffer {width_px}×{height_px} px for "
            f"z{mt.z} x{mt.rx0}-{mt.rx1} y{mt.ry0}-{mt.ry1} "
            f"(out of memory?). Try a smaller --metatile."
        )
    image.fill(background)
    painter = QPainter()
    if not painter.begin(image):
        raise RuntimeError(
            f"QPainter.begin failed for {width_px}×{height_px} px "
            f"(z{mt.z} x{mt.rx0}-{mt.rx1} y{mt.ry0}-{mt.ry1})."
        )
    painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    job = QgsMapRendererCustomPainterJob(settings, painter)
    message_start = len(_qt_messages)
    started = time.monotonic()
    try:
        job.start()
        job.waitForFinished()
    finally:
        painter.end()
    elapsed = time.monotonic() - started
    errors = [str(error) for error in job.errors()]
    diagnostics = consume_qt_messages(message_start)
    fatal_diagnostics = [message for message in diagnostics if _RENDER_FAILURE_RE.search(message)]
    if errors or fatal_diagnostics:
        details = errors + fatal_diagnostics[:3]
        raise RuntimeError(f"Render failed for {metatile_key(mt)}: " + " | ".join(details))

    stage_dir = tempfile.mkdtemp(prefix=f".stage-{metatile_key(mt)}-", dir=out_dir)
    staged: List[Tuple[str, str]] = []
    try:
        # Save and decode every core tile before changing any final path.
        for ty in range(mt.y0, mt.y1 + 1):
            for tx in range(mt.x0, mt.x1 + 1):
                px = (tx - mt.rx0) * TILE_SIZE_PX
                py = (ty - mt.ry0) * TILE_SIZE_PX
                tile = image.copy(px, py, TILE_SIZE_PX, TILE_SIZE_PX)
                if tile.isNull():
                    raise RuntimeError(f"Failed to copy output tile for {metatile_key(mt)}")
                relative = os.path.join(str(mt.z), str(tx), f"{ty}.{fmt}")
                staged_path = os.path.join(stage_dir, relative)
                os.makedirs(os.path.dirname(staged_path), exist_ok=True)
                save_tile_image(tile, staged_path, fmt, quality, background)
                validate_tile_file(staged_path, fmt)
                staged.append((staged_path, os.path.join(out_dir, relative)))

        # Each final replacement is atomic. Completion is recorded only after all
        # replacements finish, so a restart never treats a partial metatile as done.
        for staged_path, final_path in staged:
            os.makedirs(os.path.dirname(final_path), exist_ok=True)
            os.replace(staged_path, final_path)
        return len(staged), elapsed, diagnostics
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)


def resolve_qgis_macos_bundle_contents() -> Optional[str]:
    """Path to <bundle>.app/Contents, derived from the already-imported qgis
    package's own location (works regardless of the app's version-specific
    folder name)."""
    module_path = os.path.realpath(qgis.__file__)
    parts = module_path.split(os.sep)
    if "Contents" in parts:
        return os.sep.join(parts[: parts.index("Contents") + 1])
    return None


def resolve_qgis_prefix_path() -> str:
    """QgsApplication prefix path: /usr on Linux packages, but on macOS
    .app bundles it must point at <bundle>/Contents/MacOS instead."""
    env_override = os.environ.get("QGIS_PREFIX_PATH")
    if env_override:
        return env_override
    if sys.platform == "darwin":
        bundle_contents = resolve_qgis_macos_bundle_contents()
        if bundle_contents:
            return os.path.join(bundle_contents, "MacOS")
    return "/usr"


def apply_qgis_macos_bundle_paths() -> None:
    """On macOS, QgsApplication.setPrefixPath's built-in derivation of the
    plugin/data paths from the prefix path is wrong when running the bundled
    python3 interpreter directly (not the actual QGIS launcher binary) — it
    resolves to a doubled, nonexistent path like
    ".../Contents/MacOS/Contents/PlugIns/qgis" instead of
    ".../Contents/PlugIns/qgis", silently leaving zero data providers
    registered (every PostGIS layer then fails isValid() with no error
    message). Set the plugin/package-data paths explicitly from the known
    real bundle layout instead of relying on that derivation."""
    if sys.platform != "darwin":
        return
    bundle_contents = resolve_qgis_macos_bundle_contents()
    if not bundle_contents:
        return
    QgsApplication.setPluginPath(os.path.join(bundle_contents, "PlugIns", "qgis"))
    QgsApplication.setPkgDataPath(os.path.join(bundle_contents, "Resources", "qgis"))


@dataclass
class ResolvedProject:
    render_path: str
    original_path: str
    extract_dir: Optional[str] = None
    transient_file: Optional[str] = None

    def cleanup(self) -> None:
        if self.extract_dir:
            shutil.rmtree(self.extract_dir, ignore_errors=True)
        if self.transient_file:
            try:
                os.unlink(self.transient_file)
            except FileNotFoundError:
                pass


def sweep_stale_render_copies(project_dir: str, max_age_seconds: float = 3600) -> None:
    """Best-effort removal of disposable ".render-*.qgs" copies left behind by
    a SIGKILLed render (finally-block cleanup cannot run for that signal).
    Only removes files older than max_age_seconds, so a copy belonging to an
    actually-concurrent render is left alone."""
    now = time.time()
    for entry in glob.glob(os.path.join(project_dir, ".render-*.qgs")):
        try:
            if now - os.path.getmtime(entry) > max_age_seconds:
                os.remove(entry)
        except OSError:
            pass


def resolve_project_path(path: str, advanced_effects: bool) -> ResolvedProject:
    """QgsProject.read()'s own .qgz unzip has been observed to fail
    ("Unable to unzip file") when run under this embedded interpreter,
    even on a valid archive (readable fine by Python's zipfile /
    `unzip -t`) — a Qt temp-path resolution quirk specific to this
    non-GUI-launched invocation, not a corrupt project file. Sidestep it
    by extracting the .qgz ourselves and pointing QGIS at the inner .qgs."""
    sweep_stale_render_copies(os.path.dirname(os.path.abspath(path)))
    if not path.lower().endswith(".qgz"):
        project_dir = os.path.dirname(os.path.abspath(path))
        fd, render_path = tempfile.mkstemp(prefix=".render-", suffix=".qgs", dir=project_dir)
        with os.fdopen(fd, "wb") as fh:
            fh.write(Path(path).read_bytes())
        tree = ET.parse(render_path)
        if not advanced_effects:
            for effect in tree.findall(".//effect"):
                effect.set("enabled", "0")
                for option in effect.findall(".//Option[@name='enabled']"):
                    option.set("value", "0")
            disable_broken_blur_fill(tree)
        # Always, even in reference mode: these layers hang QGIS 4.2.1.
        disable_shapeburst_fill(tree)
        tree.write(render_path, encoding="utf-8", xml_declaration=True)
        return ResolvedProject(render_path, path, transient_file=render_path)
    project_dir = os.path.dirname(os.path.abspath(path))
    with zipfile.ZipFile(path) as zf:
        qgs_names = [n for n in zf.namelist() if n.lower().endswith(".qgs")]
    if not qgs_names:
        raise RuntimeError(f"No .qgs file found inside {path}")
    # Place the temporary QGS beside the QGZ, rather than under /tmp. QGIS
    # resolves conventional relative layer URIs during read(), using this
    # filename as the base directory for expressions as well.
    fd, render_path = tempfile.mkstemp(prefix=".render-", suffix=".qgs", dir=project_dir)
    with os.fdopen(fd, "wb") as fh, zipfile.ZipFile(path) as zf:
        fh.write(zf.read(qgs_names[0]))
    tree = ET.parse(render_path)
    if not advanced_effects:
        # QgsMapSettings.UseAdvancedEffects does not disable per-symbol effect
        # stacks. Disable all effects in the disposable extracted project.
        for effect in tree.findall(".//effect"):
            effect.set("enabled", "0")
            for option in effect.findall(".//Option[@name='enabled']"):
                option.set("value", "0")
        disable_broken_blur_fill(tree)
    # Always, even in reference mode: the two water ShapeburstFill layers
    # exhaust memory in QGIS 4.2.1, so reference renders cannot include them.
    disable_shapeburst_fill(tree)
    tree.write(render_path, encoding="utf-8", xml_declaration=True)
    return ResolvedProject(render_path, path, transient_file=render_path)


# The only two ShapeburstFill users confirmed by bisection to crash (see
# docs/RENDER_RECOVERY_PLAN.md, "Root cause found") — down to 5-317 sq m
# polygons, a ~97.5GB peak memory footprint, regardless of feature size. A
# third project-wide user, "roof shape" (most buildings' default roof
# shading, blur_radius=0), was confirmed NOT part of the crash by that same
# bisection and must stay enabled: disabling ShapeburstFill by symbol class
# project-wide (an earlier version of this fix) silently flattened the roof
# colour on nearly every building in headless renders.
_CRASHING_SHAPEBURST_LAYER_NAMES = {"water body", "water body (depth effect)"}


def disable_shapeburst_fill(tree: ET.ElementTree) -> None:
    """Disable ShapeburstFill only on the two layers confirmed to crash.
    Applies to every render of the extracted project, including
    --advanced-effects reference renders (which therefore lack the water
    depth gradient; QGIS Desktop opening the .qgz itself still has it)."""
    root = tree.getroot()
    for maplayer in root.iter("maplayer"):
        layername_el = maplayer.find("layername")
        if layername_el is None or layername_el.text not in _CRASHING_SHAPEBURST_LAYER_NAMES:
            continue
        for layer_el in maplayer.iter("layer"):
            if layer_el.get("class") == "ShapeburstFill":
                layer_el.set("enabled", "0")


# The "highway (unlayered)/(layered)" > "highway areas" > "blur" template
# group ("z14".."z20", cloned 6x per bridge/tunnel level by
# update_highway_layered.py). Each layer's base SimpleFill is an opaque
# near-black (35,35,35,255) — meaningless on its own; it only reads correctly
# as the *input* to that layer's renderer-level effect stack (an innerShadow
# that redraws it as a soft inset road-edge shadow). This code path already
# force-disables every <effect> project-wide for headless tile renders (see
# resolve_project_path above), which leaves that raw near-black fill exposed
# as a solid dark overlay across the whole road surface instead. Disable the
# fill itself alongside the effect so headless renders show the plain
# carriageway colour beneath; QGIS-Desktop/reference-image renders with
# --advanced-effects keep the original soft-shadow styling.
_BROKEN_BLUR_LAYER_NAMES = {"z14", "z15", "z16", "z17", "z18", "z19", "z20"}


def disable_broken_blur_fill(tree: ET.ElementTree) -> None:
    """Disable the base SimpleFill on the road-shadow "blur" layers (headless
    tile renders only — see _BROKEN_BLUR_LAYER_NAMES docstring above)."""
    root = tree.getroot()
    for maplayer in root.iter("maplayer"):
        layername_el = maplayer.find("layername")
        if layername_el is None or layername_el.text not in _BROKEN_BLUR_LAYER_NAMES:
            continue
        for layer_el in maplayer.iter("layer"):
            if layer_el.get("class") == "SimpleFill":
                layer_el.set("enabled", "0")


def preflight_assets(project_dir: str) -> int:
    """Decode every packaged raster asset used by the project style tree."""
    required = [
        os.path.join(project_dir, "symbols", "trees", "broadleaved.png"),
        os.path.join(project_dir, "symbols", "trees", "needleleaved.png"),
    ]
    assets = required + [
        str(path)
        for path in Path(project_dir).glob("**/*")
        if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg", ".svg"}
    ]
    checked = set()
    for asset in assets:
        if asset in checked:
            continue
        checked.add(asset)
        if not os.path.isfile(asset):
            raise RuntimeError(f"Required style asset is missing: {asset}")
        if Path(asset).suffix.lower() == ".svg":
            if not QSvgRenderer(asset).isValid():
                raise RuntimeError(f"Style SVG asset cannot be decoded: {asset}")
        else:
            image = QImage(asset)
            if image.isNull():
                raise RuntimeError(f"Style raster asset cannot be decoded: {asset}")
    return len(checked)


def build_configuration(args: argparse.Namespace, scale: float, project_dir: str) -> Dict:
    assets = []
    for path in Path(project_dir).glob("**/*"):
        if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg", ".svg"}:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            assets.append((str(path.relative_to(project_dir)), digest))
    project_digest = hashlib.sha256(Path(args.project).read_bytes()).hexdigest()
    parking_path = Path(args.project).resolve().parent.parent / "data" / "parking" / "street_parking_points_processed.geojson"
    parking_digest = hashlib.sha256(parking_path.read_bytes()).hexdigest() if parking_path.is_file() else None
    value = {
        "version": 2,
        "project": os.path.abspath(args.project),
        "project_sha256": project_digest,
        "parking_points": str(parking_path),
        "parking_points_sha256": parking_digest,
        "assets": assets,
        "qgis": QgsApplication.applicationVersion(),
        "extent": args.extent,
        "zoom": [args.zmin, args.zmax],
        "metatile": args.metatile,
        "gutter": args.gutter,
        "dpi": args.dpi,
        "background": args.background,
        "format": args.format.lower(),
        "quality": args.quality,
        "advanced_effects": args.advanced_effects,
        "tree_mode": args.tree_mode,
        "mercator_scale": scale,
    }
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    value["configuration_id"] = hashlib.sha256(encoded).hexdigest()
    return value


def initialise_generation(out_dir: str, configuration: Dict, resume: bool) -> set[str]:
    path = manifest_path(out_dir)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            existing = json.load(fh)
        if existing.get("configuration_id") != configuration["configuration_id"]:
            raise RuntimeError(
                f"Output generation {out_dir} has a different manifest. Choose a new --out directory; "
                "do not mix render configurations."
            )
        if not resume:
            raise RuntimeError(f"Output generation {out_dir} already exists; use --resume or a new --out directory.")
    else:
        existing_files = [entry for entry in os.listdir(out_dir) if entry not in {".DS_Store"}]
        if existing_files:
            raise RuntimeError(
                f"Refusing legacy/nonempty output directory {out_dir}. Preserve it and use a new generation directory."
            )
        atomic_write_json(path, configuration)
    return load_completed_metatiles(out_dir, configuration["configuration_id"])


def select_layers(layers: Sequence, tree_mode: str) -> List:
    if tree_mode == "off":
        # Trees are meant to be excluded entirely in this mode, so a missing,
        # renamed, or broken tree-crown layer is not this mode's problem.
        return [layer for layer in layers if layer.name() != "tree crown"]
    tree_layers = [layer for layer in layers if layer.name() == "tree crown"]
    if len(tree_layers) != 1:
        raise RuntimeError(f"Expected exactly one visible 'tree crown' layer, found {len(tree_layers)}")
    if tree_mode == "full":
        return list(layers)
    return tree_layers


def current_rss_mb() -> Optional[float]:
    """Return current process RSS where the host exposes it, otherwise None."""
    try:
        raw = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(os.getpid())], text=True
        ).strip()
        return int(raw) / 1024.0
    except (ValueError, OSError, subprocess.CalledProcessError):
        return None


def matches_requested_metatile(mt: MetaTile, requested: Optional[str]) -> bool:
    if requested is None:
        return True
    try:
        z_text, x_text, y_text = requested.split(":")
        return (mt.z, mt.x0, mt.y0) == (int(z_text), int(x_text), int(y_text))
    except ValueError as exc:
        raise RuntimeError("--only-metatile must be z:x0:y0, for example 17:70536:43016") from exc


def run(args: argparse.Namespace) -> int:
    xmin, ymin, xmax, ymax = parse_extent(args.extent)
    fmt = "jpg" if args.format.lower() in ("jpg", "jpeg") else "png"
    try:
        bg_hex, background = parse_background_color(args.background)
    except ValueError as exc:
        log("ERROR", str(exc))
        return 1

    QgsApplication.setPrefixPath(resolve_qgis_prefix_path(), True)
    app = QgsApplication([], False)
    # QgsApplication construction re-derives macOS paths from its prefix, so the
    # bundle corrections must happen afterwards and before provider discovery.
    apply_qgis_macos_bundle_paths()
    if sys.platform == "darwin":
        bundle_contents = resolve_qgis_macos_bundle_contents()
        if bundle_contents:
            # The standalone bundle interpreter creates the provider singleton
            # before its derived plugin path is reliable. Construct it with the
            # known bundle provider directory explicitly.
            QgsProviderRegistry.instance(os.path.join(bundle_contents, "PlugIns", "qgis"))
    app.initQgis()
    install_qt_message_filter()
    if "postgres" not in QgsProviderRegistry.instance().providerList():
        log("ERROR", "QGIS PostgreSQL provider did not load; verify bundle bootstrap paths.")
        app.exitQgis()
        return 1

    try:
        resolved = resolve_project_path(args.project, args.advanced_effects)
    except Exception as exc:
        # Keep this on the same ERROR-log + clean-shutdown path as every other
        # failure in run() — a raw traceback here previously skipped both.
        log("ERROR", f"Failed to prepare render project: {exc}")
        app.exitQgis()
        return 1
    project = QgsProject.instance()
    render_error: Optional[str] = None
    restart_requested = False
    stop_requested_exit = False
    try:
        if not project.read(resolved.render_path):
            raise RuntimeError(f"Failed to read project: {resolved.render_path}")

        # The extracted QGS is deliberately placed beside the source QGZ. QGIS
        # derives @project_folder from this temporary filename, so expressions
        # resolve to style/ without changing or rewriting the source archive.
        project_dir = os.path.dirname(os.path.abspath(args.project))
        project.setPresetHomePath(project_dir)
        context_check = project.createExpressionContext()
        if os.path.normpath(str(context_check.variable("project_folder"))) != os.path.normpath(project_dir):
            raise RuntimeError("QGIS @project_folder did not resolve to the project style directory")
        asset_count = preflight_assets(project_dir)

        layers = collect_visible_layers(project, args.tree_mode)
        if not layers:
            raise RuntimeError("No layers selected for rendering")
        log("INFO", f"Loaded project with {len(layers)} selected visible layer(s); decoded {asset_count} raster asset(s).")

        project_crs = project.crs()
        crs_3857 = QgsCoordinateReferenceSystem("EPSG:3857")
        if not project_crs.isValid() or project_crs.authid() != "EPSG:3857":
            raise RuntimeError(f"Project CRS is {project_crs.authid() or 'invalid'}; expected EPSG:3857")
        scale, scale_desc = resolve_mercator_scale(project, xmin, ymin, xmax, ymax)
        QgsExpressionContextUtils.setProjectVariable(project, "mercator_scale", scale)
        configuration = build_configuration(args, scale, project_dir)
        log("INFO", f"@mercator_scale: {scale_desc}; generation={configuration['configuration_id'][:12]}")
        log("INFO", "Advanced QGIS effects: " + ("enabled (reference mode)" if args.advanced_effects else "disabled in extracted render project"))
        if args.preflight:
            log("INFO", "Preflight completed successfully.")
            return 0

        base_settings = QgsMapSettings()
        base_settings.setDestinationCrs(crs_3857)
        base_settings.setOutputDpi(args.dpi)
        base_settings.setEllipsoid(project.ellipsoid())
        base_settings.setBackgroundColor(background)
        base_settings.setFlag(QgsMapSettings.Antialiasing, True)
        base_settings.setFlag(QgsMapSettings.DrawLabeling, True)
        base_settings.setFlag(QgsMapSettings.UseAdvancedEffects, args.advanced_effects)
        base_settings.setFlag(QgsMapSettings.LosslessImageRendering, True)
        base_settings.setFlag(QgsMapSettings.RenderMapTile, True)
        base_settings.setFlag(QgsMapSettings.RenderBlocking, True)
        base_settings.setTransformContext(project.transformContext())
        base_settings.setPathResolver(project.pathResolver())
        base_settings.setExpressionContext(project.createExpressionContext())

        zoom_meta: List[Tuple[int, List[MetaTile]]] = []
        total_tiles = 0
        total_metas = 0
        for z in range(args.zmin, args.zmax + 1):
            tr = tile_range_for_bbox(xmin, ymin, xmax, ymax, z)
            metas = [mt for mt in iter_metatiles(tr, z, args.metatile, args.gutter) if matches_requested_metatile(mt, args.only_metatile)]
            zoom_meta.append((z, metas))
            total_tiles += sum(m.tile_count for m in metas)
            total_metas += len(metas)
        if args.only_metatile and total_metas != 1:
            raise RuntimeError(f"Requested metatile {args.only_metatile} was not found exactly once in this extent/grid")

        os.makedirs(args.out, exist_ok=True)
        completed = initialise_generation(args.out, configuration, args.resume)
        log("INFO", f"Rendering {total_tiles} tile(s) in {total_metas} metatile(s) → {args.out}")
        started = time.monotonic()
        verified_tiles = skipped_tiles = newly_rendered_tiles = done_metas = written_total = 0
        rendered_metas = 0
        for z, metas in zoom_meta:
            for mt in metas:
                if args.resume and metatile_already_rendered(mt, args.out, fmt, completed):
                    skipped_tiles += mt.tile_count
                    verified_tiles += mt.tile_count
                    done_metas += 1
                    print_progress(zoom=z, zmax=args.zmax, meta_done=done_metas, meta_total=total_metas, verified_tiles=verified_tiles, total_tiles=total_tiles, render_elapsed=time.monotonic() - started, newly_rendered_tiles=newly_rendered_tiles, skipped_tiles=skipped_tiles)
                    continue
                try:
                    written, render_seconds, diagnostics = render_metatile(base_settings, layers, mt, args.out, fmt, args.quality, crs_3857, background)
                    rss_mb = current_rss_mb()
                    append_completion(args.out, {"configuration_id": configuration["configuration_id"], "metatile": metatile_key(mt), "status": "committed", "tiles": written, "render_seconds": round(render_seconds, 3), "rss_mb": rss_mb, "diagnostics": diagnostics, "timestamp": time.time()})
                except RuntimeError as exc:
                    append_completion(args.out, {"configuration_id": configuration["configuration_id"], "metatile": metatile_key(mt), "status": "failed", "error": str(exc), "timestamp": time.time()})
                    raise
                completed.add(metatile_key(mt))
                written_total += written
                newly_rendered_tiles += written
                verified_tiles += written
                done_metas += 1
                rendered_metas += 1
                print_progress(zoom=z, zmax=args.zmax, meta_done=done_metas, meta_total=total_metas, verified_tiles=verified_tiles, total_tiles=total_tiles, render_elapsed=time.monotonic() - started, newly_rendered_tiles=newly_rendered_tiles, skipped_tiles=skipped_tiles)
                rss_mb = current_rss_mb()
                if _stop_requested:
                    log("WARN", f"Stop requested; exiting after {rendered_metas} metatile(s) this run.")
                    stop_requested_exit = True
                    break
                if (args.max_rss_mb and rss_mb and rss_mb > args.max_rss_mb) or (args.max_metatiles_per_worker and rendered_metas >= args.max_metatiles_per_worker):
                    log("WARN", f"Worker recycle requested after {rendered_metas} metatile(s); RSS={rss_mb:.1f} MB" if rss_mb else f"Worker recycle requested after {rendered_metas} metatile(s)")
                    restart_requested = True
                    break
            if restart_requested or stop_requested_exit:
                break
    except RuntimeError as exc:
        render_error = str(exc)
    finally:
        finish_progress_line()
        app.exitQgis()
        resolved.cleanup()

    if render_error:
        log("ERROR", render_error)
        return 1
    if stop_requested_exit:
        log("INFO", "Stopped by request; resume with --resume.")
        return STOP_EXIT
    if restart_requested:
        return RESTART_EXIT
    log("INFO", "Rendering completed successfully.")
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Render XYZ tiles via PyQGIS metatile loop")
    p.add_argument("--project", required=True, help="Path to .qgz / .qgs")
    p.add_argument(
        "--extent",
        required=True,
        help='Extent as "xmin,xmax,ymin,ymax [EPSG:4326]"',
    )
    p.add_argument("--out", required=True, help="Output tile directory")
    p.add_argument("--zmin", type=int, default=15)
    p.add_argument("--zmax", type=int, default=20)
    p.add_argument("--metatile", type=int, default=8)
    p.add_argument(
        "--gutter",
        type=int,
        default=1,
        help="Extra tiles around each metatile for labels/symbols (discarded after render)",
    )
    p.add_argument("--dpi", type=int, default=96)
    p.add_argument(
        "--advanced-effects",
        action="store_true",
        help="Enable QGIS shadows, glows, and other advanced effects for reference renders",
    )
    p.add_argument(
        "--background",
        default=DEFAULT_BACKGROUND,
        help=f"Tile background colour as #rrggbb (default: {DEFAULT_BACKGROUND})",
    )
    p.add_argument("--format", default="jpg", choices=["png", "jpg", "jpeg", "PNG", "JPG", "JPEG"])
    p.add_argument("--quality", type=int, default=90, help="JPEG quality")
    p.add_argument(
        "--resume",
        action="store_true",
        help="Resume only matching, committed and decodable metatiles",
    )
    p.add_argument("--preflight", action="store_true", help="Validate QGIS, visible layers, paths, and raster assets without rendering")
    p.add_argument("--tree-mode", choices=["full", "off", "only"], default="full", help="Render all layers, omit tree crown, or render only tree crown")
    p.add_argument("--only-metatile", help="Render one core metatile as z:x0:y0 (for example 17:70536:43016)")
    p.add_argument("--max-metatiles-per-worker", type=int, default=0, help="Exit 75 after this many committed metatiles for supervisor recycling")
    p.add_argument("--max-rss-mb", type=float, default=0, help="Exit 75 after a committed metatile exceeds this RSS ceiling")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if args.zmin > args.zmax:
        log("ERROR", f"Invalid zoom range: {args.zmin}-{args.zmax}")
        return 1
    if args.metatile < 1:
        log("ERROR", f"Invalid metatile size: {args.metatile}")
        return 1
    if args.gutter < 0:
        log("ERROR", f"Invalid gutter: {args.gutter}")
        return 1
    if not os.path.isfile(args.project):
        log("ERROR", f"Project not found: {args.project}")
        return 1
    if args.max_metatiles_per_worker < 0 or args.max_rss_mb < 0:
        log("ERROR", "Worker and RSS limits must be non-negative")
        return 1
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    try:
        return run(args)
    except ValueError as exc:
        log("ERROR", str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
