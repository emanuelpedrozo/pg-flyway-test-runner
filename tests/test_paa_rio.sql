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
{
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "geometry": {
            "type": "MultiPolygon",
            "coordinates": [
              [
                [
                  [
                    -41.626402,
                    -11.506661
                  ],
                  [
                    -41.629299,
                    -11.510821
                  ],
                  [
                    -41.627239,
                    -11.512818
                  ],
                  [
                    -41.626037,
                    -11.513196
                  ],
                  [
                    -41.623333,
                    -11.514162
                  ],
                  [
                    -41.618591,
                    -11.515885
                  ],
                  [
                    -41.616402,
                    -11.509035
                  ],
                  [
                    -41.619621,
                    -11.508762
                  ],
                  [
                    -41.621939,
                    -11.508111
                  ],
                  [
                    -41.623827,
                    -11.507543
                  ],
                  [
                    -41.625544,
                    -11.506997
                  ],
                  [
                    -41.626402,
                    -11.506661
                  ]
                ]
              ]
            ]
          },
          "properties": {
            "layerCode": "RURAL_PROPERTY",
            "rules": {
              "overlap": true,
              "geometryType": "Polygon",
              "geometricUnit": "ha",
              "maxInstances": 1,
              "required": true,
              "style": {
                "color": "#FFFF00",
                "fillColor": "#FFD700",
                "weight": 2,
                "fillOpacity": 0.2
              }
            },
            "restored": true,
            "color": "#FFFF00",
            "fillColor": "#FFD700",
            "weight": 2,
            "fillOpacity": 0.2,
            "tipo": "RURAL_PROPERTY"
          }
        },
        {
          "type": "Feature",
          "geometry": {
            "type": "Point",
            "coordinates": [
              -41.619299,
              -11.514577
            ]
          },
          "properties": {
            "layerCode": "PROPERTY_HEADQUARTERS",
            "rules": {
              "overlap": true,
              "geometryType": "Point",
              "geometricUnit": "ha",
              "maxInstances": 1,
              "required": true,
              "style": {
                "icon": "fas fa-thumbtack",
                "color": "#FFD700",
                "radius": 8,
                "weight": 2,
                "opacity": 0.8,
                "fillColor": "#FFD700",
                "fillOpacity": 0.6
              }
            },
            "restored": true,
            "icon": "fas fa-thumbtack",
            "color": "#FFD700",
            "radius": 8,
            "weight": 2,
            "opacity": 0.8,
            "fillColor": "#FFD700",
            "fillOpacity": 0.6,
            "tipo": "PROPERTY_HEADQUARTERS"
          }
        },
        {
          "type": "Feature",
          "geometry": {
            "type": "Polygon",
            "coordinates": [
              [
                [
                  -41.625265,
                  -11.508168
                ],
                [
                  -41.623033,
                  -11.508693
                ],
                [
                  -41.623288,
                  -11.509452
                ],
                [
                  -41.625479,
                  -11.510185
                ],
                [
                  -41.623906,
                  -11.511292
                ],
                [
                  -41.624063,
                  -11.511761
                ],
                [
                  -41.626896,
                  -11.5109
                ],
                [
                  -41.625265,
                  -11.508168
                ]
              ]
            ]
          },
          "properties": {
            "layerCode": "CONSOLIDATED_AREA",
            "rules": {
              "required": false,
              "overlap": false,
              "geometryType": "Polygon",
              "geometricUnit": "ha",
              "style": {
                "color": "#808080",
                "fillColor": "#808080",
                "weight": 3,
                "fillOpacity": 0.5
              }
            },
            "restored": true,
            "color": "#808080",
            "fillColor": "#808080",
            "weight": 3,
            "fillOpacity": 0.5,
            "tipo": "CONSOLIDATED_AREA"
          }
        },
        {
          "type": "Feature",
          "geometry": {
            "type": "Polygon",
            "coordinates": [
              [
                [
                  -41.625479,
                  -11.510185
                ],
                [
                  -41.62196,
                  -11.509008
                ],
                [
                  -41.623269,
                  -11.51174
                ],
                [
                  -41.625479,
                  -11.510185
                ]
              ]
            ]
          },
          "properties": {
            "layerCode": "REMAINING_NATIVE_VEGETATION",
            "rules": {
              "required": false,
              "overlap": false,
              "geometryType": "Polygon",
              "geometricUnit": "ha",
              "style": {
                "color": "#008000",
                "fillColor": "#008000",
                "weight": 3,
                "fillOpacity": 0.5
              }
            },
            "restored": true,
            "color": "#008000",
            "fillColor": "#008000",
            "weight": 3,
            "fillOpacity": 0.5,
            "tipo": "REMAINING_NATIVE_VEGETATION"
          }
        },
        {
          "type": "Feature",
          "geometry": {
            "type": "Polygon",
            "coordinates": [
              [
                [
                  -41.624986,
                  -11.509379
                ],
                [
                  -41.623591,
                  -11.510335
                ],
                [
                  -41.625104,
                  -11.511123
                ],
                [
                  -41.624986,
                  -11.509379
                ]
              ]
            ]
          },
          "properties": {
            "layerCode": "LEGAL_RESERVE",
            "rules": {
              "required": false,
              "overlap": false,
              "geometryType": "Polygon",
              "geometricUnit": "ha",
              "style": {
                "color": "#2e7d32",
                "fillColor": "#2e7d32",
                "weight": 3,
                "fillOpacity": 0.5
              }
            },
            "restored": true,
            "color": "#2e7d32",
            "fillColor": "#2e7d32",
            "weight": 3,
            "fillOpacity": 0.5,
            "tipo": "LEGAL_RESERVE"
          }
        },
        {
          "type": "Feature",
          "properties": {
            "color": "#1E90FF",
            "fillColor": "#1E90FF",
            "weight": 2,
            "fillOpacity": 0.2,
            "pane": "overlayPane",
            "_dashArray": null,
            "layerCode": "RIVER",
            "rules": {
              "required": false,
              "overlap": true,
              "geometryType": "Polygon",
              "geometricUnit": "ha",
              "style": {
                "color": "#1E90FF",
                "fillColor": "#1E90FF",
                "weight": 2,
                "fillOpacity": 0.2
              },
              "buffer": {
                "layerCode": "PPA_WIDER_THAN_10M",
                "displayName": "PPA River",
                "displayNameKey": "layers.vectorization.ppaRiver.displayName",
                "style": {
                  "color": "#FF8C00",
                  "weight": 3,
                  "opacity": 0.8,
                  "fillColor": "#FF8C00",
                  "fillOpacity": 0.25
                }
              }
            },
            "tipo": "RIVER"
          },
          "geometry": {
            "type": "Polygon",
            "coordinates": [
              [
                [
                  -41.626234,
                  -11.513714
                ],
                [
                  -41.622704,
                  -11.513283
                ],
                [
                  -41.619743,
                  -11.51605
                ],
                [
                  -41.620301,
                  -11.516155
                ],
                [
                  -41.622693,
                  -11.513925
                ],
                [
                  -41.626148,
                  -11.513977
                ],
                [
                  -41.626234,
                  -11.513714
                ]
              ]
            ]
          }
        }
      ]
    }
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