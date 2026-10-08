#!/usr/bin/env python3
"""Golden count/validity audit for QGIS barrier-way MarkerLine geometry."""
from __future__ import annotations

import json
import os
import subprocess

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5433")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_NAME = os.environ.get("DB_NAME", "strassenraumkarte")


SQL = r"""
WITH lines AS (
 -- QGIS: retaining walls under 1 m (height NULL counts as tall) use a 0.33 m offset and 0.65 m interval, the rest 1 m and 2 m
 SELECT barrier, ST_Length(dump.geom) len,
  CASE WHEN barrier='retaining_wall' THEN CASE WHEN COALESCE(height<1,false) THEN 0.33 ELSE 1 END ELSE 0 END off_m,
  CASE WHEN barrier='bollard' THEN 1.5 WHEN barrier='palisade' THEN .2
       WHEN COALESCE(height<1,false) THEN .65 ELSE 2 END step_m
 FROM barrier_way CROSS JOIN LATERAL ST_Dump(geom) dump
 WHERE barrier IN ('bollard','palisade','retaining_wall')
), expected AS (
 SELECT barrier, sum(GREATEST(0, floor((len-off_m-1e-9)/step_m)::int+1)) n
 FROM lines WHERE len>off_m
 GROUP BY barrier
), actual AS (SELECT barrier,count(*) n,bool_and(ST_IsValid(geom)) valid,min(ST_Area(geom)) min_area,max(ST_Area(geom)) max_area FROM barrier_way_marker_polygons GROUP BY barrier)
SELECT json_agg(json_build_object('barrier',e.barrier,'expected',e.n,'actual',coalesce(a.n,0),'valid',coalesce(a.valid,false),'min_area',a.min_area,'max_area',a.max_area) ORDER BY e.barrier) FROM expected e LEFT JOIN actual a USING(barrier);
"""

ORIENTATION_SQL = r"""
WITH vectors AS (
 SELECT marker.*, ST_PointN(ST_ExteriorRing(marker.geom),2) a,
   ST_PointN(ST_ExteriorRing(marker.geom),3) b,
   ST_LineInterpolatePoint(source.geom,GREATEST(0,marker.distance_along-2)/ST_Length(source.geom)) p1,
   ST_LineInterpolatePoint(source.geom,LEAST(ST_Length(source.geom),marker.distance_along+2)/ST_Length(source.geom)) p2
 FROM barrier_way_marker_polygons marker JOIN barrier_way source USING(osm_id)
 WHERE marker.barrier='retaining_wall'
), errors AS (
 SELECT abs(1 - abs(((ST_X(b)-ST_X(a))*(ST_Y(p2)-ST_Y(p1))-(ST_Y(b)-ST_Y(a))*(ST_X(p2)-ST_X(p1))) / NULLIF(ST_Distance(a,b)*ST_Distance(p1,p2),0))) AS angular_error
 FROM vectors
) SELECT coalesce(max(angular_error),0) FROM errors;
"""


def main() -> None:
    result = subprocess.run([
        "psql", "--no-psqlrc", "-XAt", "-h", DB_HOST, "-p", DB_PORT,
        "-U", DB_USER, "-d", DB_NAME, "-c", SQL,
    ], check=True, text=True, capture_output=True)
    rows = json.loads(result.stdout)
    # QGIS SimpleMarker circles are buffered at radius size/2 (quad_segs=8);
    # retaining walls use the equilateral-triangle transform.
    # Retaining-wall triangles are 0.6 m (tall) or 0.4 m (< 1 m high): area scales with size^2.
    expected_area = {
        "bollard": (0.12485780609032203, 0.12485780609032203),
        "palisade": (0.03121445152258051, 0.03121445152258051),
        "retaining_wall": (0.06, 0.135),
    }
    errors = [
        row for row in rows
        if row["expected"] != row["actual"] or not row["valid"]
        or abs(row["min_area"] - expected_area[row["barrier"]][0]) > 1e-9
        or abs(row["max_area"] - expected_area[row["barrier"]][1]) > 1e-9
    ]
    orientation = subprocess.run([
        "psql", "--no-psqlrc", "-XAt", "-h", DB_HOST, "-p", DB_PORT,
        "-U", DB_USER, "-d", DB_NAME, "-c", ORIENTATION_SQL,
    ], check=True, text=True, capture_output=True)
    # The first triangle edge is perpendicular to the averaged line tangent.
    if float(orientation.stdout) > 1e-8:
        errors.append({"max_retaining_wall_orientation_error": orientation.stdout.strip()})
    if errors:
        raise SystemExit(f"FAIL: {errors}")
    print("PASS: barrier MarkerLine counts, dimensions, orientation, and polygon validity match QGIS intervals")


if __name__ == "__main__":
    main()
