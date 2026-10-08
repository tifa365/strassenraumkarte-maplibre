#!/usr/bin/env python3
"""Small contract checks for the generated parking layer (no QGIS required)."""
import argparse, json, hashlib, math, pathlib

def side(tags, side, key=""):
    return tags.get(f"parking:{side}{(':'+key) if key else ''}", tags.get(f"parking:both{(':'+key) if key else ''}"))

def main():
    p=argparse.ArgumentParser(); p.add_argument("--geojson",default="data/parking/street_parking_points_processed.geojson"); p.add_argument("--manifest"); a=p.parse_args()
    cases=json.load(open("tests/fixtures/parking_tag_cases.json",encoding="utf8"))
    for c in cases:
        assert side(c["tags"],"left")==c["expected"]["left"] and side(c["tags"],"right")==c["expected"]["right"], c["name"]
        if "left_orientation" in c["expected"]: assert side(c["tags"],"left","orientation")==c["expected"]["left_orientation"]
        if "right_orientation" in c["expected"]: assert side(c["tags"],"right","orientation")==c["expected"]["right_orientation"]
    d=json.load(open(a.geojson,encoding="utf8")); assert d["type"]=="FeatureCollection"
    required={"space_id","osm_type","osm_id","source_key","side","orientation","angle","highway:oneway","vehicle_designated","vehicle_excluded","condition_class","markings","markings:type","width","@modell","@colour"}
    assert all(required <= set(x["properties"]) for x in d["features"])
    assets={x.name for x in pathlib.Path("style/symbols/cars").glob("*.svg")}
    assert all(x["geometry"]["type"]=="Point" and x["properties"]["orientation"] in {"parallel","diagonal","perpendicular"} for x in d["features"])
    assert all(len(x["geometry"]["coordinates"])==2 and all(math.isfinite(float(v)) for v in x["geometry"]["coordinates"]) for x in d["features"])
    assert all(x["properties"]["@modell"]+"_"+x["properties"]["@colour"]+".svg" in assets for x in d["features"])
    assert all(isinstance(x["properties"]["capacity"],int) and x["properties"]["capacity"] > 0 for x in d["features"])
    ids=[x["properties"]["space_id"] for x in d["features"]]; assert len(ids)==len(set(ids))
    if a.manifest:
        m=json.load(open(a.manifest,encoding="utf8")); assert m.get("status") in {"validated","published"}
        assert m.get("output_count")==len(ids)
        assert m.get("output_sha256")==hashlib.sha256(pathlib.Path(a.geojson).read_bytes()).hexdigest()
    print(f"PASS: {len(ids)} parking points satisfy the source/tag/geometry contract; sha256={hashlib.sha256(pathlib.Path(a.geojson).read_bytes()).hexdigest()}")

if __name__ == "__main__": main()
