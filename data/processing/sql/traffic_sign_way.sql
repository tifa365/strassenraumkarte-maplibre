-- Derive traffic sign locations and directions from traffic sign centerline tags

DROP TABLE IF EXISTS traffic_sign_centerline_segments;

CREATE TABLE traffic_sign_centerline_segments AS
SELECT country_code, sign_main, sign_list, oneway, "oneway:bicycle", ST_LineMerge(ST_Union(geom)) AS geom
FROM traffic_sign_way
GROUP BY country_code, sign_main, sign_list, oneway, "oneway:bicycle";

-- TODO: derive layer for each traffic sign from closest highway line