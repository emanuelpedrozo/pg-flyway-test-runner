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
                "type": "Point",
                "coordinates": [
                    -52.22733,
                    -7.035518
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
                            -52.230163,
                            -7.034634
                        ],
                        [
                            -52.22644,
                            -7.03424
                        ],
                        [
                            -52.224659,
                            -7.035455
                        ],
                        [
                            -52.228028,
                            -7.037702
                        ],
                        [
                            -52.230817,
                            -7.036797
                        ],
                        [
                            -52.230163,
                            -7.034634
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
                "type": "Polygon",
                "coordinates": [
                    [
                        [
                            -52.229744,
                            -7.035156
                        ],
                        [
                            -52.229809,
                            -7.034901
                        ],
                        [
                            -52.226697,
                            -7.03456
                        ],
                        [
                            -52.226697,
                            -7.034837
                        ],
                        [
                            -52.229744,
                            -7.035156
                        ]
                    ]
                ]
            },
            "properties": {
                "layerCode": "RIVER",
                "rules": {
                    "required": false,
                    "maxInstances": 1,
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
                        "style": {
                            "color": "#FF8C00",
                            "weight": 3,
                            "opacity": 0.8,
                            "fillColor": "#FF8C00",
                            "fillOpacity": 0.25
                        }
                    }
                },
                "restored": true,
                "color": "#1E90FF",
                "fillColor": "#1E90FF",
                "weight": 2,
                "fillOpacity": 0.2,
                "tipo": "RIVER"
            }
        },
        {
            "type": "Feature",
            "geometry": {
                "type": "Polygon",
                "coordinates": [
                    [
                        [
                            -52.226287,
                            -7.03502
                        ],
                        [
                            -52.226334,
                            -7.035101
                        ],
                        [
                            -52.226397,
                            -7.035171
                        ],
                        [
                            -52.226473,
                            -7.035226
                        ],
                        [
                            -52.226558,
                            -7.035264
                        ],
                        [
                            -52.22665,
                            -7.035283
                        ],
                        [
                            -52.229697,
                            -7.035602
                        ],
                        [
                            -52.229789,
                            -7.035603
                        ],
                        [
                            -52.229878,
                            -7.035584
                        ],
                        [
                            -52.229962,
                            -7.035548
                        ],
                        [
                            -52.230037,
                            -7.035496
                        ],
                        [
                            -52.2301,
                            -7.03543
                        ],
                        [
                            -52.230148,
                            -7.035352
                        ],
                        [
                            -52.230179,
                            -7.035267
                        ],
                        [
                            -52.230244,
                            -7.035012
                        ],
                        [
                            -52.230255,
                            -7.03494
                        ],
                        [
                            -52.230163,
                            -7.034634
                        ],
                        [
                            -52.22644,
                            -7.03424
                        ],
                        [
                            -52.226314,
                            -7.034326
                        ],
                        [
                            -52.226279,
                            -7.034396
                        ],
                        [
                            -52.226256,
                            -7.034477
                        ],
                        [
                            -52.226248,
                            -7.03456
                        ],
                        [
                            -52.226248,
                            -7.034837
                        ],
                        [
                            -52.226258,
                            -7.03493
                        ],
                        [
                            -52.226287,
                            -7.03502
                        ]
                    ],
                    [
                        [
                            -52.229809,
                            -7.034901
                        ],
                        [
                            -52.229744,
                            -7.035156
                        ],
                        [
                            -52.226697,
                            -7.034837
                        ],
                        [
                            -52.226697,
                            -7.03456
                        ],
                        [
                            -52.229809,
                            -7.034901
                        ]
                    ]
                ]
            },
            "properties": {
                "layerCode": "PPA_WIDER_THAN_10M",
                "style": {
                    "color": "#FF8C00",
                    "weight": 3,
                    "opacity": 0.8,
                    "fillColor": "#FF8C00",
                    "fillOpacity": 0.25
                },
                "tipo": "PPA_WIDER_THAN_10M"
            }
        },
        {
            "type": "Feature",
            "properties": {
                "color": "#CFE2F3",
                "fillColor": "#CFE2F3",
                "weight": 2,
                "fillOpacity": 0.2,
                "icon": "fas fa-thumbtack",
                "radius": 8,
                "opacity": 0.8,
                "pane": "overlayPane",
                "_dashArray": null,
                "layerCode": "RIVER_UP_TO_10M",
                "rules": {
                    "required": false,
                    "maxInstances": 1,
                    "overlap": true,
                    "geometryType": "LineString",
                    "lineMaxLength": 10,
                    "geometricUnit": "m",
                    "style": {
                        "color": "#CFE2F3",
                        "fillColor": "#CFE2F3",
                        "weight": 2,
                        "fillOpacity": 0.2
                    },
                    "buffer": {
                        "layerCode": "PPA_UP_TO_10M",
                        "style": {
                            "color": "#FF8C00",
                            "weight": 3,
                            "opacity": 0.8,
                            "fillColor": "#FF8C00",
                            "fillOpacity": 0.25
                        }
                    }
                },
                "tipo": "RIVER_UP_TO_10M"
            },
            "geometry": {
                "type": "LineString",
                "coordinates": [
                    [
                        -52.229573,
                        -7.036499
                    ],
                    [
                        -52.227234,
                        -7.03635
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
s5 AS (SELECT geometry_bases.ppa_up_to_10m(fc, 30, 2000)      AS fc FROM s4),
s6 AS (SELECT geometry_bases.ppa_wider_than_10m(fc) AS fc FROM s5),
s7 AS (SELECT geometry_bases.legal_reserve(fc)      AS fc FROM s6)
SELECT jsonb_pretty(fc) FROM s7
\g /tests_output/test_paa_rio_result.json