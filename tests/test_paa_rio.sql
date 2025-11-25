\set ON_ERROR_STOP on
\pset pager off
\t on
\a on
\pset footer off
\o /dev/null

DROP TABLE IF EXISTS tmp_fc1;
CREATE TEMP TABLE tmp_fc1 (j jsonb);

INSERT INTO tmp_fc1(j) VALUES (
$json$
{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-49.132318,-9.739449]},"properties":{"layerCode":"PROPERTY_HEADQUARTERS","rules":{"overlap":true,"geometryType":"Point","geometricUnit":"ha","maxInstances":1,"required":true,"style":{"icon":"fas fa-thumbtack","color":"#FFD700","radius":8,"weight":2,"opacity":0.8,"fillColor":"#FFD700","fillOpacity":0.6}},"restored":true,"icon":"fas fa-thumbtack","color":"#FFD700","radius":8,"weight":2,"opacity":0.8,"fillColor":"#FFD700","fillOpacity":0.6,"tipo":"PROPERTY_HEADQUARTERS"}},{"type":"Feature","geometry":{"type":"MultiPolygon","coordinates":[[[[-49.143391,-9.738856],[-49.143927,-9.743788],[-49.130044,-9.743618],[-49.131782,-9.73875],[-49.143391,-9.738856]]]]},"properties":{"layerCode":"RURAL_PROPERTY","rules":{"overlap":true,"geometryType":"Polygon","geometricUnit":"ha","maxInstances":1,"required":true,"style":{"color":"#FFFF00","fillColor":"#FFD700","weight":2,"fillOpacity":0.2}},"restored":true,"color":"#FFFF00","fillColor":"#FFD700","weight":2,"fillOpacity":0.2,"tipo":"RURAL_PROPERTY"}},{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-49.134593,-9.740105],[-49.133542,-9.742348],[-49.140601,-9.742243],[-49.141331,-9.739872],[-49.134593,-9.740105]]]},"properties":{"layerCode":"CONSOLIDATED_AREA","rules":{"required":false,"overlap":false,"geometryType":"Polygon","geometricUnit":"ha","style":{"color":"#808080","fillColor":"#808080","weight":3,"fillOpacity":0.5}},"restored":true,"color":"#808080","fillColor":"#808080","weight":3,"fillOpacity":0.5,"tipo":"CONSOLIDATED_AREA"}},{"type":"Feature","properties":{"color":"#008000","fillColor":"#008000","weight":3,"fillOpacity":0.5,"icon":"fas fa-thumbtack","radius":8,"opacity":0.8,"pane":"overlayPane","_dashArray":null,"layerCode":"REMAINING_NATIVE_VEGETATION","rules":{"required":false,"overlap":false,"geometryType":"Polygon","geometricUnit":"ha","style":{"color":"#008000","fillColor":"#008000","weight":3,"fillOpacity":0.5}},"tipo":"REMAINING_NATIVE_VEGETATION"},"geometry":{"type":"Polygon","coordinates":[[[-49.139013,-9.739576],[-49.138724,-9.742793],[-49.136932,-9.742708],[-49.137597,-9.739449],[-49.139013,-9.739576]]]}}]}
$json$::jsonb
);

WITH
s0 AS (SELECT j AS fc FROM tmp_fc1),
s1 AS (SELECT geometry_bases.rural_property(fc)     AS fc FROM s0),
s2 AS (SELECT geometry_bases.headquarter(fc)        AS fc FROM s1),
s3 AS (SELECT geometry_bases.native_vegetation(fc)  AS fc FROM s2),
s4 AS (SELECT geometry_bases.consolidated_area(fc)  AS fc FROM s3),
s5 AS (SELECT geometry_bases.rivers_up_to_10m(fc)  AS fc FROM s4),
s6 AS (SELECT geometry_bases.rivers_wider_than_10m(fc)  AS fc FROM s5),
s7 AS (SELECT geometry_bases.legal_reserve(fc)      AS fc FROM s6),
s8 AS (SELECT geometry_bases.ppa_up_to_10m(fc, 30, 2000)      AS fc FROM s7),
s9 AS (SELECT geometry_bases.ppa_wider_than_10m(fc) AS fc FROM s8)
SELECT jsonb_pretty(fc) FROM s9;
\g /tests_output/test_paa_rio_result.json