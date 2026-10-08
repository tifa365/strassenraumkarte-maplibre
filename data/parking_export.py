#!/usr/bin/env python3
"""Stream a validated parking generation to the map's GeoJSON contract."""
import argparse, hashlib, json, math, os, subprocess, sys
from pathlib import Path

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--schema", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--bbox", help="xmin,ymin,xmax,ymax in WGS84")
    a = p.parse_args()
    if not a.schema.startswith("parking_") or not a.schema[8:] or not all(c in "0123456789abcdef" for c in a.schema[8:]):
        p.error("invalid generation schema")
    where = ""
    if a.bbox:
        vals = a.bbox.split(",")
        if len(vals) != 4: p.error("bbox must have four coordinates")
        try: nums = [float(x) for x in vals]
        except ValueError: p.error("bbox coordinates must be numbers")
        if not all(math.isfinite(x) for x in nums) or nums[0] >= nums[2] or nums[1] >= nums[3]:
            p.error("bbox must be a finite xmin,ymin,xmax,ymax extent")
        if not (-180 <= nums[0] <= 180 and -180 <= nums[2] <= 180 and -90 <= nums[1] <= 90 and -90 <= nums[3] <= 90):
            p.error("bbox must be in WGS84 longitude/latitude")
        where = (" WHERE ST_Intersects(geom, ST_Transform(ST_MakeEnvelope(%s,%s,%s,%s,4326),3857))"
                 % tuple(nums))
    q = f"""COPY (
      SELECT jsonb_build_object('type','Feature',
        'geometry',ST_AsGeoJSON(ST_Transform(geom,4326),9,0)::jsonb,
        'properties',jsonb_build_object(
          'space_id',space_id,'osm_type',osm_type,'osm_id',osm_id,'source_key',source_key,
          'side',side,'parking',parking,'orientation',orientation,'angle',angle,
          'highway',highway,'highway:oneway',highway_oneway,
          'vehicle_designated',vehicle_designated,'vehicle_excluded',vehicle_excluded,'condition_class',condition_class,
          'markings',markings,'markings:type',markings_type,'width',width_m,
          '@modell',model,'@colour',colour,'source_type',source_type,
          'capacity',capacity,'point_index',point_index))::text
      FROM {a.schema}.parking_points{where} ORDER BY space_id
    ) TO STDOUT"""
    env = os.environ.copy()
    db = ["psql", "-U", env.get("DB_USER","postgres"), "-h", env.get("DB_HOST","localhost"),
          "-p", env.get("DB_PORT","5433"), "-d", env.get("DB_NAME","strassenraumkarte"), "-Atq", "-c", q]
    out = Path(a.output); out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name("." + out.name + ".tmp")
    count = 0; digest = hashlib.sha256(); ids = set()
    try:
        with subprocess.Popen(db, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc, tmp.open("w", encoding="utf-8") as fh:
            fh.write('{"type":"FeatureCollection","features":[\n')
            first = True
            assert proc.stdout is not None
            for line in proc.stdout:
                line = line.rstrip("\n")
                if not line: continue
                # Validate each feature before it can become the published file.
                feature = json.loads(line)
                geometry = feature.get("geometry") or {}
                if geometry.get("type") != "Point": raise RuntimeError("non-point parking geometry")
                coordinates = geometry.get("coordinates")
                if not isinstance(coordinates, list) or len(coordinates) != 2 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in coordinates):
                    raise RuntimeError("parking geometry has invalid coordinates")
                if not (-180 <= coordinates[0] <= 180 and -90 <= coordinates[1] <= 90):
                    raise RuntimeError("parking geometry is outside WGS84 bounds")
                props = feature.get("properties", {})
                required = {"space_id","osm_type","osm_id","source_key","side","orientation","angle",
                            "highway:oneway","vehicle_designated","vehicle_excluded","condition_class",
                            "markings","markings:type","width","@modell","@colour"}
                missing = required - props.keys()
                if missing: raise RuntimeError("missing parking fields: " + ",".join(sorted(missing)))
                space_id = props["space_id"]
                if not isinstance(space_id, str) or not space_id or space_id in ids:
                    raise RuntimeError("parking space_id is empty or duplicated")
                ids.add(space_id)
                if props["orientation"] not in {"parallel", "diagonal", "perpendicular"}:
                    raise RuntimeError("invalid parking orientation")
                if not isinstance(props["angle"], (int, float)) or not math.isfinite(props["angle"]):
                    raise RuntimeError("invalid parking angle")
                if not isinstance(props["@modell"], str) or not isinstance(props["@colour"], str):
                    raise RuntimeError("invalid car appearance fields")
                if not first: fh.write(",\n")
                first = False; encoded = json.dumps(feature, ensure_ascii=False, separators=(",", ":"))
                fh.write(encoded); digest.update((encoded+"\n").encode()); count += 1
            stderr = proc.stderr.read() if proc.stderr else ""
            code = proc.wait()
            if code: raise RuntimeError(stderr.strip() or f"psql exited {code}")
            fh.write('\n]}\n'); fh.flush(); os.fsync(fh.fileno())
        tmp.replace(out)
    finally:
        if tmp.exists(): tmp.unlink()
    print(json.dumps({"count":count,"sha256":digest.hexdigest(),"output":str(out)}))

if __name__ == "__main__":
    try: main()
    except Exception as exc:
        print(f"parking export failed: {exc}", file=sys.stderr); raise SystemExit(1)
