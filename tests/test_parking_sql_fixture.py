#!/usr/bin/env python3
"""Exercise every PostGIS parking stage on a deterministic synthetic extract."""
import os
import pathlib
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
STAGES = sorted((ROOT / "data/processing/sql").glob("parking_*.sql"))


def psql(schema, sql=None, file=None):
    cmd = ["psql", "--no-psqlrc", "-X", "-At", "-h", os.environ.get("DB_HOST", "localhost"),
           "-p", os.environ.get("DB_PORT", "5433"), "-U", os.environ.get("DB_USER", "postgres"),
           "-d", os.environ.get("DB_NAME", "strassenraumkarte"), "-v", "ON_ERROR_STOP=1",
           "-v", f"schema={schema}"]
    if sql is not None:
        cmd += ["-c", sql]
    else:
        cmd += ["-f", str(file)]
    return subprocess.run(cmd, input=None, text=True, check=True, capture_output=True)


def main():
    if not subprocess.run(["sh", "-c", "command -v psql >/dev/null"], check=False).returncode == 0:
        print("SKIP: psql is unavailable")
        return
    schema = "parking_fixture_" + uuid.uuid4().hex[:16]
    setup = f"""
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA {schema};
CREATE TABLE {schema}.raw_ways(osm_type text,osm_id bigint,tags jsonb,node_ids jsonb,is_area boolean,geom geometry(LineString,3857));
CREATE TABLE {schema}.raw_nodes(osm_type text,osm_id bigint,tags jsonb,geom geometry(Point,3857));
CREATE TABLE {schema}.raw_relations(osm_type text,osm_id bigint,tags jsonb,members jsonb);
INSERT INTO {schema}.raw_ways VALUES
 ('W',1,'{{"highway":"residential","parking:right":"lane","parking:right:orientation":"parallel","parking:right:capacity":"3","width":"8"}}','[1,2]',false,ST_Transform(ST_GeomFromText('LINESTRING(13.4 52.4,13.402 52.4)',4326),3857)),
 ('W',2,'{{"highway":"service","service":"driveway"}}','[3,4]',false,ST_Transform(ST_GeomFromText('LINESTRING(13.401 52.3995,13.401 52.4005)',4326),3857));
INSERT INTO {schema}.raw_nodes VALUES
 ('N',10,'{{"highway":"crossing","crossing":"zebra"}}',ST_Transform(ST_SetSRID(ST_MakePoint(13.401,52.4),4326),3857)),
 ('N',11,'{{"amenity":"parking_space","parking:orientation":"parallel"}}',ST_Transform(ST_SetSRID(ST_MakePoint(13.4003,52.4),4326),3857));
"""
    try:
        psql(schema, sql=setup)
        for stage in STAGES:
            psql(schema, file=stage)
        result = psql(schema, sql=f"SELECT count(*), count(DISTINCT space_id), bool_and(ST_SRID(geom)=3857), bool_and(orientation IN ('parallel','diagonal','perpendicular')) FROM {schema}.parking_points").stdout.strip()
        values = result.split("|")
        if values[0] != "3" or values[1] != "3" or values[2] != "t" or values[3] != "t":
            raise AssertionError(result)
        print(f"PASS: synthetic PostGIS parking pipeline produced {values[0]} stable valid points")
    finally:
        psql(schema, sql=f"DROP SCHEMA IF EXISTS {schema} CASCADE")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(exc.stderr or str(exc), file=sys.stderr)
        raise
