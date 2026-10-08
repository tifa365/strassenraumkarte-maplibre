#!/usr/bin/env python3
"""QGIS simple-marker symbols of the feature_node layers, as sprite specs.

The QGIS ``feature_node (middleground / foreground)`` layers draw most street
furniture (lamps, cabinets, vending machines, columns, wells, signs ...) with
SimpleMarker layers whose size, outline width and offsets are data-defined
ground metres (``@mercator_scale * x``). MapLibre has no such markers, so each
symbol becomes a sprite that QGIS itself renders (``render()``), square, 64
logical px, covering ``box`` ground metres: the existing ``icon-size`` expression
(``symbol_size_m / 64``) scales it, and ``web_symbol_names.sql`` selects the sprite
per feature and sets ``icon_rotation`` (the frame in which each spec is drawn).

Facts that differ from what the project file suggests, checked in QGIS 4.2:

* line-shaped markers (``cross2``, ``line``) are drawn in the *outline* colour,
  their fill colour is ignored (a lamp's "red cross" is grey);
* sizes of layers with a data-defined ``size`` are ground metres, static values
  are map units (~0.61 m at Berlin) and are never used here.

Each ``Layer`` is one SimpleMarker (or an SVG): ``size`` and ``stroke_width`` in
metres, ``offset`` (x east, y north) in metres in the sprite frame, ``angle`` in
degrees clockwise in that frame.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

RGBA = tuple[int, int, int, int]
LOGICAL_SIZE = 64


@dataclass(frozen=True)
class Layer:
    shape: str  # QGIS SimpleMarker name, or "svg"
    size: float
    fill: RGBA | None = None
    stroke: RGBA | None = None
    stroke_width: float = 0.0
    offset: tuple[float, float] = (0.0, 0.0)
    angle: float = 0.0
    svg: str | None = None  # path relative to style/symbols
    char: str | None = None  # shape "font": glyph drawn with ``font``
    font: str = "DejaVu Sans"


@dataclass(frozen=True)
class Marker:
    name: str
    box: float  # ground metres covered by the 64 logical px square
    layers: tuple[Layer, ...] = field(default_factory=tuple)
    alpha: float = 1.0


GREY80 = (128, 128, 128, 255)
GREY80_DARK = (80, 80, 80, 255)
TEAL = (99, 217, 198, 255)


def circle(size, fill, stroke=None, stroke_width=0.0, **kw):
    return Layer("circle", size, fill, stroke, stroke_width, **kw)


MARKERS: tuple[Marker, ...] = (
    Marker("marker-street-lamp", 1.0, (
        circle(0.67, (218, 218, 218, 255), GREY80, 0.11),
        Layer("cross2", 0.45, (255, 0, 0, 255), GREY80, 0.11),
    )),
    # horizontal bent mast (6 m SVG, drawn rotated by direction - 90): the lamp head sits at
    # 2.55 m opposite the mast's +x axis
    Marker("icon-highway-street-lamp-bent-mast", 6.0, (
        Layer("svg", 6.0, (128, 128, 128, 255), (35, 35, 35, 255), 0.2, svg="highway/street_lamp_bent_mast.svg"),
        circle(0.67, (218, 218, 218, 171), GREY80, 0.11, offset=(-2.55, 0.0)),
        Layer("cross2", 0.45, (255, 0, 0, 255), GREY80, 0.11, offset=(-2.55, 0.0)),
        circle(0.35, GREY80),
    )),
    # wall lamp, drawn in the frame rotated by direction: head 0.4 m behind the line
    Marker("marker-street-lamp-wall", 1.6, (
        Layer("line", 0.4, (255, 0, 0, 255), (96, 96, 96, 255), 0.3),
        circle(0.67, (218, 218, 218, 255), GREY80, 0.11, offset=(0.0, -0.4)),
        Layer("cross2", 0.45, (255, 0, 0, 255), GREY80, 0.11, offset=(0.0, -0.4)),
    )),
    Marker("marker-street-cabinet", 1.0, (
        Layer("half_square", 0.8, TEAL, (128, 128, 128, 255), 0.05),
    )),
    Marker("marker-vending-machine", 0.5, (
        Layer("square", 0.3, TEAL, (128, 128, 128, 255), 0.04),
    )),
    # QGIS draws the parking_tickets rule and the general vending_machine rule: both squares
    Marker("marker-parking-tickets", 0.7, (
        Layer("square", 0.5, TEAL, (128, 128, 128, 255), 0.04),
        Layer("square", 0.3, TEAL, (128, 128, 128, 255), 0.04),
    )),
    Marker("marker-advertising-column", 2.0, (
        circle(1.6, (208, 208, 197, 255), GREY80_DARK, 0.2),
        circle(1.0, (208, 208, 197, 255), GREY80_DARK, 0.12),
    )),
    Marker("marker-water-well", 1.5, (Layer("arrow", 1.25, GREY80),)),
    Marker("marker-charging-station", 0.7, (
        Layer("square", 0.5, (116, 176, 217, 255), GREY80_DARK, 0.05),
    )),
    Marker("marker-drinking-water", 0.8, (circle(0.6, (214, 216, 237, 255), GREY80_DARK, 0.06),)),
    Marker("marker-clock", 0.8, (Layer("square", 0.6, TEAL, (35, 35, 35, 255), 0.06),)),
    Marker("marker-planter", 1.0, (circle(0.75, (199, 214, 184, 255), GREY80_DARK, 0.12),)),
    Marker("marker-shelter", 3.4, (circle(3.0, (218, 218, 218, 255), GREY80_DARK, 0.12),)),
    Marker("marker-pole", 0.6, (circle(0.5, GREY80),)),
    Marker("marker-monitoring-station", 0.4, (circle(0.3, GREY80),)),
    Marker("marker-mast", 0.9, (circle(0.75, GREY80),)),
    # fire hydrants: red "H" at scales <= 1:1500 for underground/other types (own layer from
    # MapLibre z17.59), a 0.7 m ring with a 0.2 m red outline for pillar/pipe/wall hydrants
    Marker("marker-fire-hydrant-h", 0.9, (
        Layer("font", 0.7, (255, 0, 0, 255), (255, 0, 0, 255), 0.06, char="H"),
    )),
    Marker("marker-fire-hydrant-ring", 1.1, (
        circle(0.7, (255, 0, 0, 0), (255, 0, 0, 255), 0.2),
    )),
    Marker("marker-flagpole", 0.4, (circle(0.3, GREY80),)),  # the "~" flag glyph is not drawn
    Marker("marker-grit-bin", 1.4, (
        Layer("half_square", 1.0, (233, 169, 95, 255), (139, 133, 121, 255), 0.2),
    )),
    Marker("marker-chimney", 1.5, (circle(1.25, (80, 80, 80, 128), GREY80_DARK, 0.12),)),
    Marker("marker-public-bookcase", 1.2, (
        Layer("octagon", 1.0, (183, 145, 110, 128), (183, 145, 110, 255), 0.06),
    )),
    Marker("marker-stolperstein", 0.4, (
        Layer("square", 0.3, (201, 180, 106, 191), (171, 124, 44, 255), 0.03),
    )),
    Marker("marker-guard-stone", 0.8, (
        Layer("filled_arrowhead", 0.5, GREY80, GREY80, 0.1, offset=(0.25, 0.0)),
    )),
    # traffic signs, drawn rotated by direction + 180; the pole variants have a 0.2 m post line
    Marker("marker-traffic-sign", 1.2, (
        Layer("line", 0.2, GREY80, GREY80, 0.16, offset=(0.0, 0.4)),
        Layer("pentagon", 0.67, (237, 237, 237, 128), GREY80, 0.11),
    )),
    Marker("marker-traffic-sign-wall", 1.2, (
        Layer("pentagon", 0.33, (237, 237, 237, 128), GREY80, 0.11),
    )),
    Marker("marker-traffic-sign-street-name", 1.2, (
        Layer("line", 0.2, (255, 0, 0, 255), GREY80, 0.16, offset=(0.0, 0.1)),
    )),
    Marker("marker-traffic-sign-arrows", 1.2, (
        Layer("line", 0.15, GREY80, GREY80, 0.11, offset=(0.0, 0.4)),
    )),
)


def render(marker: Marker, pixel_ratio: int, symbols_dir: Path):
    """Render a Marker with QGIS into a square QImage (64 * pixel_ratio px)."""
    from qgis.core import (
        QgsFontMarkerSymbolLayer, QgsMarkerSymbol, QgsRenderContext, QgsSimpleMarkerSymbolLayer,
        QgsSvgMarkerSymbolLayer,
    )
    from qgis.PyQt.QtCore import QPointF, Qt
    from qgis.PyQt.QtGui import QImage, QPainter

    side = LOGICAL_SIZE * pixel_ratio
    px_per_m = side / marker.box

    def color(value: RGBA | None) -> str:
        return "0,0,0,0" if value is None else ",".join(str(c) for c in value)

    def layer_for(spec: Layer):
        props = {
            "size": str(spec.size * px_per_m),
            "size_unit": "Pixel",
            "outline_width": str(spec.stroke_width * px_per_m),
            "outline_width_unit": "Pixel",
            # QGIS marker offsets have y pointing down
            "offset": f"{spec.offset[0] * px_per_m},{-spec.offset[1] * px_per_m}",
            "offset_unit": "Pixel",
            "angle": str(spec.angle),
            "color": color(spec.fill),
            "outline_color": color(spec.stroke),
            "outline_style": "no" if spec.stroke is None or spec.stroke_width == 0 else "solid",
        }
        if spec.shape == "font":
            props["chr"] = spec.char
            props["font"] = spec.font
            return QgsFontMarkerSymbolLayer.create(props)
        if spec.shape == "svg":
            props["name"] = str(symbols_dir / spec.svg)
            return QgsSvgMarkerSymbolLayer.create(props)
        props["name"] = spec.shape
        return QgsSimpleMarkerSymbolLayer.create(props)

    symbol = QgsMarkerSymbol.createSimple({})
    symbol.deleteSymbolLayer(0)
    for spec in marker.layers:
        symbol.appendSymbolLayer(layer_for(spec))
    image = QImage(side, side, QImage.Format.Format_ARGB32_Premultiplied)
    image.fill(Qt.GlobalColor.transparent)
    painter = QPainter(image)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    context = QgsRenderContext.fromQPainter(painter)
    symbol.startRender(context)
    symbol.renderPoint(QPointF(side / 2, side / 2), None, context)
    symbol.stopRender(context)
    painter.end()
    return image
