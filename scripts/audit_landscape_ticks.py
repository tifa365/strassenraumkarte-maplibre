#!/usr/bin/env python3
"""Check the QGIS landscape-way MarkerLine triangles in landscape_ticks.

QGIS draws them only for embankment, cliff and earth_bank, with data-defined
ground-metre values halved for ways shorter than 20 map units: size 1.6 m,
interval 2.4 m, first marker at 0.8 m, offset 0.6 m to the left, pointing away
from the way (see web_landscape_ticks.sql).
"""
from __future__ import annotations
import json
import os
import subprocess

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5433")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_NAME = os.environ.get("DB_NAME", "strassenraumkarte")

SQL = """
WITH parts AS (
 SELECT osm_id, dump.geom line_geom, ST_Length(dump.geom) len,
  metres(CASE WHEN ST_Length(w.geom) < 20 THEN 0.5 ELSE 1 END) k
 FROM landscape_way w CROSS JOIN LATERAL ST_Dump(geom) dump
 WHERE class IN ('embankment', 'cliff', 'earth_bank')
), expected AS (
 SELECT sum(CASE WHEN len >= 0.8 * k THEN floor((len - 0.8 * k) / (2.4 * k) + 1e-9)::int + 1 ELSE 0 END) n
 FROM parts
), ticks AS (
 SELECT t.geom, p.k, p.line_geom,
  -- apex = first vertex; equilateral triangle with circumradius 0.8 k
  abs(ST_Area(t.geom) - 1.2990381 * (0.8 * p.k) ^ 2) area_error,
  ST_Distance(ST_Centroid(t.geom), p.line_geom) / p.k centre_distance,
  ST_Distance(ST_PointN(ST_ExteriorRing(t.geom), 1), p.line_geom)
   > ST_Distance(ST_Centroid(t.geom), p.line_geom) apex_outward,
  -- left of the way: the centroid's cross product with the local tangent is positive
  (ST_X(b) - ST_X(a)) * (ST_Y(ST_Centroid(t.geom)) - ST_Y(a))
   - (ST_Y(b) - ST_Y(a)) * (ST_X(ST_Centroid(t.geom)) - ST_X(a)) > 0 left_side
 FROM landscape_ticks t
 JOIN LATERAL (SELECT * FROM parts WHERE parts.osm_id = t.osm_id ORDER BY ST_Distance(parts.line_geom, t.geom) LIMIT 1) p ON true
 CROSS JOIN LATERAL (
  SELECT ST_LineInterpolatePoint(p.line_geom, GREATEST(0, ST_LineLocatePoint(p.line_geom, ST_Centroid(t.geom)) - 0.5 / p.len)) a,
         ST_LineInterpolatePoint(p.line_geom, LEAST(1, ST_LineLocatePoint(p.line_geom, ST_Centroid(t.geom)) + 0.5 / p.len)) b
 ) ab
)
SELECT json_build_object(
 'expected', (SELECT n FROM expected),
 'actual', (SELECT count(*) FROM landscape_ticks),
 'other_classes', (SELECT count(*) FROM landscape_ticks JOIN landscape_way USING (osm_id)
                   WHERE class NOT IN ('embankment', 'cliff', 'earth_bank')),
 'valid', (SELECT bool_and(ST_IsValid(geom)) FROM landscape_ticks),
 'max_area_error', (SELECT max(area_error) FROM ticks),
 'median_centre_distance', (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY centre_distance) FROM ticks),
 'apex_outward_share', (SELECT avg(apex_outward::int) FROM ticks),
 'left_side_share', (SELECT avg(left_side::int) FROM ticks));
"""
r = subprocess.run(
    ['psql', '--no-psqlrc', '-XAt', '-h', DB_HOST, '-p', DB_PORT, '-U', DB_USER, '-d', DB_NAME, '-c', SQL],
    capture_output=True, text=True, check=True,
)
row = json.loads(r.stdout)
ok = (
    row['expected'] == row['actual']
    and row['other_classes'] == 0
    and row['valid']
    and row['max_area_error'] < 1e-6
    # the centre sits 0.6 k from the way; curves and line ends pull the median slightly
    and abs(row['median_centre_distance'] - 0.6) < 0.02
    and row['apex_outward_share'] > 0.99
    and row['left_side_share'] > 0.99
)
if not ok:
    raise SystemExit(f'FAIL: {row}')
print(
    f"PASS: {row['actual']} landscape MarkerLine triangles match QGIS classes, counts, size, "
    f"offset (median {row['median_centre_distance']:.3f} k), side and orientation"
)
