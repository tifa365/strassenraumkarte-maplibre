#!/usr/bin/env python3
"""Verify QGIS HashLine-derived highway and railway polygon counts."""
from __future__ import annotations

import json
import os
import subprocess

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5433")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_NAME = os.environ.get("DB_NAME", "strassenraumkarte")

SQL = r"""
WITH expected_highway AS (
 SELECT CASE WHEN highway='steps' THEN 'steps' ELSE 'access_aisle' END kind,
 sum(GREATEST(0,floor((ST_Length(dump.geom)-1e-9)/metres(CASE WHEN highway='steps' THEN .6 ELSE 1 END))::int+1)) n
 FROM highway CROSS JOIN LATERAL ST_Dump(geom) dump
 WHERE (highway='steps' OR class='access_aisle') AND COALESCE(tunnel,'') <> 'yes'
 GROUP BY kind
), actual_highway AS (SELECT kind,count(*) n,bool_and(ST_IsValid(geom)) valid FROM highway_hashes GROUP BY kind),
expected_rail AS (SELECT sum(GREATEST(0,floor((ST_Length(dump.geom)-1e-9)/metres(.9))::int+1)) n FROM railway_way CROSS JOIN LATERAL ST_Dump(geom) dump WHERE tunnel IS DISTINCT FROM 'yes'),
actual_rail AS (SELECT count(*) n,bool_and(ST_IsValid(geom)) valid FROM railway_ties)
SELECT json_build_object('highway',(SELECT json_agg(json_build_object('kind',e.kind,'expected',e.n,'actual',a.n,'valid',a.valid)) FROM expected_highway e JOIN actual_highway a USING(kind)),'railway',json_build_object('expected',(SELECT coalesce(n,0) FROM expected_rail),'actual',(SELECT n FROM actual_rail),'valid',(SELECT coalesce(valid,true) FROM actual_rail)));
"""
r = subprocess.run(['psql','--no-psqlrc','-XAt','-h',DB_HOST,'-p',DB_PORT,'-U',DB_USER,'-d',DB_NAME,'-c',SQL],capture_output=True,text=True,check=True)
data=json.loads(r.stdout)
bad=[x for x in (data['highway'] or []) if x['expected']!=x['actual'] or not x['valid']]
rail=data['railway']
if bad or rail['expected']!=rail['actual'] or not rail['valid']:
 raise SystemExit(f'FAIL: {data}')
print('PASS: highway and railway HashLine counts and validity match QGIS intervals')
