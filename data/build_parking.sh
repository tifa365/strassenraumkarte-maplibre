#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/data/db_config.sh"
SQL_DIR="$ROOT/data/processing/sql"; PARKING_DIR="$ROOT/data/parking"
IMPORT_LUA="$ROOT/data/lua/parking_import.lua"; CURRENT="$PARKING_DIR/street_parking_points_processed.geojson"
DATA=""; BBOX=""; RESUME=""; PUBLISH=""
STAGES=(parking_01_normalize.sql parking_02_lanes.sql parking_03_obstructions.sql parking_04_separate.sql parking_05_points.sql)
usage(){ echo "Usage: $0 --data PBF [--bbox xmin,ymin,xmax,ymax] [--resume ID] | $0 --publish ID"; }
while [[ $# -gt 0 ]]; do
 case "$1" in
  --data) DATA=${2:?--data requires a file}; shift 2;;
  --bbox) BBOX=${2:?--bbox requires four coordinates}; shift 2;;
  --resume) RESUME=${2:?--resume requires an id}; shift 2;;
  --publish) PUBLISH=${2:?--publish requires an id}; shift 2;;
  -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; usage >&2; exit 2;;
 esac
done
if [[ -n "$PUBLISH" ]]; then
 [[ "$PUBLISH" =~ ^[0-9a-f]{16,64}$ ]] || { echo "Invalid hexadecimal generation id." >&2; exit 2; }
 STAGE_DIR="$PARKING_DIR/$PUBLISH"; MANIFEST="$STAGE_DIR/manifest.json"; [[ -f "$MANIFEST" ]] || { echo "Generation manifest not found." >&2; exit 1; }
 STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$MANIFEST"); [[ "$STATUS" == validated ]] || { echo "Generation is not validated (status=$STATUS)." >&2; exit 1; }
 mkdir "$PARKING_DIR/.publish.lock" 2>/dev/null || { echo "Another publication is in progress." >&2; exit 1; }; trap 'rmdir "$PARKING_DIR/.publish.lock" 2>/dev/null || true' EXIT
 [[ ! -e "$PARKING_DIR/.render.lock" ]] || { echo "Renderer is using current parking data." >&2; exit 1; }
 [[ -f "$STAGE_DIR/street_parking_points.geojson" ]] || { echo "Validated GeoJSON missing." >&2; exit 1; }
  python3 - "$MANIFEST" "$STAGE_DIR/street_parking_points.geojson" <<'PY'
import hashlib,json,sys
m=json.load(open(sys.argv[1],encoding='utf8')); actual=hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest()
if actual != m.get('output_sha256'): raise SystemExit('validated GeoJSON hash does not match manifest')
PY
 mkdir -p "$PARKING_DIR/rollback"
 if [[ -f "$CURRENT" ]]; then
   ROLLBACK="$PARKING_DIR/rollback/street_parking_points_$(date +%Y%m%d%H%M%S).geojson"
   [[ ! -e "$ROLLBACK" ]] || ROLLBACK="$PARKING_DIR/rollback/street_parking_points_$(date +%Y%m%d%H%M%S).$$.geojson"
   cp -p "$CURRENT" "$ROLLBACK"
 fi
 TMP="$PARKING_DIR/.street_parking_points_processed.geojson.tmp"; cp "$STAGE_DIR/street_parking_points.geojson" "$TMP"; mv -f "$TMP" "$CURRENT"
 python3 - "$MANIFEST" "$CURRENT" <<'PY'
import hashlib,json,sys,time
p,o=sys.argv[1:]; m=json.load(open(p,encoding='utf8')); m.update(status='published',published_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),published_sha256=hashlib.sha256(open(o,'rb').read()).hexdigest()); open(p,'w',encoding='utf8').write(json.dumps(m,indent=2,sort_keys=True)+'\n')
PY
 echo "$PUBLISH"; exit 0
fi
[[ -z "$PUBLISH" || ( -z "$DATA" && -z "$RESUME" ) ]] || { echo "--publish cannot be combined with --data/--resume." >&2; exit 2; }
[[ -n "$DATA" && -f "$DATA" ]] || { echo "PBF does not exist: $DATA" >&2; exit 1; }
[[ -z "$BBOX" || "$BBOX" =~ ^-?[0-9]+([.][0-9]+)?,-?[0-9]+([.][0-9]+)?,-?[0-9]+([.][0-9]+)?,-?[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid bbox." >&2; exit 2; }
if [[ -n "$BBOX" ]]; then
 python3 - "$BBOX" <<'PY'
import math,sys
v=[float(x) for x in sys.argv[1].split(',')]
if not all(math.isfinite(x) for x in v) or v[0] >= v[2] or v[1] >= v[3] or not (-180 <= v[0] <= 180 and -180 <= v[2] <= 180 and -90 <= v[1] <= 90 and -90 <= v[3] <= 90):
    raise SystemExit('Invalid bbox extent: require finite WGS84 xmin<xmax and ymin<ymax')
PY
fi
command -v osm2pgsql >/dev/null || { echo "osm2pgsql is required." >&2; exit 1; }; command -v psql >/dev/null || { echo "psql is required." >&2; exit 1; }; command -v osmium >/dev/null || { echo "osmium is required." >&2; exit 1; }
SHA=$(shasum -a 256 "$DATA" | awk '{print $1}'); HEADER_TS=$(osmium fileinfo -e -j "$DATA" 2>/dev/null | python3 -c 'import json,sys; h=json.load(sys.stdin).get("header",{}); print(h.get("timestamp") or h.get("option",{}).get("timestamp") or h.get("option",{}).get("osmosis_replication_timestamp") or "unknown")')
UPSTREAM="$PARKING_DIR/reference/upstream/street_parking.py"
[[ -f "$UPSTREAM" ]] || { mkdir -p "$(dirname "$UPSTREAM")"; git clone -q https://github.com/SupaplexOSM/street_parking.py.git "$PARKING_DIR/reference/upstream"; (cd "$PARKING_DIR/reference/upstream" && git checkout -q 96debe3635ff7c63800d968270db7ae3b21c48e0); }
UPSTREAM_SHA=$(shasum -a 256 "$UPSTREAM" | awk '{print $1}'); CODE_SHA=$({ shasum -a 256 "$ROOT/data/build_parking.sh" "$ROOT/data/lua/parking_import.lua" "$ROOT/data/parking_export.py"; find "$ROOT/data/processing/sql" -name 'parking_*.sql' -print0 | sort -z | xargs -0 shasum -a 256; } | shasum -a 256 | awk '{print $1}')
PARAMS='{"round_method":"floor","width_parallel":2,"width_diagonal":4.5,"width_perpendicular":5,"car_distance_parallel":5.2,"car_distance_diagonal":3.1,"car_distance_perpendicular":2.5,"car_length":4.4,"car_width":1.8,"bus_distance_parallel":12,"bus_distance_diagonal":5,"bus_distance_perpendicular":4,"area_parking_place":12,"buffer_driveway":4,"buffer_bus_stop":15,"buffer_traffic_signals":0,"buffer_crossing_protected":3,"buffer_crossing_primary":4.5,"buffer_crossing_marked":2,"buffer_turning_circle":10,"buffer_turning_loop":15,"appearance_version":"appearance-v1"}'
if [[ -n "$RESUME" ]]; then
 GEN="$RESUME"; [[ "$GEN" =~ ^[0-9a-f]{16,64}$ ]] || { echo "Invalid resume id." >&2; exit 2; }
 STAGE_DIR="$PARKING_DIR/$GEN"; MANIFEST="$STAGE_DIR/manifest.json"; [[ -f "$MANIFEST" ]] || { echo "Resume manifest missing." >&2; exit 1; }
 if [[ -z "$BBOX" ]]; then
   BBOX=$(python3 - "$MANIFEST" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding='utf8')).get('extent','full'))
PY
)
   [[ "$BBOX" == full ]] && BBOX=""
 fi
 python3 - "$MANIFEST" "$SHA" "$CODE_SHA" "$BBOX" "$PARAMS" <<'PY'
import json,sys
m=json.load(open(sys.argv[1],encoding='utf8'))
if m.get('status') in ('validated','published'): raise SystemExit('generation is already complete; use --publish or create a new generation')
if m.get('pbf_sha256') != sys.argv[2] or m.get('implementation_sha256') != sys.argv[3]: raise SystemExit('resume input/code hash does not match manifest')
if (m.get('extent') or 'full') != (sys.argv[4] or 'full'): raise SystemExit('resume extent does not match manifest')
if m.get('parameters') != json.loads(sys.argv[5]): raise SystemExit('resume parameters do not match manifest')
PY
else
 GEN=$(printf '%s' "$SHA|$CODE_SHA|$PARAMS|${BBOX:-full}" | shasum -a 256 | awk '{print substr($1,1,24)}')
 STAGE_DIR="$PARKING_DIR/$GEN"; MANIFEST="$STAGE_DIR/manifest.json"
 if [[ -e "$MANIFEST" ]]; then
   echo "Generation $GEN already exists; use --resume $GEN to continue it." >&2
   exit 1
 fi
 mkdir -p "$STAGE_DIR"
 python3 - "$MANIFEST" "$SHA" "$HEADER_TS" "$UPSTREAM_SHA" "$CODE_SHA" "$GEN" "$BBOX" "$PARAMS" <<'PY'
import json,sys,time
p,sha,ts,ush,code,g,bbox,params=sys.argv[1:]
m={'generation_id':g,'status':'running','pbf_sha256':sha,'pbf_header_timestamp':ts,'extent':bbox or 'full','upstream_revision':'96debe3635ff7c63800d968270db7ae3b21c48e0','upstream_sha256':ush,'implementation_sha256':code,'parameters':json.loads(params),'tool_versions':{},'stage_counts':{},'stage_timings':{},'started_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
open(p,'w',encoding='utf8').write(json.dumps(m,indent=2,sort_keys=True)+'\n')
PY
fi
SCHEMA="parking_$GEN"; mkdir -p "$STAGE_DIR"
python3 - "$MANIFEST" <<'PY'
import json,sys,subprocess,shutil
p=sys.argv[1]; m=json.load(open(p,encoding='utf8')); versions={}
for name in ('osm2pgsql','psql','osmium'):
 exe=shutil.which(name)
 if exe:
  try: versions[name]=subprocess.check_output([exe,'--version'],text=True,stderr=subprocess.STDOUT).strip().splitlines()[0]
  except Exception: versions[name]='unknown'
m['tool_versions']=versions; open(p,'w',encoding='utf8').write(json.dumps(m,indent=2,sort_keys=True)+'\n')
PY
LOCK="$PARKING_DIR/.build.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "Another parking build is in progress (pid $lock_pid)." >&2; exit 1
  fi
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || { echo "Cannot recover stale build lock: $LOCK" >&2; exit 1; }
  mkdir "$LOCK"
fi
printf '%s\n' "$$" > "$LOCK/pid"
BUILD_FINISHED=0
cleanup_build_lock() {
  if [[ "$BUILD_FINISHED" -ne 1 && -f "$MANIFEST" ]]; then
    python3 - "$MANIFEST" <<'PY'
import json,sys,time
p=sys.argv[1]
try: m=json.load(open(p,encoding='utf8'))
except Exception: m={}
if m.get('status') == 'running':
    m['status']='failed'; m['failed_at']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
    open(p,'w',encoding='utf8').write(json.dumps(m,indent=2,sort_keys=True)+'\n')
PY
  fi
  rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup_build_lock EXIT
PSQL=(psql --no-psqlrc -X -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -v ON_ERROR_STOP=1 -v "schema=$SCHEMA")
if [[ -z "$RESUME" ]]; then
 "${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE SCHEMA IF NOT EXISTS \"$SCHEMA\";"
 osm2pgsql -c --slim -H "$DB_HOST" -P "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" --schema "$SCHEMA" -O flex -S "$IMPORT_LUA" "$DATA"
fi
for stage in "${STAGES[@]}"; do
 case "$stage" in
  parking_01_normalize.sql) COUNT_TABLE=normalized_lanes;;
  parking_02_lanes.sql) COUNT_TABLE=parking_lane_fragments;;
  parking_03_obstructions.sql) COUNT_TABLE=parking_lane_cut2;;
  parking_04_separate.sql) COUNT_TABLE=parking_lane_final;;
  parking_05_points.sql) COUNT_TABLE=parking_points;;
 esac
 if [[ -n "$RESUME" ]]; then
   completed=$(${PSQL[@]} -Atc "SELECT CASE WHEN to_regclass('$SCHEMA.stage_runs') IS NOT NULL THEN EXISTS (SELECT 1 FROM $SCHEMA.stage_runs WHERE stage='$stage' AND status='complete') ELSE false END" 2>/dev/null || echo false)
   if [[ "$completed" == "t" ]]; then
     echo "Skipping completed stage $stage" >&2
     continue
   fi
 fi
 start=$(date +%s)
 if ! "${PSQL[@]}" -1 -c "SET max_parallel_workers_per_gather=0; SET work_mem='64MB'; SET statement_timeout='30min';" -f "$SQL_DIR/$stage"; then
   python3 - "$MANIFEST" "$stage" <<'PY'
import json,sys,time
p,stage=sys.argv[1:]
try: m=json.load(open(p,encoding='utf8'))
except Exception: raise SystemExit(1)
m['status']='failed'; m['failed_stage']=stage; m['failed_at']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
open(p,'w',encoding='utf8').write(json.dumps(m,indent=2,sort_keys=True)+'\n')
PY
   exit 1
 fi
 elapsed=$(( $(date +%s) - start ))
 count=$(${PSQL[@]} -Atc "SELECT count(*) FROM $SCHEMA.$COUNT_TABLE")
 "${PSQL[@]}" -c "INSERT INTO $SCHEMA.stage_runs(stage,status,started_at,completed_at,row_count,elapsed_seconds) VALUES ('$stage','complete',now()-make_interval(secs=>$elapsed),now(),$count,$elapsed) ON CONFLICT(stage) DO UPDATE SET status='complete',completed_at=excluded.completed_at,row_count=excluded.row_count,elapsed_seconds=excluded.elapsed_seconds"
 python3 - "$MANIFEST" "$stage" "$elapsed" "$count" <<'PY'
import json,sys
p,stage,elapsed,count=sys.argv[1:]; m=json.load(open(p,encoding='utf8')); m.setdefault('stage_timings',{})[stage]=int(elapsed); m.setdefault('stage_counts',{})[stage]=int(count); open(p,'w',encoding='utf8').write(json.dumps(m,indent=2,sort_keys=True)+'\n')
PY
done
EXPORT_ARGS=(--schema "$SCHEMA" --output "$STAGE_DIR/street_parking_points.geojson")
[[ -z "$BBOX" ]] || EXPORT_ARGS+=(--bbox "$BBOX")
python3 "$ROOT/data/parking_export.py" "${EXPORT_ARGS[@]}" > "$STAGE_DIR/export.json"
# Nominal capacity is summed once per parking_lines row (a line's capacity is
# duplicated onto every one of its generated points, so summing the exported
# points' 'capacity' property overcounts by roughly capacity^2 per line).
CAPACITY_TOTAL=$("${PSQL[@]}" -Atc "SELECT COALESCE(sum(capacity),0) FROM $SCHEMA.parking_lines")
SOURCE_COUNTS=$("${PSQL[@]}" -Atc "SELECT jsonb_build_object('ways',(SELECT count(*) FROM $SCHEMA.raw_ways),'nodes',(SELECT count(*) FROM $SCHEMA.raw_nodes),'relations',(SELECT count(*) FROM $SCHEMA.raw_relations))")
DIAGNOSTIC_COUNTS=$("${PSQL[@]}" -Atc "SELECT COALESCE(jsonb_object_agg(code,n),'{}'::jsonb) FROM (SELECT code,count(*) n FROM $SCHEMA.diagnostics GROUP BY code ORDER BY code) q")
python3 - "$STAGE_DIR/street_parking_points.geojson" "$STAGE_DIR/manifest.json" "$ROOT" "$CAPACITY_TOTAL" "$SOURCE_COUNTS" "$DIAGNOSTIC_COUNTS" <<'PY'
import glob,hashlib,json,os,sys,time
f,mf,root,capacity_total,source_counts,diagnostic_counts=sys.argv[1:]; d=json.load(open(f,encoding='utf8')); assets={os.path.basename(x) for x in glob.glob(os.path.join(root,'style/symbols/cars/*.svg'))}; missing=[]
for x in d['features']:
 p=x['properties']; n=p['@modell']+'_'+p['@colour']+'.svg'
 if n not in assets: missing.append(n)
if missing: raise SystemExit('missing car assets: '+','.join(sorted(set(missing))))
m=json.load(open(mf,encoding='utf8')); m['status']='validated'; m['output_count']=len(d['features']); m['capacity_total']=int(capacity_total); m['source_counts']=json.loads(source_counts); m['diagnostic_counts']=json.loads(diagnostic_counts); m['output_sha256']=hashlib.sha256(open(f,'rb').read()).hexdigest(); m['completed_at']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()); open(mf,'w',encoding='utf8').write(json.dumps(m,indent=2,sort_keys=True)+'\n')
PY
BUILD_FINISHED=1
echo "$GEN"
