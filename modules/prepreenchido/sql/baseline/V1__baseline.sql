-- Baseline inicial do módulo prepreenchido

CREATE SCHEMA IF NOT EXISTS geometry_bases;

-- Retorna EPSG UTM da zona baseada no centroide da geometria (WGS84/SIRGAS).
CREATE OR REPLACE FUNCTION geometry_bases.utmzone(p_geom geometry)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  lon double precision;
  lat double precision;
  zone integer;
BEGIN
  IF p_geom IS NULL OR ST_IsEmpty(p_geom) THEN
    RETURN NULL;
  END IF;

  lon := ST_X(ST_Transform(ST_Centroid(p_geom), 4326));
  lat := ST_Y(ST_Transform(ST_Centroid(p_geom), 4326));
  zone := floor((lon + 180.0) / 6.0)::integer + 1;

  IF lat >= 0 THEN
    RETURN 32600 + zone; -- WGS84 / UTM north
  END IF;

  RETURN 32700 + zone;   -- WGS84 / UTM south
END;
$function$;

-- DROP FUNCTION geometry_bases.f_add_area_ha_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_add_area_ha_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    j_in        jsonb := input_geojson_text::jsonb;
    feats_in    jsonb := COALESCE(j_in->'features','[]'::jsonb);
    feats_out   jsonb := '[]'::jsonb;

    feat        jsonb;
    geom_4674   public.geometry;
    geom_poly   public.geometry;
    area_ha     double precision;
BEGIN
    -- Sanidade: precisa ser FeatureCollection
    IF j_in->>'type' IS DISTINCT FROM 'FeatureCollection' THEN
        RETURN jsonb_build_object(
            'type','FeatureCollection',
            'features','[]'::jsonb,
            'message','GeoJSON inválido: esperado FeatureCollection'
        );
    END IF;

    -- Varre todas as features
    FOR feat IN
        SELECT value FROM jsonb_array_elements(feats_in)
    LOOP
        -- Se não há geometria, só mantém a feature
        IF NOT (feat ? 'geometry') OR feat->'geometry' IS NULL THEN
            feats_out := feats_out || feat;
            CONTINUE;
        END IF;

        -- 1) Entrada suposta em 4170 -> 4674
        BEGIN
            geom_4674 := ST_Transform(
                            ST_SetSRID(ST_GeomFromGeoJSON(feat->>'geometry'), 4170),
                            4674
                         );
        EXCEPTION WHEN others THEN
            -- Geometria inválida no JSON; mantém sem alterar
            feats_out := feats_out || feat;
            CONTINUE;
        END;

        -- 2) Normaliza para poligonais
        geom_poly := ST_Multi( ST_CollectionExtract( ST_MakeValid(geom_4674), 3) );

        -- 3) Calcula área em ha apenas para Polygon/MultiPolygon não vazios
        IF geom_poly IS NULL OR ST_IsEmpty(geom_poly) THEN
            area_ha := 0.0;
        ELSE
            -- área geodésica precisa (m²) / 10.000 -> ha
            area_ha := (ST_Area(geom_poly::geography) / 10000.0);
        END IF;

        -- 4) Monta feature de saída: preserva geometry original (CRS de entrada)
        feats_out := feats_out || jsonb_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(ST_Transform(geom_4674,4170))::jsonb,
            'properties', jsonb_strip_nulls(
                COALESCE(feat->'properties','{}'::jsonb)
                || jsonb_build_object('area_ha', ROUND(area_ha::numeric, 4)::double precision)
            )
        );
    END LOOP;

    -- 5) Retorna FeatureCollection com as mesmas features, acrescidas/atualizadas com area_ha
    RETURN j_in || jsonb_build_object('features', feats_out);
END;
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_app_escadinha_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_app_escadinha_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    input_geojson      jsonb := input_geojson_text::jsonb;
    features_all       jsonb := COALESCE(input_geojson->'features','[]'::jsonb);
    feature            jsonb;
    features_clipped   jsonb := '[]'::jsonb;

    -- Módulo fiscal e zona
    modulo_fiscal      numeric := NULL;
    mf                 numeric := NULL;  -- módulo fiscal com fallback
    zona_localizacao   text := 'RURAL';

    -- Auxiliares
    tipo_agua          text;
    id_agua            text;
    buffer_m           numeric;
    g_feat_4674        geometry := NULL;
    g_buf_4674         geometry := NULL;
    g_app_escadinha_4674 geometry := NULL;
    g_app_total_escadinha_4674 geometry := NULL;
    
    area_ha            numeric;
    utm                integer;
    tipo_raw           text;
    
    -- Buffer de correção topológica em graus (~0.1m)
    buffer_epsilon_deg numeric := 0.000001;

    -- Geometrias agregadas em 4674
    g_ai_4674           geometry := NULL;
    g_hidrica_4674      geometry := NULL;
    g_ac_4674           geometry := NULL;
    
    -- APPs agregadas
    g_rio_ate_10        geometry := NULL;
    g_rio_10_a_50       geometry := NULL;
    g_rio_50_a_200      geometry := NULL;
    g_rio_200_a_600     geometry := NULL;
    g_rio_acima_600     geometry := NULL;
    g_lago_natural      geometry := NULL;
    g_nascente_olho_dagua geometry := NULL;
    g_vereda            geometry := NULL;
    g_app_intersection  geometry := NULL;

    -- Saída
    features_out       jsonb := '[]'::jsonb;
BEGIN

    -------------------------------------------------------------------------
    -- 1) AGREGAÇÃO DE GEOMETRIAS BASE USANDO QUERIES
    -- Reason: Evita ST_Union incremental dentro de loops
    -- NOTA: Assume entrada já em 4674 (sem ST_Transform)
    -------------------------------------------------------------------------
    
    -- Extrai AREA_IMOVEL
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
           ), 3)),
           upper(COALESCE(f->'properties'->>'zona_localizacao', 'RURAL')),
           NULLIF(f->'properties'->>'modulo_fiscal', '')::numeric
    INTO g_ai_4674, zona_localizacao, modulo_fiscal
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_IMOVEL'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL
    LIMIT 1;

    IF g_ai_4674 IS NULL OR ST_IsEmpty(g_ai_4674) THEN
        RETURN input_geojson;
    END IF;

    -- CORREÇÃO V5: Adiciona fallback do módulo fiscal (como na V2)
    mf := COALESCE(modulo_fiscal, 999999);

    -- Agrega HIDRICO_IMOVEL
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_hidrica_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'HIDRICO_IMOVEL'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega AREA_CONSOLIDADA
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_ac_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_CONSOLIDADA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega todas as APPs de rios
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_rio_ate_10
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'APP_RIO_ATE_10'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_rio_10_a_50
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'APP_RIO_10_A_50'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_rio_50_a_200
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'APP_RIO_50_A_200'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_rio_200_a_600
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'APP_RIO_200_A_600'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_rio_acima_600
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'APP_RIO_ACIMA_600'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_lago_natural
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'APP_LAGO_NATURAL'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_nascente_olho_dagua
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'APP_NASCENTE_OLHO_DAGUA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_vereda
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'APP_VEREDA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Coleta features que não serão recalculadas
    SELECT COALESCE(jsonb_agg(f), '[]'::jsonb)
    INTO features_clipped
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) IN (
        'AREA_IMOVEL', 'HIDRICO_IMOVEL', 'AREA_CONSOLIDADA'
    )
    OR upper(COALESCE(f->'properties'->>'tipo', '')) NOT LIKE 'APP_%'
       AND upper(COALESCE(f->'properties'->>'tipo', '')) NOT IN (
           'RIO_ATE_10','RIO_10_A_50','RIO_50_A_200','RIO_200_A_600','RIO_ACIMA_600',
           'LAGO_NATURAL','NASCENTE_OLHO_DAGUA','VEREDA'
       );

    -- Inicializa vazias se NULL
    IF g_hidrica_4674 IS NULL THEN g_hidrica_4674 := ST_GeomFromText('MULTIPOLYGON EMPTY', 4674); END IF;
    IF g_ac_4674 IS NULL THEN g_ac_4674 := ST_GeomFromText('MULTIPOLYGON EMPTY', 4674); END IF;

    -------------------------------------------------------------------------
    -- 2) PROCESSA CORPOS D'ÁGUA E GERA APP_ESCADINHA
    -- Reason: Mantém loop apenas para corpos d'água (reduzido em tamanho)
    -------------------------------------------------------------------------
    FOR feature IN
        SELECT f FROM jsonb_array_elements(features_all) AS f
        WHERE upper(f->'properties'->>'tipo') IN (
            'RIO_ATE_10','RIO_10_A_50','RIO_50_A_200','RIO_200_A_600','RIO_ACIMA_600',
            'LAGO_NATURAL','NASCENTE_OLHO_DAGUA','VEREDA'
        )
          AND f ? 'geometry' AND f->'geometry' IS NOT NULL
    LOOP
        tipo_agua := upper(COALESCE(feature->'properties'->>'tipo', ''));
        id_agua := feature->'properties'->>'id';

        -- Geometria da feature (já em 4674)
        g_feat_4674 := ST_SetSRID(ST_GeomFromGeoJSON(feature->>'geometry'), 4674);
        
        IF g_feat_4674 IS NULL OR ST_IsEmpty(g_feat_4674) THEN
            CONTINUE;
        END IF;

        -- Determina zona UTM uma vez
        utm := geometry_bases.utmzone(ST_Centroid(g_feat_4674));

        -- CORREÇÃO V5: Usa mf (com fallback) ao invés de modulo_fiscal diretamente
        -- Calcula buffer "escadinha" baseado no tipo e módulo fiscal
        IF tipo_agua IN ('RIO_ATE_10', 'RIO_10_A_50') THEN
            buffer_m := CASE
                WHEN mf <= 1 THEN 5
                WHEN mf > 1 AND mf <= 2 THEN 8
                WHEN mf > 2 AND mf <= 4 THEN 15
                WHEN tipo_agua = 'RIO_ATE_10' AND mf > 4 AND mf <= 10 THEN 20
                WHEN tipo_agua = 'RIO_ATE_10' AND mf > 10 THEN 30
                WHEN tipo_agua = 'RIO_10_A_50' AND mf > 4 THEN 30
                ELSE 0
            END;

        ELSIF tipo_agua = 'RIO_50_A_200' THEN
            buffer_m := GREATEST(COALESCE((feature->'properties'->>'num_largura')::numeric / 2, 30), 30);

        ELSIF tipo_agua IN ('RIO_200_A_600', 'RIO_ACIMA_600') THEN
            buffer_m := 100;

        ELSIF tipo_agua = 'LAGO_NATURAL' THEN
            buffer_m := CASE
                WHEN mf <= 1 THEN 5
                WHEN mf > 1 AND mf <= 2 THEN 8
                WHEN mf > 2 AND mf <= 4 THEN 15
                ELSE 30
            END;

        ELSIF tipo_agua = 'NASCENTE_OLHO_DAGUA' THEN
            buffer_m := 15;

        ELSIF tipo_agua = 'VEREDA' THEN
            buffer_m := CASE
                WHEN mf <= 1 THEN 5
                WHEN mf > 1 AND mf <= 2 THEN 8
                WHEN mf > 2 AND mf <= 4 THEN 15
                ELSE 30
            END;
        ELSE
            CONTINUE;
        END IF;

        -- Seleciona APP agregada correspondente
        g_app_intersection := CASE tipo_agua
            WHEN 'RIO_ATE_10' THEN g_rio_ate_10
            WHEN 'RIO_10_A_50' THEN g_rio_10_a_50
            WHEN 'RIO_50_A_200' THEN g_rio_50_a_200
            WHEN 'RIO_200_A_600' THEN g_rio_200_a_600
            WHEN 'RIO_ACIMA_600' THEN g_rio_acima_600
            WHEN 'LAGO_NATURAL' THEN g_lago_natural
            WHEN 'NASCENTE_OLHO_DAGUA' THEN g_nascente_olho_dagua
            WHEN 'VEREDA' THEN g_vereda
            ELSE NULL
        END;

        -- CORREÇÃO V5: Adiciona verificação ST_IsEmpty (como na V2)
        IF g_app_intersection IS NULL OR ST_IsEmpty(g_app_intersection) THEN
            CONTINUE;
        END IF;

        -- Aplica buffer em UTM
        g_buf_4674 := ST_Transform(ST_Buffer(ST_Transform(g_feat_4674, utm), buffer_m), 4674);

        -- Verifica intersecção com Área Consolidada
        IF ST_Intersects(g_ac_4674, g_buf_4674) THEN
            -- Intersecta com AC
            g_app_escadinha_4674 := ST_Multi(ST_CollectionExtract(
                                      ST_MakeValid(ST_Intersection(g_ac_4674, g_buf_4674)), 3));

            -- CORREÇÃO V5: Adiciona verificação ST_IsEmpty antes de usar g_app_intersection
            -- Se não é nascente, intersecta com APP original também
            IF tipo_agua <> 'NASCENTE_OLHO_DAGUA' 
               AND g_app_intersection IS NOT NULL 
               AND NOT ST_IsEmpty(g_app_intersection) THEN
                g_app_escadinha_4674 := ST_Multi(ST_CollectionExtract(
                                          ST_MakeValid(ST_Intersection(g_app_intersection, g_app_escadinha_4674)), 3));
            END IF;

            -- Aplica buffer de correção topológica
            IF g_app_escadinha_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_escadinha_4674) THEN
                g_app_escadinha_4674 := ST_Buffer(ST_Buffer(g_app_escadinha_4674, buffer_epsilon_deg), -buffer_epsilon_deg);
                g_app_escadinha_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_app_escadinha_4674), 3));

                IF g_app_escadinha_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_escadinha_4674) THEN
                    -- Calcula área
                    area_ha := ST_Area(g_app_escadinha_4674::geography) / 10000.0;

                    -- Cria feature de saída (em 4674)
                    features_out := features_out || jsonb_build_object(
                        'type', 'Feature',
                        'geometry', ST_AsGeoJSON(ST_Transform(g_app_escadinha_4674, 4674))::jsonb,
                        'properties', jsonb_build_object(
                            'tipo', 'APP_ESCADINHA_' || tipo_agua,
                            'buffer_m', buffer_m,
                            'area_ha', round(area_ha, 4)
                        )
                    );

                    -- CORREÇÃO V5: Usa ST_Collect ao invés de ST_Union incremental (melhor performance)
                    -- Agrega para APP_ESCADINHA_TOTAL
                    g_app_total_escadinha_4674 := CASE
                        WHEN g_app_total_escadinha_4674 IS NULL THEN g_app_escadinha_4674
                        ELSE ST_Collect(g_app_total_escadinha_4674, g_app_escadinha_4674)
                    END;
                END IF;
            END IF;
        END IF;
    END LOOP;

    -------------------------------------------------------------------------
    -- 3) CRIA APP_ESCADINHA_TOTAL
    -- CORREÇÃO V5: Faz ST_UnaryUnion uma vez no final ao invés de ST_Union incremental
    -------------------------------------------------------------------------
    IF g_app_total_escadinha_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_total_escadinha_4674) THEN
        g_app_total_escadinha_4674 := ST_Multi(ST_CollectionExtract(
                                      ST_MakeValid(g_app_total_escadinha_4674), 3));
        
        -- CORREÇÃO V5: Faz ST_UnaryUnion uma vez no final
        BEGIN
            g_app_total_escadinha_4674 := ST_UnaryUnion(g_app_total_escadinha_4674);
        EXCEPTION WHEN OTHERS THEN
            g_app_total_escadinha_4674 := ST_UnaryUnion(ST_Buffer(g_app_total_escadinha_4674, 0));
        END;
        
        area_ha := ST_Area(g_app_total_escadinha_4674::geography) / 10000.0;
        
        features_out := features_out || jsonb_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(ST_Transform(g_app_total_escadinha_4674, 4674))::jsonb,
            'properties', jsonb_build_object(
                'tipo', 'APP_ESCADINHA_TOTAL',
                'area_ha', round(area_ha, 4)
            )
        );
    END IF;

    -------------------------------------------------------------------------
    -- 4) RETORNA RESULTADO
    -------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'type', 'FeatureCollection',
        'features', features_clipped || features_out
    );
END;
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_app_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_app_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    input_geojson       jsonb := input_geojson_text::jsonb;
    features_all        jsonb := COALESCE(input_geojson->'features','[]'::jsonb);
    feat                jsonb;
    tipo_raw            text;
    tipo_base           text;
    zona_localizacao    text := 'RURAL';

    -- Geometrias base (trabalho em 4674)
    g_ai_4674           geometry := NULL;
    g_hidrica_4674      geometry := NULL;
    g_al_4674           geometry := NULL;

    -- Geometrias agregadas
    g_ac_4674           geometry := NULL;
    g_avn_4674          geometry := NULL;
    g_anc_4674          geometry := NULL;
    g_topo_morro_4674   geometry := NULL;
    g_aas_4674          geometry := NULL;
    g_bc_4674           geometry := NULL;
    g_adm_4674          geometry := NULL;
    g_aurd_4674         geometry := NULL;
    g_aurp_4674         geometry := NULL;

    -- Auxiliares
    g_feat_4674         geometry := NULL;
    g_buf_4674          geometry := NULL;
    g_dif_4674          geometry := NULL;
    g_app_4674          geometry := NULL;
    g_app_total_4674    geometry := NULL;

    utm                 integer;
    area_ha             numeric;

    -- Overrides por properties
    prop_buffer_m       numeric;
    prop_usa_geom       boolean;
    prop_faixa_lic_m    numeric;

    -- Saída
    features_app        jsonb := '[]'::jsonb;
    features_clipped    jsonb := '[]'::jsonb;
    feature_out         jsonb;

    -- Buffer de correção topológica em graus (~0.1m)
    buffer_epsilon_deg  numeric := 0.000001;
BEGIN
    --------------------------------------------------------------------
    -- 1) AGREGAÇÃO DAS GEOMETRIAS BASE USANDO CTEs
    -- Reason: Evita ST_UnaryUnion(ST_Collect()) dentro de loop
    -- NOTA: Assume entrada já em 4674 (sem ST_Transform)
    --------------------------------------------------------------------
    
    -- Extrai AREA_IMOVEL
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
           ), 3)),
           upper(COALESCE(f->'properties'->>'zona_localizacao', 'RURAL'))
    INTO g_ai_4674, zona_localizacao
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_IMOVEL'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL
    LIMIT 1;

    -- Verificação de segurança
    IF g_ai_4674 IS NULL OR ST_IsEmpty(g_ai_4674) THEN
        RETURN input_geojson;
    END IF;

    -- Extrai AREA_IMOVEL_LIQUIDA
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
           ), 3))
    INTO g_al_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_IMOVEL_LIQUIDA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL
    LIMIT 1;

    -- Se não há área líquida, usa área do imóvel
    IF g_al_4674 IS NULL THEN
        g_al_4674 := g_ai_4674;
    END IF;

    -- Agrega HIDRICO_IMOVEL
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_hidrica_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'HIDRICO_IMOVEL'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega AREA_CONSOLIDADA
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_ac_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_CONSOLIDADA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega VETACAO_NATIVA
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_avn_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'VETACAO_NATIVA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega AREA_NAO_CLASSIFICADA
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_anc_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_NAO_CLASSIFICADA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega AREA_TOPO_MORRO
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_topo_morro_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_TOPO_MORRO'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega AREA_ALTITUDE_SUPERIOR_1800
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_aas_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_ALTITUDE_SUPERIOR_1800'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega BORDA_CHAPADA
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_bc_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'BORDA_CHAPADA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega AREA_DECLIVIDADE_MAIOR_45
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_adm_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_DECLIVIDADE_MAIOR_45'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega AREA_USO_RESTRITO_DECLIVIDADE_25_A_45
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_aurd_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_USO_RESTRITO_DECLIVIDADE_25_A_45'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Agrega AREA_USO_RESTRITO_PANTANEIRA
    SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_UnaryUnion(ST_Collect(
                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
               ))
           ), 3))
    INTO g_aurp_4674
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(f->'properties'->>'tipo') = 'AREA_USO_RESTRITO_PANTANEIRA'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Coleta features para clipping (que não são processadas como APP)
    SELECT COALESCE(jsonb_agg(f), '[]'::jsonb)
    INTO features_clipped
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) IN (
        'AREA_IMOVEL', 'AREA_IMOVEL_LIQUIDA', 'HIDRICO_IMOVEL',
        'AREA_CONSOLIDADA', 'VETACAO_NATIVA', 'AREA_NAO_CLASSIFICADA'
    )
    OR upper(COALESCE(f->'properties'->>'tipo', '')) NOT LIKE 'APP_%'
       AND upper(COALESCE(f->'properties'->>'tipo', '')) NOT IN (
           'RIO_ATE_10','RIO_10_A_50','RIO_50_A_200','RIO_200_A_600','RIO_ACIMA_600',
           'LAGO_NATURAL','NASCENTE_OLHO_DAGUA','RESERVATORIO_ARTIFICIAL_DECORRENTE_BARRAMENTO',
           'VEREDA','RESTINGA','BANHADO','MANGUEZAL',
           'RESERVATORIO_GERACAO_ENERGIA_ATE_24_08_2001',
           'BORDA_CHAPADA','AREA_TOPO_MORRO','AREA_ALTITUDE_SUPERIOR_1800','AREA_DECLIVIDADE_MAIOR_45',
           'AREA_USO_RESTRITO_DECLIVIDADE_25_A_45','AREA_USO_RESTRITO_PANTANEIRA'
       );

    -- Inicializa geometrias vazias se NULL
    IF g_hidrica_4674 IS NULL THEN g_hidrica_4674 := ST_GeomFromText('MULTIPOLYGON EMPTY', 4674); END IF;
    IF g_ac_4674 IS NULL THEN g_ac_4674 := ST_GeomFromText('MULTIPOLYGON EMPTY', 4674); END IF;
    IF g_avn_4674 IS NULL THEN g_avn_4674 := ST_GeomFromText('MULTIPOLYGON EMPTY', 4674); END IF;
    IF g_anc_4674 IS NULL THEN g_anc_4674 := ST_GeomFromText('MULTIPOLYGON EMPTY', 4674); END IF;

    --------------------------------------------------------------------
    -- 2) CÁLCULO DAS APPs INDIVIDUAIS (Hidrografia)
    -- Reason: Mantém loop apenas para APPs que precisam de buffer dinâmico
    --------------------------------------------------------------------
    FOR feat IN 
        SELECT f FROM jsonb_array_elements(features_all) AS f
        WHERE upper(f->'properties'->>'tipo') IN (
            'RIO_ATE_10','RIO_10_A_50','RIO_50_A_200','RIO_200_A_600','RIO_ACIMA_600',
            'LAGO_NATURAL','NASCENTE_OLHO_DAGUA','RESERVATORIO_ARTIFICIAL_DECORRENTE_BARRAMENTO',
            'VEREDA','RESTINGA','BANHADO','MANGUEZAL','RESERVATORIO_GERACAO_ENERGIA_ATE_24_08_2001',
            'BORDA_CHAPADA','AREA_TOPO_MORRO','AREA_ALTITUDE_SUPERIOR_1800','AREA_DECLIVIDADE_MAIOR_45',
            'APP_RIO_ATE_10','APP_RIO_10_A_50','APP_RIO_50_A_200','APP_RIO_200_A_600','APP_RIO_ACIMA_600',
            'APP_LAGO_NATURAL','APP_NASCENTE_OLHO_DAGUA','APP_RESERVATORIO_ARTIFICIAL_DECORRENTE_BARRAMENTO',
            'APP_VEREDA','APP_RESTINGA','APP_BANHADO','APP_MANGUEZAL','APP_RESERVATORIO_GERACAO_ENERGIA_ATE_24_08_2001',
            'APP_BORDA_CHAPADA','APP_AREA_TOPO_MORRO','APP_AREA_ALTITUDE_SUPERIOR_1800','APP_AREA_DECLIVIDADE_MAIOR_45'
        )
          AND f ? 'geometry' AND f->'geometry' IS NOT NULL
    LOOP
        tipo_raw := upper(feat->'properties'->>'tipo');
        tipo_base := regexp_replace(tipo_raw, '^APP_', '');

        -- Ignora tipos que não são APP de hidrografia
        IF tipo_base NOT IN (
            'RIO_ATE_10','RIO_10_A_50','RIO_50_A_200','RIO_200_A_600','RIO_ACIMA_600',
            'LAGO_NATURAL','NASCENTE_OLHO_DAGUA','RESERVATORIO_ARTIFICIAL_DECORRENTE_BARRAMENTO',
            'VEREDA','RESTINGA','BANHADO','MANGUEZAL','RESERVATORIO_GERACAO_ENERGIA_ATE_24_08_2001',
            'BORDA_CHAPADA','AREA_TOPO_MORRO','AREA_ALTITUDE_SUPERIOR_1800','AREA_DECLIVIDADE_MAIOR_45'
        ) THEN
            CONTINUE;
        END IF;

        -- Geometria da feature (já em 4674)
        g_feat_4674 := ST_SetSRID(ST_GeomFromGeoJSON(feat->>'geometry'), 4674);

        IF g_feat_4674 IS NULL OR ST_IsEmpty(g_feat_4674) THEN
            CONTINUE;
        END IF;

        -- Propriedades de override
        prop_buffer_m := (feat->'properties'->>'app_buffer_m')::numeric;
        prop_usa_geom := COALESCE((feat->'properties'->>'usa_geometria')::boolean, FALSE);
        prop_faixa_lic_m := (feat->'properties'->>'faixa_licenciamento_m')::numeric;

        -- Determina zona UTM uma vez
        utm := geometry_bases.utmzone(ST_Centroid(g_feat_4674));

        -- Aplica buffer baseado no tipo
        IF prop_usa_geom IS TRUE THEN
            g_buf_4674 := g_feat_4674;
        ELSIF tipo_base IN ('AREA_TOPO_MORRO','AREA_ALTITUDE_SUPERIOR_1800','AREA_DECLIVIDADE_MAIOR_45','BORDA_CHAPADA') THEN
            g_buf_4674 := g_feat_4674;
        ELSIF tipo_base IN ('RESTINGA','MANGUEZAL','BANHADO') THEN
            g_buf_4674 := g_feat_4674;
        ELSIF tipo_base = 'VEREDA' THEN
            g_buf_4674 := ST_Transform(ST_Buffer(ST_Transform(g_feat_4674, utm), COALESCE(prop_buffer_m, 50)), 4674);
        ELSIF tipo_base = 'RESERVATORIO_ARTIFICIAL_DECORRENTE_BARRAMENTO' THEN
            g_buf_4674 := ST_Transform(ST_Buffer(ST_Transform(g_feat_4674, utm),
                          COALESCE(prop_buffer_m, CASE WHEN zona_localizacao='URBANO' THEN 30 ELSE 100 END)), 4674);
        ELSIF tipo_base = 'RESERVATORIO_GERACAO_ENERGIA_ATE_24_08_2001' THEN
            g_buf_4674 := ST_Transform(ST_Buffer(ST_Transform(g_feat_4674, utm),
                          COALESCE(prop_faixa_lic_m, prop_buffer_m, CASE WHEN zona_localizacao='URBANO' THEN 30 ELSE 100 END)), 4674);
        ELSIF tipo_base IN ('RIO_ATE_10','RIO_10_A_50','RIO_50_A_200','RIO_200_A_600','RIO_ACIMA_600') THEN
            g_buf_4674 := ST_Transform(ST_Buffer(ST_Transform(g_feat_4674, utm),
                          COALESCE(prop_buffer_m,
                                   CASE
                                       WHEN tipo_base='RIO_ATE_10' THEN 30
                                       WHEN tipo_base='RIO_10_A_50' THEN 50
                                       WHEN tipo_base='RIO_50_A_200' THEN 100
                                       WHEN tipo_base='RIO_200_A_600' THEN 200
                                       WHEN tipo_base='RIO_ACIMA_600' THEN 500
                                   END)), 4674);
        ELSIF tipo_base = 'LAGO_NATURAL' THEN
            area_ha := ST_Area(ST_Transform(g_feat_4674, utm)) / 10000.0;
            g_buf_4674 := ST_Transform(ST_Buffer(ST_Transform(g_feat_4674, utm),
                          COALESCE(prop_buffer_m,
                                   CASE WHEN zona_localizacao='RURAL' AND area_ha<=20 THEN 50
                                        WHEN zona_localizacao='RURAL' THEN 100 ELSE 30 END)), 4674);
        ELSIF tipo_base = 'NASCENTE_OLHO_DAGUA' THEN
            g_buf_4674 := ST_Transform(ST_Buffer(ST_Transform(g_feat_4674, utm), COALESCE(prop_buffer_m, 50)), 4674);
        ELSE
            CONTINUE;
        END IF;

        -- Remove a hidrografia da APP
        g_dif_4674 := ST_Difference(g_buf_4674, g_hidrica_4674);

        -- Verifica interseção com área do imóvel
        IF ST_Intersects(g_ai_4674, g_dif_4674) THEN
            g_app_4674 := ST_Multi(ST_CollectionExtract(
                              ST_MakeValid(ST_Intersection(g_al_4674, ST_MakeValid(g_dif_4674))), 3));

            -- Buffer de correção topológica
            IF g_app_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_4674) THEN
                g_app_4674 := ST_Buffer(ST_Buffer(g_app_4674, buffer_epsilon_deg), -buffer_epsilon_deg);
                g_app_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_app_4674), 3));

                IF g_app_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_4674) THEN
                    -- Calcula área
                    area_ha := ST_Area(g_app_4674::geography) / 10000.0;

                    -- Cria feature de saída (em 4674)
                    feature_out := jsonb_build_object(
                        'type', 'Feature',
                        'geometry', ST_AsGeoJSON(ST_Transform(g_app_4674, 4674))::jsonb,
                        'properties', jsonb_build_object(
                            'tipo', 'APP_' || tipo_base,
                            'area_ha', round(area_ha, 4)
                        )
                    );
                    features_app := features_app || feature_out;

                    -- CORREÇÃO V5: Usa ST_Collect ao invés de ST_Union incremental (melhor performance)
                    -- Agrega à APP_TOTAL
                    g_app_total_4674 := CASE
                        WHEN g_app_total_4674 IS NULL THEN g_app_4674
                        ELSE ST_Collect(g_app_total_4674, g_app_4674)
                    END;
                END IF;
            END IF;
        END IF;
    END LOOP;

    --------------------------------------------------------------------
    -- 3) CRIA APP_TOTAL
    -- CORREÇÃO V5: Faz ST_UnaryUnion uma vez no final
    --------------------------------------------------------------------
    IF g_app_total_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_total_4674) THEN
        g_app_total_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_app_total_4674), 3));
        
        -- CORREÇÃO V5: Faz ST_UnaryUnion uma vez no final
        BEGIN
            g_app_total_4674 := ST_UnaryUnion(g_app_total_4674);
        EXCEPTION WHEN OTHERS THEN
            g_app_total_4674 := ST_UnaryUnion(ST_Buffer(g_app_total_4674, 0));
        END;
        
        area_ha := ST_Area(g_app_total_4674::geography) / 10000.0;
        
        feature_out := jsonb_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(ST_Transform(g_app_total_4674, 4674))::jsonb,
            'properties', jsonb_build_object(
                'tipo', 'APP_TOTAL',
                'area_ha', round(area_ha, 4)
            )
        );
        features_app := features_app || feature_out;

        --------------------------------------------------------------------
        -- 4) SOBREPOSIÇÕES DA APP_TOTAL
        --------------------------------------------------------------------
        
        -- APP sobre Área Consolidada (APP_AREA_AC)
        IF g_ac_4674 IS NOT NULL AND NOT ST_IsEmpty(g_ac_4674) THEN
            g_app_4674 := ST_Multi(ST_CollectionExtract(
                              ST_MakeValid(ST_Intersection(g_ac_4674, g_app_total_4674)), 3));
            IF g_app_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_4674) THEN
                g_app_4674 := ST_Buffer(ST_Buffer(g_app_4674, buffer_epsilon_deg), -buffer_epsilon_deg);
                g_app_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_app_4674), 3));
                IF g_app_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_4674) THEN
                    area_ha := ST_Area(g_app_4674::geography) / 10000.0;
                    features_app := features_app || jsonb_build_object(
                        'type', 'Feature',
                        'geometry', ST_AsGeoJSON(ST_Transform(g_app_4674, 4674))::jsonb,
                        'properties', jsonb_build_object('tipo', 'APP_AREA_AC', 'area_ha', round(area_ha, 4))
                    );
                END IF;
            END IF;
        END IF;

        -- APP sobre Vegetação Nativa (APP_AREA_VN)
        IF g_avn_4674 IS NOT NULL AND NOT ST_IsEmpty(g_avn_4674) THEN
            g_app_4674 := ST_Multi(ST_CollectionExtract(
                              ST_MakeValid(ST_Intersection(g_avn_4674, g_app_total_4674)), 3));
            IF g_app_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_4674) THEN
                g_app_4674 := ST_Buffer(ST_Buffer(g_app_4674, buffer_epsilon_deg), -buffer_epsilon_deg);
                g_app_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_app_4674), 3));
                IF g_app_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_4674) THEN
                    area_ha := ST_Area(g_app_4674::geography) / 10000.0;
                    features_app := features_app || jsonb_build_object(
                        'type', 'Feature',
                        'geometry', ST_AsGeoJSON(ST_Transform(g_app_4674, 4674))::jsonb,
                        'properties', jsonb_build_object('tipo', 'APP_AREA_VN', 'area_ha', round(area_ha, 4))
                    );
                END IF;
            END IF;
        END IF;

        -- APP Vazio (APP_VAZIO)
        IF g_anc_4674 IS NOT NULL AND NOT ST_IsEmpty(g_anc_4674) THEN
            g_app_4674 := ST_Multi(ST_CollectionExtract(
                              ST_MakeValid(ST_Intersection(g_anc_4674, g_app_total_4674)), 3));
            IF g_app_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_4674) THEN
                g_app_4674 := ST_Buffer(ST_Buffer(g_app_4674, buffer_epsilon_deg), -buffer_epsilon_deg);
                g_app_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_app_4674), 3));
                IF g_app_4674 IS NOT NULL AND NOT ST_IsEmpty(g_app_4674) THEN
                    area_ha := ST_Area(g_app_4674::geography) / 10000.0;
                    features_app := features_app || jsonb_build_object(
                        'type', 'Feature',
                        'geometry', ST_AsGeoJSON(ST_Transform(g_app_4674, 4674))::jsonb,
                        'properties', jsonb_build_object('tipo', 'APP_VAZIO', 'area_ha', round(area_ha, 4))
                    );
                END IF;
            END IF;
        END IF;
    END IF;

    --------------------------------------------------------------------
    -- 5) PROCESSAMENTO DAS APPs DE RELEVO
    -- Reason: Consolidado em função auxiliar inline
    --------------------------------------------------------------------
    
    -- Função auxiliar para processar APP de relevo
    <<process_relief_app>>
    DECLARE
        relief_types text[] := ARRAY['AREA_TOPO_MORRO', 'AREA_ALTITUDE_SUPERIOR_1800', 'BORDA_CHAPADA', 
                                     'AREA_DECLIVIDADE_MAIOR_45', 'AREA_USO_RESTRITO_DECLIVIDADE_25_A_45', 
                                     'AREA_USO_RESTRITO_PANTANEIRA'];
        relief_geoms geometry[] := ARRAY[g_topo_morro_4674, g_aas_4674, g_bc_4674, g_adm_4674, g_aurd_4674, g_aurp_4674];
        i integer;
        g_relief geometry;
    BEGIN
        FOR i IN 1..array_length(relief_types, 1) LOOP
            g_relief := relief_geoms[i];
            
            IF g_relief IS NOT NULL AND NOT ST_IsEmpty(g_relief) THEN
                -- Intersecta com área líquida
                g_relief := ST_Multi(ST_CollectionExtract(
                                ST_MakeValid(ST_Intersection(g_relief, g_al_4674)), 3));
                
                IF g_relief IS NOT NULL AND NOT ST_IsEmpty(g_relief) THEN
                    -- Remove hidrografia
                    IF g_hidrica_4674 IS NOT NULL AND NOT ST_IsEmpty(g_hidrica_4674) THEN
                        g_relief := ST_Multi(ST_CollectionExtract(
                                        ST_MakeValid(ST_Difference(g_relief, g_hidrica_4674)), 3));
                    END IF;
                    
                    IF g_relief IS NOT NULL AND NOT ST_IsEmpty(g_relief) THEN
                        -- Buffer de correção
                        g_relief := ST_Buffer(ST_Buffer(g_relief, buffer_epsilon_deg), -buffer_epsilon_deg);
                        g_relief := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_relief), 3));
                        
                        IF g_relief IS NOT NULL AND NOT ST_IsEmpty(g_relief) THEN
                            area_ha := ST_Area(g_relief::geography) / 10000.0;
                            features_app := features_app || jsonb_build_object(
                                'type', 'Feature',
                                'geometry', ST_AsGeoJSON(ST_Transform(g_relief, 4674))::jsonb,
                                'properties', jsonb_build_object(
                                    'tipo', relief_types[i],
                                    'area_ha', round(area_ha, 4)
                                )
                            );
                        END IF;
                    END IF;
                END IF;
            END IF;
        END LOOP;
    END process_relief_app;

    --------------------------------------------------------------------
    -- 6) RETORNA RESULTADO
    --------------------------------------------------------------------
    RETURN jsonb_build_object(
        'type', 'FeatureCollection',
        'features', features_app || features_clipped
    );
END;
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_area_imovel_liquida_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_area_imovel_liquida_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    input_geojson         jsonb := input_geojson_text::jsonb;
    features_acc          jsonb := COALESCE(input_geojson->'features', '[]'::jsonb);

    -- Geometrias de trabalho (todas em 4674)
    geom_ai_union_4674    geometry := NULL;
    geom_serv_union_4674  geometry := NULL;
    geom_liquida_4674     geometry := NULL;

    -- UTM (determinado uma única vez)
    utm                   integer := NULL;
    buffer_epsilon_m      numeric := 0.1;  -- correção topológica condicional

    -- Saída
    feature_liquida       jsonb;
    found_ai              boolean := false;
    found_serv            boolean := false;

BEGIN
    -----------------------------------------------------------------------
    -- 1) AGREGAÇÃO DAS GEOMETRIAS BASE USANDO QUERIES
    -- Reason: Evita ST_Collect incremental e ST_Transform no loop
    -- NOTA: Assume entrada já em 4674 (sem ST_Transform)
    -----------------------------------------------------------------------
    
    -- Extrai e normaliza AREA_IMOVEL
    -- Reason: Usa ST_SnapToGrid logo após ST_UnaryUnion (evita 2x SnapToGrid)
    SELECT ST_Multi(ST_CollectionExtract(
               ST_SnapToGrid(
                   ST_MakeValid(
                       ST_UnaryUnion(ST_Collect(
                           ST_SnapToGrid(
                               ST_MakeValid(
                                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
                               ), 
                               1e-8
                           )
                       ))
                   ), 
                   1e-8
               ), 3))
    INTO geom_ai_union_4674
    FROM jsonb_array_elements(features_acc) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_IMOVEL'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    -- Verificação de segurança
    IF geom_ai_union_4674 IS NULL OR ST_IsEmpty(geom_ai_union_4674) THEN
        RETURN input_geojson;
    END IF;

    -- Extrai zona UTM uma única vez (do centroide da área)
    utm := geometry_bases.utmzone(ST_Centroid(geom_ai_union_4674));
    found_ai := true;

    -- Extrai e normaliza AREA_SERVIDAO_ADMINISTRATIVA_TOTAL (se existir)
    SELECT ST_Multi(ST_CollectionExtract(
               ST_SnapToGrid(
                   ST_MakeValid(
                       ST_UnaryUnion(ST_Collect(
                           ST_SnapToGrid(
                               ST_MakeValid(
                                   ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
                               ), 
                               1e-8
                           )
                       ))
                   ), 
                   1e-8
               ), 3))
    INTO geom_serv_union_4674
    FROM jsonb_array_elements(features_acc) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_SERVIDAO_ADMINISTRATIVA_TOTAL'
      AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

    IF geom_serv_union_4674 IS NOT NULL AND NOT ST_IsEmpty(geom_serv_union_4674) THEN
        found_serv := true;
    END IF;

    -----------------------------------------------------------------------
    -- 2) CALCULAR ÁREA LÍQUIDA
    -----------------------------------------------------------------------
    
    IF found_serv THEN
        -- Área Líquida = AREA_IMOVEL - SERVIDAO
        geom_liquida_4674 := ST_Difference(geom_ai_union_4674, geom_serv_union_4674);
        geom_liquida_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(geom_liquida_4674), 3));

        IF geom_liquida_4674 IS NULL OR ST_IsEmpty(geom_liquida_4674) THEN
            RETURN input_geojson;
        END IF;

        -- Só aplica buffer com reprojeção UTM se geometria estiver inválida
        -- Reason: Buffer é operação cara, evita se desnecessário
        IF NOT ST_IsValid(geom_liquida_4674) THEN
            geom_liquida_4674 := ST_Buffer(
                                    ST_Transform(geom_liquida_4674, utm), 
                                    buffer_epsilon_m
                                );
            geom_liquida_4674 := ST_Transform(geom_liquida_4674, 4674);
            geom_liquida_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(geom_liquida_4674), 3));

            IF geom_liquida_4674 IS NULL OR ST_IsEmpty(geom_liquida_4674) THEN
                RETURN input_geojson;
            END IF;
        END IF;
    ELSE
        -- Sem servidão: área líquida = área do imóvel
        geom_liquida_4674 := geom_ai_union_4674;
    END IF;

    -- Opcional: converte MULTIPOLYGON com 1 geometria para POLYGON
    -- Reason: Alguns sistemas preferem POLYGON para peças únicas
    IF ST_GeometryType(geom_liquida_4674) = 'ST_MultiPolygon' 
       AND ST_NumGeometries(geom_liquida_4674) = 1 THEN
        geom_liquida_4674 := ST_GeometryN(geom_liquida_4674, 1);
    END IF;

    -----------------------------------------------------------------------
    -- 3) MONTAR RESULTADO (mantém em 4674)
    -----------------------------------------------------------------------
    
    -- Remove qualquer AREA_IMOVEL_LIQUIDA existente
    features_acc := COALESCE((
        SELECT jsonb_agg(f)
        FROM jsonb_array_elements(features_acc) AS f
        WHERE upper(COALESCE(f->'properties'->>'tipo', '')) <> 'AREA_IMOVEL_LIQUIDA'
    ), '[]'::jsonb);

    -- Cria nova feature (em 4674)
    feature_liquida := jsonb_build_object(
        'type', 'Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(geom_liquida_4674, 4674))::jsonb,
        'properties', jsonb_build_object('tipo', 'AREA_IMOVEL_LIQUIDA')
    );

    features_acc := features_acc || feature_liquida;

    RETURN input_geojson || jsonb_build_object('features', features_acc);
END;
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_area_nao_classificada_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_area_nao_classificada_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    j_in            jsonb := input_geojson_text::jsonb;
    feats_in        jsonb := COALESCE(j_in->'features','[]'::jsonb);
    feats_out       jsonb := feats_in;
    
    -- Buffer de correção topológica em graus (~0.1m em latitude média do Brasil)
    -- Reason: Evita reprojetar para UTM só para aplicar buffer
    buffer_epsilon_deg numeric := 0.000001;  -- ~0.1m em graus

    -- Acumuladores em 4674
    g_area_imovel_4674   geometry := NULL;
    g_ant_vet_4674       geometry := NULL;
    g_ant_nao_vet_4674   geometry := NULL;
    g_union_anc_4674     geometry := NULL;
    
    feature_out          jsonb;
BEGIN
    -- Sanidade básica: Verifica se a entrada é uma FeatureCollection
    IF j_in->>'type' IS DISTINCT FROM 'FeatureCollection' THEN
        RETURN jsonb_build_object(
            'type', 'FeatureCollection',
            'features', '[]'::jsonb,
            'message', 'GeoJSON inválido: esperado FeatureCollection'
        );
    END IF; 

    ---------------------------------------------------------------------------------
    -- PASSO 1: AGREGAR GEOMETRIAS DE AREA_IMOVEL
    -- Reason: Usa ST_Collect + ST_UnaryUnion (1 operação) ao invés de ST_Union incremental (N operações)
    ---------------------------------------------------------------------------------
    SELECT ST_Multi(ST_CollectionExtract(
               ST_MakeValid(
                   ST_UnaryUnion(
                       ST_Collect(
                           ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
                       )
                   )
               ), 3
           ))
    INTO g_area_imovel_4674
    FROM jsonb_array_elements(feats_in) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_IMOVEL'
      AND f ? 'geometry'
      AND f->'geometry' IS NOT NULL;

    -- Verificação de segurança: Se não há AREA_IMOVEL válida, retorna entrada
    IF g_area_imovel_4674 IS NULL OR ST_IsEmpty(g_area_imovel_4674) THEN
        RETURN j_in; 
    END IF;

    ---------------------------------------------------------------------------------
    -- PASSO 2: AGREGAR GEOMETRIAS DE AREA_ANTROPIZADA_APOS_2008_VETORIZADA
    ---------------------------------------------------------------------------------
    SELECT ST_Multi(ST_CollectionExtract(
               ST_MakeValid(
                   ST_UnaryUnion(
                       ST_Collect(
                           ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
                       )
                   )
               ), 3
           ))
    INTO g_ant_vet_4674
    FROM jsonb_array_elements(feats_in) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_ANTROPIZADA_APOS_2008_VETORIZADA'
      AND f ? 'geometry'
      AND f->'geometry' IS NOT NULL;

    ---------------------------------------------------------------------------------
    -- PASSO 3: AGREGAR GEOMETRIAS DE AREA_ANTROPIZADA_APOS_2008_NAO_VETORIZADA
    ---------------------------------------------------------------------------------
    SELECT ST_Multi(ST_CollectionExtract(
               ST_MakeValid(
                   ST_UnaryUnion(
                       ST_Collect(
                           ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
                       )
                   )
               ), 3
           ))
    INTO g_ant_nao_vet_4674
    FROM jsonb_array_elements(feats_in) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_ANTROPIZADA_APOS_2008_NAO_VETORIZADA'
      AND f ? 'geometry'
      AND f->'geometry' IS NOT NULL;

    ---------------------------------------------------------------------------------
    -- PASSO 4: CALCULAR UNIÃO DAS ÁREAS ANTROPIZADAS
    -- Reason: AREA_NAO_CLASSIFICADA = VETORIZADA ∪ NAO_VETORIZADA
    ---------------------------------------------------------------------------------
    
    -- Trata NULLs como geometrias vazias para o ST_Union
    IF g_ant_vet_4674 IS NULL THEN
        g_ant_vet_4674 := ST_GeomFromText('MULTIPOLYGON EMPTY', 4674);
    END IF;
    
    IF g_ant_nao_vet_4674 IS NULL THEN
        g_ant_nao_vet_4674 := ST_GeomFromText('MULTIPOLYGON EMPTY', 4674);
    END IF;

    -- União das áreas antropizadas
    g_union_anc_4674 := ST_Union(g_ant_vet_4674, g_ant_nao_vet_4674);

    -- Se a união está vazia, retorna entrada original
    IF g_union_anc_4674 IS NULL OR ST_IsEmpty(g_union_anc_4674) THEN
        RETURN j_in;
    END IF;

    ---------------------------------------------------------------------------------
    -- PASSO 5: CORREÇÃO TOPOLÓGICA COM BUFFER
    -- Reason: Buffer positivo+negativo resolve problemas de topologia
    --         Usando graus diretamente evita 2 ST_Transform para UTM
    ---------------------------------------------------------------------------------
    g_union_anc_4674 := ST_Buffer(ST_Buffer(g_union_anc_4674, buffer_epsilon_deg), -buffer_epsilon_deg);
    g_union_anc_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_union_anc_4674), 3));

    -- Se após correção ficou vazio, retorna entrada original
    IF g_union_anc_4674 IS NULL OR ST_IsEmpty(g_union_anc_4674) THEN
        RETURN j_in;
    END IF;

    ---------------------------------------------------------------------------------
    -- PASSO 6: MONTAR A FEATURE DE SAÍDA
    -- NOTA: Saída em 4674 (sem ST_Transform para 4170)
    ---------------------------------------------------------------------------------
    feature_out := jsonb_build_object(
        'type', 'Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(g_union_anc_4674, 4674))::jsonb,
        'properties', jsonb_build_object('tipo', 'AREA_NAO_CLASSIFICADA')
    );

    -- Remove qualquer feature 'AREA_NAO_CLASSIFICADA' antiga
    feats_out := (
        SELECT COALESCE(jsonb_agg(f), '[]'::jsonb)
        FROM jsonb_array_elements(feats_out) f
        WHERE upper(COALESCE(f->'properties'->>'tipo', '')) <> 'AREA_NAO_CLASSIFICADA'
    );

    -- Adiciona a nova feature calculada
    feats_out := feats_out || feature_out;

    ---------------------------------------------------------------------------------
    -- PASSO 7: RETORNAR RESULTADO
    ---------------------------------------------------------------------------------
    RETURN j_in || jsonb_build_object('features', feats_out);
END;
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_cobertura_solo_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_cobertura_solo_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  j         jsonb := input_geojson_text::jsonb;
  feats     jsonb := COALESCE(j->'features', '[]'::jsonb);
  
  -- Geometrias base (trabalho em 4674)
  g_imovel     geometry := NULL;
  g_hidrico    geometry := NULL;
  g_vn         geometry := NULL;
  g_ac         geometry := NULL;
  g_ant_vet    geometry := NULL;
  g_pousio     geometry := NULL;

  -- Geometrias processadas (com prioridades aplicadas)
  g_vn_out      geometry := NULL;
  g_ac_out      geometry := NULL;
  g_ant_vet_out geometry := NULL;
  g_ant_nao_out geometry := NULL;
  g_pousio_out  geometry := NULL;
  
  -- Acumuladores de prioridade
  g_vn_hidrico_out           geometry := NULL;
  g_vn_hidrico_ac_out        geometry := NULL;
  g_vn_hidrico_ac_ant_vet_out geometry := NULL;

  -- Saída
  kept_others   jsonb := '[]'::jsonb;
  features_out  jsonb := '[]'::jsonb;

BEGIN 

   -------------------------------------------------------------------------
   -- 1) AGREGAÇÃO DAS GEOMETRIAS BASE USANDO QUERIES
   -- Reason: Evita ST_Union incremental dentro de loops
   -- NOTA: Assume entrada já em 4674 (sem ST_Transform)
   -------------------------------------------------------------------------
  
  -- Extrai AREA_IMOVEL_LIQUIDA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_imovel
  FROM jsonb_array_elements(feats) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_IMOVEL_LIQUIDA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Retorna se não há imóvel
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN j;
  END IF;

  -- Agrega HIDRICO_IMOVEL
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_hidrico
  FROM jsonb_array_elements(feats) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'HIDRICO_IMOVEL'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega VEGETACAO_NATIVA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_vn
  FROM jsonb_array_elements(feats) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'VEGETACAO_NATIVA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega AREA_CONSOLIDADA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_ac
  FROM jsonb_array_elements(feats) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_CONSOLIDADA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega AREA_ANTROPIZADA_APOS_2008_VETORIZADA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_ant_vet
  FROM jsonb_array_elements(feats) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_ANTROPIZADA_APOS_2008_VETORIZADA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega AREA_POUSIO
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_pousio
  FROM jsonb_array_elements(feats) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_POUSIO'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Coleta outras features (que não serão recalculadas)
  SELECT COALESCE(jsonb_agg(f), '[]'::jsonb)
  INTO kept_others
  FROM jsonb_array_elements(feats) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) NOT IN (
      'VEGETACAO_NATIVA',
      'AREA_CONSOLIDADA',
      'AREA_ANTROPIZADA_APOS_2008_VETORIZADA',
      'AREA_ANTROPIZADA_APOS_2008_NAO_VETORIZADA',
      'AREA_POUSIO',
      'AREA_IMOVEL_LIQUIDA',
      'HIDRICO_IMOVEL'
  );

  -------------------------------------------------------------------------
  -- 2) RESTRINGIR COBERTURAS AO IMÓVEL LÍQUIDO
  -- Reason: Garante que todas as camadas só existam dentro da AI
  -------------------------------------------------------------------------
  IF g_imovel IS NOT NULL AND NOT ST_IsEmpty(g_imovel) THEN
    IF g_vn IS NOT NULL THEN
      g_vn := ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Intersection(g_vn, g_imovel)), 3));
    END IF;
    IF g_ac IS NOT NULL THEN
      g_ac := ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Intersection(g_ac, g_imovel)), 3));
    END IF;
    IF g_ant_vet IS NOT NULL THEN
      g_ant_vet := ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Intersection(g_ant_vet, g_imovel)), 3));
    END IF;
    IF g_pousio IS NOT NULL THEN
      g_pousio := ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Intersection(g_pousio, g_imovel)), 3));
    END IF;
  END IF;

  -------------------------------------------------------------------------
  -- 3) APLICAR PRIORIDADE (Lógica de Sobreposição)
  -- Reason: "Esculpe" as geometrias sem sobreposição, seguindo ordem:
  --   1. VN (remove Hidrografia)
  --   2. AC (remove VN e Hidrografia)
  --   3. ANT_VET (remove VN, Hidrografia e AC)
  --   4. ANT_NAO (é o que sobra do imóvel após remover tudo acima)
  --   5. POUSIO (remove Hidrografia)
  -------------------------------------------------------------------------

  -- Prioridade 1: VEGETACAO_NATIVA (menos hidrografia)
  IF g_vn IS NOT NULL THEN
    g_vn_out := ST_Multi(ST_CollectionExtract(
                  ST_MakeValid(
                    ST_Difference(g_vn, COALESCE(g_hidrico, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)))
                  ), 3));
  END IF;

  -- CORREÇÃO V5: Adiciona fallback de ST_UnaryUnion (como na V2)
  -- Acumula o que já foi processado (VN + Hidrico)
  BEGIN
    g_vn_hidrico_out := ST_UnaryUnion(ST_Union(
        COALESCE(g_vn_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
        COALESCE(g_hidrico, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
    ));
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      g_vn_hidrico_out := ST_UnaryUnion(ST_Buffer(ST_Union(
          COALESCE(g_vn_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
          COALESCE(g_hidrico, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
      ), 0));
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;

  -- Prioridade 2: AREA_CONSOLIDADA (menos VN e Hidrografia)
  IF g_ac IS NOT NULL THEN
    g_ac_out := ST_Multi(ST_CollectionExtract(
                  ST_MakeValid(
                    ST_Difference(g_ac, g_vn_hidrico_out)
                  ), 3));
  END IF;

  -- CORREÇÃO V5: Adiciona fallback de ST_UnaryUnion
  -- Acumula o que já foi processado (VN + Hidrico + AC)
  BEGIN
    g_vn_hidrico_ac_out := ST_UnaryUnion(ST_Union(
        COALESCE(g_vn_hidrico_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
        COALESCE(g_ac_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
    ));
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      g_vn_hidrico_ac_out := ST_UnaryUnion(ST_Buffer(ST_Union(
          COALESCE(g_vn_hidrico_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
          COALESCE(g_ac_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
      ), 0));
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;

  -- Prioridade 3: AREA_ANTROPIZADA_APOS_2008_VETORIZADA
  IF g_ant_vet IS NOT NULL THEN
    g_ant_vet_out := ST_Multi(ST_CollectionExtract(
                        ST_MakeValid(
                          ST_Difference(
                            g_ant_vet,
                            g_vn_hidrico_ac_out
                          )
                        ), 3));
  END IF;

  -- CORREÇÃO V5: Adiciona fallback de ST_UnaryUnion
  -- Acumula o que já foi processado (VN + Hidrico + AC + ANT_VET)
  BEGIN
    g_vn_hidrico_ac_ant_vet_out := ST_UnaryUnion(ST_Union(
        COALESCE(g_ant_vet_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
        COALESCE(g_vn_hidrico_ac_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
    ));
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      g_vn_hidrico_ac_ant_vet_out := ST_UnaryUnion(ST_Buffer(ST_Union(
          COALESCE(g_ant_vet_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
          COALESCE(g_vn_hidrico_ac_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
      ), 0));
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;

  -- Prioridade 4: AREA_ANTROPIZADA_APOS_2008_NAO_VETORIZADA (A "Sobra")
  -- É calculada como: IMOVEL - (VN U HIDRICO U AC U ANT_VET)
  g_ant_nao_out := ST_Multi(ST_CollectionExtract(
                      ST_MakeValid(
                        ST_Difference(
                          g_imovel,
                          g_vn_hidrico_ac_ant_vet_out
                        )
                      ), 3));

  -- Prioridade 5: AREA_POUSIO (menos hidrografia)
  IF g_pousio IS NOT NULL THEN
    g_pousio_out := ST_Multi(ST_CollectionExtract(
                ST_MakeValid(
                  ST_Difference(g_pousio, COALESCE(g_hidrico, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)))
                ), 3));
  END IF;

  -------------------------------------------------------------------------
  -- 4) MONTA FEATURES DE SAÍDA (em 4674)
  -------------------------------------------------------------------------

   IF g_vn_out IS NOT NULL AND NOT ST_IsEmpty(g_vn_out) THEN
     features_out := features_out || jsonb_build_object(
       'type', 'Feature',
       'geometry', ST_AsGeoJSON(ST_Transform(g_vn_out, 4674))::jsonb,
       'properties', jsonb_build_object('tipo', 'VEGETACAO_NATIVA')
     );
   END IF;

   IF g_ac_out IS NOT NULL AND NOT ST_IsEmpty(g_ac_out) THEN
     features_out := features_out || jsonb_build_object(
       'type', 'Feature',
       'geometry', ST_AsGeoJSON(ST_Transform(g_ac_out, 4674))::jsonb,
       'properties', jsonb_build_object('tipo', 'AREA_CONSOLIDADA')
     );
   END IF;

   IF g_ant_vet_out IS NOT NULL AND NOT ST_IsEmpty(g_ant_vet_out) THEN
     features_out := features_out || jsonb_build_object(
       'type', 'Feature',
       'geometry', ST_AsGeoJSON(ST_Transform(g_ant_vet_out, 4674))::jsonb,
       'properties', jsonb_build_object('tipo', 'AREA_ANTROPIZADA_APOS_2008_VETORIZADA')
     );
   END IF;

   IF g_ant_nao_out IS NOT NULL AND NOT ST_IsEmpty(g_ant_nao_out) THEN
     features_out := features_out || jsonb_build_object(
       'type', 'Feature',
       'geometry', ST_AsGeoJSON(ST_Transform(g_ant_nao_out, 4674))::jsonb,
       'properties', jsonb_build_object('tipo', 'AREA_ANTROPIZADA_APOS_2008_NAO_VETORIZADA')
     );
   END IF;

   IF g_pousio_out IS NOT NULL AND NOT ST_IsEmpty(g_pousio_out) THEN
     features_out := features_out || jsonb_build_object(
       'type', 'Feature',
       'geometry', ST_AsGeoJSON(ST_Transform(g_pousio_out, 4674))::jsonb,
       'properties', jsonb_build_object('tipo', 'AREA_POUSIO')
     );
   END IF;

  -- Retorna o JSON final
  RETURN jsonb_build_object('type', 'FeatureCollection', 'features', kept_others || features_out);
END; 
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_hidrico_imovel_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_hidrico_imovel_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  input_geojson   jsonb := input_geojson_text::jsonb;

  -- Geometria final (em 4674)
  g_hidrica_4674  geometry;

  -- Saída
  features_out    jsonb := '[]'::jsonb;
  f_out           jsonb;

BEGIN

  -----------------------------------------------------------------------
  -- 1) AGREGAÇÃO DE TEMAS HÍDRICOS USANDO QUERY
  -- Reason: Evita ST_UnaryUnion(ST_Collect(...)) incremental no loop
  --         Padroniza em 4674 para consistência
  -- NOTA: Assume entrada em 4326 (sem necessidade de transformar entrada)
  -----------------------------------------------------------------------
  SELECT ST_Multi(ST_CollectionExtract(
             ST_SnapToGrid(
                 ST_MakeValid(
                     ST_UnaryUnion(ST_Collect(
                         ST_Transform(
                             ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4326),
                             4674
                         )
                     ))
                 ),
                 1e-8
             ), 3))
  INTO g_hidrica_4674
  FROM jsonb_array_elements(input_geojson->'features') AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) IN (
      'LAGO_NATURAL',
      'RESERVATORIO_ENERGIA',
      'RIO_ATE_10',
      'RIO_10_A_50',
      'RIO_50_A_200',
      'RIO_200_A_600',
      'RIO_ACIMA_600'
  )
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -----------------------------------------------------------------------
  -- 2) MONTA FEATURE DE SAÍDA (em 4674)
  -----------------------------------------------------------------------
  IF g_hidrica_4674 IS NOT NULL AND NOT ST_IsEmpty(g_hidrica_4674) THEN
    f_out := jsonb_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(ST_Transform(g_hidrica_4674, 4674), 6, 1)::jsonb,
      'properties', jsonb_build_object('tipo', 'HIDRICO_IMOVEL')
    );
    features_out := features_out || f_out;
  END IF;

  -----------------------------------------------------------------------
  -- 3) RETORNA RESULTADO
  -----------------------------------------------------------------------
  RETURN jsonb_build_object(
    'type', 'FeatureCollection',
    'features', features_out
  );

END;
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_modulo_fiscal_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_modulo_fiscal_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    j                   jsonb := input_geojson_text::jsonb;
    feats_in            jsonb := COALESCE(j->'features','[]'::jsonb);
    feats_out           jsonb := '[]'::jsonb;

    feat                jsonb;
    tipo                text;

    gjson_geom_text     text;
    geom_4674           geometry;

    modulo_fiscal       double precision;
    modulo_fiscal_round numeric;   -- << arredondado em 4 casas
BEGIN
    IF j->>'type' IS DISTINCT FROM 'FeatureCollection' THEN
        RETURN jsonb_build_object(
            'type','FeatureCollection',
            'features','[]'::jsonb,
            'message','GeoJSON inválido: esperado FeatureCollection'
        );
    END IF;

    FOR feat IN
        SELECT value FROM jsonb_array_elements(feats_in)
    LOOP
        tipo := upper(feat->'properties'->>'tipo');

        IF tipo IN ('AREA_IMOVEL','AREA_IMOVEL_LIQUIDA') THEN
            gjson_geom_text := feat->>'geometry';

            IF gjson_geom_text IS NULL THEN
                feats_out := feats_out || feat;
                CONTINUE;
            END IF;

            geom_4674 := ST_Transform(
                            ST_SetSRID(ST_GeomFromGeoJSON(gjson_geom_text), 4170),
                            4674
                        );
            geom_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(geom_4674), 3));

            IF geom_4674 IS NULL OR ST_IsEmpty(geom_4674) THEN
                modulo_fiscal := 0.0;
            ELSE
                SELECT
                    SUM( (ST_Area(geom_part::geography) / 10000.0) / num_hectares_modulo_fiscal )::double precision
                INTO modulo_fiscal
                FROM (
                    SELECT
                        m.num_hectares_modulo_fiscal,
                        CASE
                            WHEN ST_CoveredBy(geom_4674, m.geo_localizacao) THEN geom_4674
                            ELSE ST_Multi(ST_Intersection(geom_4674, m.geo_localizacao))
                        END AS geom_part
                    FROM geometry_bases.municipio AS m
                    WHERE ST_Intersects(geom_4674, m.geo_localizacao)
                      AND NOT ST_Touches(geom_4674, m.geo_localizacao)
                ) AS parts;

                IF modulo_fiscal IS NULL THEN
                    modulo_fiscal := 0.0;
                END IF;
            END IF;

            -- <<< Arredondamento em 4 casas
            modulo_fiscal_round := ROUND(modulo_fiscal::numeric, 4);

            feats_out := feats_out || jsonb_build_object(
                'type', 'Feature',
                'geometry', feat->'geometry',
                'properties', (feat->'properties') || jsonb_build_object('modulo_fiscal', modulo_fiscal_round)
            );
        ELSE
            feats_out := feats_out || feat;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'type', 'FeatureCollection',
        'features', feats_out
    );
END;
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_rl_total_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_rl_total_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    input_geojson   jsonb := input_geojson_text::jsonb;
    features_all    jsonb := COALESCE(input_geojson->'features','[]'::jsonb);

    -- Geometrias de base (trabalho em 4674)
    g_hidrica_4674     geometry := NULL;
    g_al_4674          geometry := NULL;  -- Área Líquida
    g_ac_4674          geometry := NULL;  -- Área Consolidada
    g_anc_4674         geometry := NULL;  -- Área Não Classificada
    g_arl_outro_imovel_4674 geometry := NULL;
    
    -- ARLs agregadas
    g_arl_a_4674       geometry := NULL;  -- Averbada
    g_arl_ana_4674     geometry := NULL;  -- Aprovada Não Averbada
    g_arl_p_4674       geometry := NULL;  -- Proposta

    -- Geometrias processadas
    g_arl_a_out        geometry := NULL;
    g_arl_ana_out      geometry := NULL;
    g_arl_p_out        geometry := NULL;
    g_rl_total_4674    geometry := NULL;
    g_arl_recuperar_4674 geometry := NULL;
    g_arl_outro_imovel_out geometry := NULL;
    
    -- Acumuladores de prioridade
    g_arl_a_hidrico_4674       geometry := NULL;
    g_arl_ana_hidrico_4674     geometry := NULL;

    -- Saída
    features_clipped jsonb := '[]'::jsonb;
    features_rl      jsonb := '[]'::jsonb;
    feature_out      jsonb;
    
    area_ha          numeric;
    buffer_epsilon_deg numeric := 0.000001;  -- ~0.1m em graus

BEGIN

   -------------------------------------------------------------------------
   -- 1) AGREGAÇÃO DAS GEOMETRIAS BASE USANDO QUERIES
   -- Reason: Evita ST_UnaryUnion(ST_Collect(...)) dentro de loops
   -- NOTA: Assume entrada já em 4674 (sem ST_Transform)
   -------------------------------------------------------------------------
  
  -- Extrai HIDRICO_IMOVEL
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
         ), 3))
  INTO g_hidrica_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'HIDRICO_IMOVEL'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL
  LIMIT 1;

  -- Extrai AREA_IMOVEL_LIQUIDA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
         ), 3))
  INTO g_al_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_IMOVEL_LIQUIDA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL
  LIMIT 1;

  -- Agrega AREA_CONSOLIDADA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_ac_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_CONSOLIDADA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega AREA_NAO_CLASSIFICADA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_anc_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_NAO_CLASSIFICADA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega ARL_AVERBADA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_arl_a_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'ARL_AVERBADA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega ARL_APROVADA_NAO_AVERBADA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_arl_ana_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'ARL_APROVADA_NAO_AVERBADA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega ARL_PROPOSTA
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_arl_p_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'ARL_PROPOSTA'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Agrega ARL_AVERBADA_OUTRO_IMOVEL
  SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
             ST_UnaryUnion(ST_Collect(
                 ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
             ))
         ), 3))
  INTO g_arl_outro_imovel_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'ARL_AVERBADA_OUTRO_IMOVEL'
    AND f ? 'geometry' AND f->'geometry' IS NOT NULL;

  -- Coleta outras features (que não serão recalculadas)
  SELECT COALESCE(jsonb_agg(f), '[]'::jsonb)
  INTO features_clipped
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) NOT IN (
      'ARL_AVERBADA',
      'ARL_APROVADA_NAO_AVERBADA',
      'ARL_PROPOSTA',
      'ARL_AVERBADA_OUTRO_IMOVEL'
  );

  -------------------------------------------------------------------------
  -- 2) APLICAR PRIORIDADES (Lógica de Sobreposição)
  -------------------------------------------------------------------------

  -- Prioridade 1: ARL_AVERBADA
  IF g_arl_a_4674 IS NOT NULL THEN
    -- Recorta a Área Líquida
    g_arl_a_out := ST_Multi(ST_CollectionExtract(
                    ST_MakeValid(ST_Intersection(g_al_4674, g_arl_a_4674)), 3));

    -- Remove Hidrografia
    IF g_hidrica_4674 IS NOT NULL THEN
      g_arl_a_out := ST_Multi(ST_CollectionExtract(
                      ST_MakeValid(ST_Difference(g_arl_a_out, g_hidrica_4674)), 3));
    END IF;

    -- Buffer de correção topológica em graus
    IF g_arl_a_out IS NOT NULL AND NOT ST_IsEmpty(g_arl_a_out) THEN
      g_arl_a_out := ST_Buffer(ST_Buffer(g_arl_a_out, buffer_epsilon_deg), -buffer_epsilon_deg);
      g_arl_a_out := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_arl_a_out), 3));

      IF g_arl_a_out IS NOT NULL AND NOT ST_IsEmpty(g_arl_a_out) THEN
        -- Calcula área (usando geography)
        area_ha := ST_Area(g_arl_a_out::geography) / 10000.0;

        -- Cria feature de saída
         feature_out := jsonb_build_object(
             'type', 'Feature',
             'geometry', ST_AsGeoJSON(ST_Transform(g_arl_a_out, 4674))::jsonb,
             'properties', jsonb_build_object(
                 'tipo', 'ARL_AVERBADA',
                 'area_ha', round(area_ha, 4)
             )
         );
        features_rl := features_rl || feature_out;

        -- CORREÇÃO V5: Usa ST_Collect ao invés de ST_Union incremental
        -- Acumula na RL_TOTAL
        g_rl_total_4674 := CASE
            WHEN g_rl_total_4674 IS NULL THEN g_arl_a_out
            ELSE ST_Collect(g_rl_total_4674, g_arl_a_out)
        END;
      END IF;
    END IF;
  END IF;

  -- CORREÇÃO V5: Adiciona fallback de ST_UnaryUnion
  -- Acumula ARL_A + Hidrografia para usar na próxima prioridade
  BEGIN
    g_arl_a_hidrico_4674 := ST_UnaryUnion(ST_Union(
        COALESCE(g_arl_a_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
        COALESCE(g_hidrica_4674, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
    ));
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      g_arl_a_hidrico_4674 := ST_UnaryUnion(ST_Buffer(ST_Union(
          COALESCE(g_arl_a_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
          COALESCE(g_hidrica_4674, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
      ), 0));
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;

  -- Prioridade 2: ARL_APROVADA_NAO_AVERBADA
  IF g_arl_ana_4674 IS NOT NULL THEN
    -- Recorta a Área Líquida
    g_arl_ana_out := ST_Multi(ST_CollectionExtract(
                      ST_MakeValid(ST_Intersection(g_al_4674, g_arl_ana_4674)), 3));

    -- Remove ARL_A + Hidrografia
    g_arl_ana_out := ST_Multi(ST_CollectionExtract(
                      ST_MakeValid(ST_Difference(g_arl_ana_out, g_arl_a_hidrico_4674)), 3));

    -- Buffer de correção
    IF g_arl_ana_out IS NOT NULL AND NOT ST_IsEmpty(g_arl_ana_out) THEN
      g_arl_ana_out := ST_Buffer(ST_Buffer(g_arl_ana_out, buffer_epsilon_deg), -buffer_epsilon_deg);
      g_arl_ana_out := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_arl_ana_out), 3));

      IF g_arl_ana_out IS NOT NULL AND NOT ST_IsEmpty(g_arl_ana_out) THEN
        area_ha := ST_Area(g_arl_ana_out::geography) / 10000.0;

         feature_out := jsonb_build_object(
             'type', 'Feature',
             'geometry', ST_AsGeoJSON(ST_Transform(g_arl_ana_out, 4674))::jsonb,
             'properties', jsonb_build_object(
                 'tipo', 'ARL_APROVADA_NAO_AVERBADA',
                 'area_ha', round(area_ha, 4)
             )
         );
        features_rl := features_rl || feature_out;

        -- CORREÇÃO V5: Usa ST_Collect ao invés de ST_Union incremental
        g_rl_total_4674 := CASE
            WHEN g_rl_total_4674 IS NULL THEN g_arl_ana_out
            ELSE ST_Collect(g_rl_total_4674, g_arl_ana_out)
        END;
      END IF;
    END IF;
  END IF;

  -- CORREÇÃO V5: Adiciona fallback de ST_UnaryUnion
  -- Acumula ARL_ANA + ARL_A + Hidrografia para usar na próxima prioridade
  BEGIN
    g_arl_ana_hidrico_4674 := ST_UnaryUnion(ST_Union(
        COALESCE(g_arl_ana_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
        COALESCE(g_arl_a_hidrico_4674, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
    ));
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      g_arl_ana_hidrico_4674 := ST_UnaryUnion(ST_Buffer(ST_Union(
          COALESCE(g_arl_ana_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
          COALESCE(g_arl_a_hidrico_4674, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
      ), 0));
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;

  -- Prioridade 3: ARL_PROPOSTA
  IF g_arl_p_4674 IS NOT NULL THEN
    -- Recorta a Área Líquida
    g_arl_p_out := ST_Multi(ST_CollectionExtract(
                    ST_MakeValid(ST_Intersection(g_al_4674, g_arl_p_4674)), 3));

    -- Remove ARL_ANA + ARL_A + Hidrografia
    g_arl_p_out := ST_Multi(ST_CollectionExtract(
                    ST_MakeValid(ST_Difference(g_arl_p_out, g_arl_ana_hidrico_4674)), 3));

    -- Buffer de correção
    IF g_arl_p_out IS NOT NULL AND NOT ST_IsEmpty(g_arl_p_out) THEN
      g_arl_p_out := ST_Buffer(ST_Buffer(g_arl_p_out, buffer_epsilon_deg), -buffer_epsilon_deg);
      g_arl_p_out := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_arl_p_out), 3));

      IF g_arl_p_out IS NOT NULL AND NOT ST_IsEmpty(g_arl_p_out) THEN
        area_ha := ST_Area(g_arl_p_out::geography) / 10000.0;

         feature_out := jsonb_build_object(
             'type', 'Feature',
             'geometry', ST_AsGeoJSON(ST_Transform(g_arl_p_out, 4674))::jsonb,
             'properties', jsonb_build_object(
                 'tipo', 'ARL_PROPOSTA',
                 'area_ha', round(area_ha, 4)
             )
         );
        features_rl := features_rl || feature_out;

        -- CORREÇÃO V5: Usa ST_Collect ao invés de ST_Union incremental
        g_rl_total_4674 := CASE
            WHEN g_rl_total_4674 IS NULL THEN g_arl_p_out
            ELSE ST_Collect(g_rl_total_4674, g_arl_p_out)
        END;
      END IF;
    END IF;
  END IF;

  -------------------------------------------------------------------------
  -- 3) CRIA ARL_TOTAL
  -- CORREÇÃO V5: Faz ST_UnaryUnion uma vez no final
  -------------------------------------------------------------------------
  IF g_rl_total_4674 IS NOT NULL AND NOT ST_IsEmpty(g_rl_total_4674) THEN
    g_rl_total_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_rl_total_4674), 3));
    
    -- CORREÇÃO V5: Faz ST_UnaryUnion uma vez no final com fallback
    BEGIN
      g_rl_total_4674 := ST_UnaryUnion(g_rl_total_4674);
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        g_rl_total_4674 := ST_UnaryUnion(ST_Buffer(g_rl_total_4674, 0));
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END;
    
    area_ha := ST_Area(g_rl_total_4674::geography) / 10000.0;

     feature_out := jsonb_build_object(
         'type', 'Feature',
         'geometry', ST_AsGeoJSON(ST_Transform(g_rl_total_4674, 4674))::jsonb,
         'properties', jsonb_build_object(
             'tipo', 'ARL_TOTAL',
             'area_ha', round(area_ha, 4)
         )
     );
    features_rl := features_rl || feature_out;
  END IF;

  -------------------------------------------------------------------------
  -- 4) CALCULA ARL_A_RECUPERAR
  -- Intersecção com Área Não Classificada e Área Consolidada
  -------------------------------------------------------------------------
  IF g_rl_total_4674 IS NOT NULL THEN
    g_arl_recuperar_4674 := ST_Multi(ST_CollectionExtract(
                ST_MakeValid(ST_Intersection(
                    g_rl_total_4674,
                    ST_UnaryUnion(ST_Collect(
                        COALESCE(g_anc_4674, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
                        COALESCE(g_ac_4674, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
                    ))
                )), 3));

    IF g_arl_recuperar_4674 IS NOT NULL AND NOT ST_IsEmpty(g_arl_recuperar_4674) THEN
      g_arl_recuperar_4674 := ST_Buffer(ST_Buffer(g_arl_recuperar_4674, buffer_epsilon_deg), -buffer_epsilon_deg);
      g_arl_recuperar_4674 := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_arl_recuperar_4674), 3));

      IF g_arl_recuperar_4674 IS NOT NULL AND NOT ST_IsEmpty(g_arl_recuperar_4674) THEN
        area_ha := ST_Area(g_arl_recuperar_4674::geography) / 10000.0;

         feature_out := jsonb_build_object(
             'type', 'Feature',
             'geometry', ST_AsGeoJSON(ST_Transform(g_arl_recuperar_4674, 4674))::jsonb,
             'properties', jsonb_build_object(
                 'tipo', 'ARL_A_RECUPERAR',
                 'area_ha', round(area_ha, 4)
             )
         );
        features_rl := features_rl || feature_out;
      END IF;
    END IF;
  END IF;

  -------------------------------------------------------------------------
  -- 5) CALCULA ARL_AVERBADA_OUTRO_IMOVEL
  -- Intersecção com ARL_A e ARL_ANA
  -------------------------------------------------------------------------
  IF g_arl_outro_imovel_4674 IS NOT NULL THEN
    g_arl_outro_imovel_out := ST_Multi(ST_CollectionExtract(
                ST_MakeValid(ST_Intersection(
                    g_arl_outro_imovel_4674,
                    ST_UnaryUnion(ST_Collect(
                        COALESCE(g_arl_a_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674)),
                        COALESCE(g_arl_ana_out, ST_GeomFromText('MULTIPOLYGON EMPTY', 4674))
                    ))
                )), 3));

    IF g_arl_outro_imovel_out IS NOT NULL AND NOT ST_IsEmpty(g_arl_outro_imovel_out) THEN
      g_arl_outro_imovel_out := ST_Buffer(ST_Buffer(g_arl_outro_imovel_out, buffer_epsilon_deg), -buffer_epsilon_deg);
      g_arl_outro_imovel_out := ST_Multi(ST_CollectionExtract(ST_MakeValid(g_arl_outro_imovel_out), 3));

      IF g_arl_outro_imovel_out IS NOT NULL AND NOT ST_IsEmpty(g_arl_outro_imovel_out) THEN
        area_ha := ST_Area(g_arl_outro_imovel_out::geography) / 10000.0;

         feature_out := jsonb_build_object(
             'type', 'Feature',
             'geometry', ST_AsGeoJSON(ST_Transform(g_arl_outro_imovel_out, 4674))::jsonb,
             'properties', jsonb_build_object(
                 'tipo', 'ARL_AVERBADA_OUTRO_IMOVEL',
                 'area_ha', round(area_ha, 4)
             )
         );
        features_rl := features_rl || feature_out;
      END IF;
    END IF;
  END IF;

  -------------------------------------------------------------------------
  -- 6) RETORNA RESULTADO
  -------------------------------------------------------------------------
  RETURN jsonb_build_object('type', 'FeatureCollection', 'features', features_clipped || features_rl);

END;
$function$
;

-- DROP FUNCTION geometry_bases.f_calcula_servidao_total_geojson(text);

CREATE OR REPLACE FUNCTION geometry_bases.f_calcula_servidao_total_geojson(input_geojson_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  input_geojson      jsonb := input_geojson_text::jsonb;
  features_all       jsonb := COALESCE(input_geojson->'features','[]'::jsonb);

  -- Geometrias de trabalho (todas em 4674)
  g_ai_4674          geometry := NULL;
  g_union_4674       geometry := NULL;

  -- Saída
  features_clipped   jsonb := '[]'::jsonb;
  features_out       jsonb := '[]'::jsonb;
  feature_out        jsonb;
  
  -- Parâmetros
  buffer_epsilon_deg numeric := 0.000001;  -- ~0.1m em graus
  
  -- Auxiliares
  utm                integer;
  area_ha            numeric;

BEGIN

  -----------------------------------------------------------------------
  -- 1) EXTRAI AREA_IMOVEL E SEPARA SERVIDÕES
  -- Reason: Usa queries ao invés de loops para melhor performance
  -----------------------------------------------------------------------
  
  -- Extrai e normaliza AREA_IMOVEL
  SELECT ST_SnapToGrid(ST_MakeValid(
             ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
         ), 1e-8)
  INTO g_ai_4674
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'AREA_IMOVEL'
  LIMIT 1;

  -- Se não há imóvel, retorna só o que tínhamos
  IF g_ai_4674 IS NULL OR ST_IsEmpty(g_ai_4674) THEN
    RETURN input_geojson;
  END IF;

  -- Coleta features que serão preservadas (não são servidões)
  SELECT COALESCE(jsonb_agg(f), '[]'::jsonb)
  INTO features_clipped
  FROM jsonb_array_elements(features_all) AS f
  WHERE upper(COALESCE(f->'properties'->>'tipo', '')) IN (
      'AREA_IMOVEL',
      'AREA_INFRAESTRUTURA_PUBLICA',
      'AREA_UTILIDADE_PUBLICA',
      'RESERVATORIO_ENERGIA'
  )
  OR upper(COALESCE(f->'properties'->>'tipo', '')) NOT IN (
      'AREA_INFRAESTRUTURA_PUBLICA',
      'AREA_UTILIDADE_PUBLICA',
      'RESERVATORIO_ENERGIA'
  );

  -----------------------------------------------------------------------
  -- 2) PROCESSA SERVIDÕES (exceto RESERVATORIO que tem ENTORNO)
  -- Reason: Query única com jsonb_agg ao invés de loop
  -----------------------------------------------------------------------
  
  -- Processa servidões INFRAESTRUTURA e UTILIDADE (não reservatório)
  WITH servidoes_processadas AS (
    SELECT
      upper(COALESCE(f->'properties'->>'tipo', '')) AS tipo_raw,
      NULLIF(f->'properties'->>'faixa_m', '')::numeric AS faixa_m,
      ST_Intersection(
          g_ai_4674,
          ST_SnapToGrid(ST_MakeValid(
              ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
          ), 1e-8)
      ) AS geom_intersec
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) IN (
        'AREA_INFRAESTRUTURA_PUBLICA',
        'AREA_UTILIDADE_PUBLICA'
    )
      AND ST_Intersects(
          g_ai_4674,
          ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
      )
  ),
  servidoes_validadas AS (
    SELECT
      tipo_raw,
      faixa_m,
      ST_Multi(ST_CollectionExtract(ST_MakeValid(geom_intersec), 3)) AS geom_clean
    FROM servidoes_processadas
    WHERE geom_intersec IS NOT NULL AND NOT ST_IsEmpty(geom_intersec)
  ),
  servidoes_finais AS (
    SELECT
      tipo_raw,
      faixa_m,
      CASE
          WHEN ST_GeometryType(geom_clean) = 'ST_MultiPolygon' 
               AND ST_NumGeometries(geom_clean) = 1 
          THEN ST_GeometryN(geom_clean, 1)
          ELSE geom_clean
      END AS geom_final
    FROM servidoes_validadas
    WHERE geom_clean IS NOT NULL AND NOT ST_IsEmpty(geom_clean)
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
        'type', 'Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(sf.geom_final, 4674))::jsonb,
        'properties', jsonb_build_object(
            'tipo', sf.tipo_raw,
            'area_ha', ROUND((ST_Area(sf.geom_final::geography) / 10000.0)::numeric, 4),
            'faixa_m', sf.faixa_m
        )
    )
  ), '[]'::jsonb)
  INTO features_out
  FROM servidoes_finais sf;

  -----------------------------------------------------------------------
  -- 3) PROCESSA RESERVATORIO_ENERGIA (com ENTORNO)
  -- Reason: Lógica especial para criar buffer de entorno
  -----------------------------------------------------------------------
  
  -- Processa RESERVATORIO_ENERGIA
  WITH reservatrios AS (
    SELECT
      NULLIF(f->'properties'->>'faixa_m', '')::numeric AS faixa_m,
      ST_SnapToGrid(ST_MakeValid(
          ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
      ), 1e-8) AS geom_resv
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'RESERVATORIO_ENERGIA'
      AND ST_Intersects(
          g_ai_4674,
          ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
      )
  ),
  entornos_calculados AS (
    SELECT
      COALESCE(r.faixa_m, 30) AS faixa_m_final,
      ST_Difference(
          ST_Buffer(r.geom_resv, COALESCE(r.faixa_m, 30) / 111111.0),  -- Buffer em graus (~1m = 1°/111111)
          r.geom_resv
      ) AS geom_entorno
    FROM reservatrios r
  ),
  entornos_validados AS (
    SELECT
      faixa_m_final,
      ST_Multi(ST_CollectionExtract(ST_MakeValid(geom_entorno), 3)) AS geom_clean
    FROM entornos_calculados
    WHERE geom_entorno IS NOT NULL AND NOT ST_IsEmpty(geom_entorno)
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
        'type', 'Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(ev.geom_clean, 4674))::jsonb,
        'properties', jsonb_build_object(
            'tipo', 'AREA_ENTORNO_RESERVATORIO_ENERGIA',
            'area_ha', 0,
            'faixa_m', ev.faixa_m_final
        )
    )
  ), '[]'::jsonb)
  INTO feature_out
  FROM entornos_validados ev;
  
  features_out := features_out || COALESCE(feature_out, '[]'::jsonb);

  -----------------------------------------------------------------------
  -- 4) CALCULA SERVIDÃO TOTAL (acumula TODAS)
  -- Reason: Query única com ST_Collect + ST_UnaryUnion
  -----------------------------------------------------------------------
  
  WITH todas_servidoes AS (
    -- Servidões diretas (após intersecção)
    SELECT
      ST_Multi(ST_CollectionExtract(ST_MakeValid(
          ST_Intersection(
              g_ai_4674,
              ST_SnapToGrid(ST_MakeValid(
                  ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
              ), 1e-8)
          )
      ), 3)) AS geom
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) IN (
        'AREA_INFRAESTRUTURA_PUBLICA',
        'AREA_UTILIDADE_PUBLICA'
    )
      AND ST_Intersects(
          g_ai_4674,
          ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
      )
    
    UNION ALL
    
    -- Entornos de reservatório
    SELECT
      ST_Multi(ST_CollectionExtract(ST_MakeValid(
          ST_Difference(
              ST_Buffer(
                  ST_SnapToGrid(ST_MakeValid(
                      ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
                  ), 1e-8),
                  COALESCE(NULLIF(f->'properties'->>'faixa_m', '')::numeric, 30) / 111111.0
              ),
              ST_SnapToGrid(ST_MakeValid(
                  ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
              ), 1e-8)
          )
      ), 3)) AS geom
    FROM jsonb_array_elements(features_all) AS f
    WHERE upper(COALESCE(f->'properties'->>'tipo', '')) = 'RESERVATORIO_ENERGIA'
      AND ST_Intersects(
          g_ai_4674,
          ST_SetSRID(ST_GeomFromGeoJSON(f->>'geometry'), 4674)
      )
  ),
  servidao_union AS (
    SELECT ST_UnaryUnion(ST_Collect(geom)) AS geom_union
    FROM todas_servidoes
    WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
  ),
  servidao_final AS (
    SELECT
      CASE
          WHEN ST_GeometryType(geom_union) = 'ST_MultiPolygon' 
               AND ST_NumGeometries(geom_union) = 1 
          THEN ST_GeometryN(geom_union, 1)
          ELSE geom_union
      END AS geom_final
    FROM servidao_union
    WHERE geom_union IS NOT NULL AND NOT ST_IsEmpty(geom_union)
  )
  SELECT COALESCE(
      jsonb_build_object(
          'type', 'Feature',
          'geometry', ST_AsGeoJSON(ST_Transform(sf.geom_final, 4674))::jsonb,
          'properties', jsonb_build_object(
              'tipo', 'AREA_SERVIDAO_ADMINISTRATIVA_TOTAL',
              'area_ha', ROUND((ST_Area(sf.geom_final::geography) / 10000.0)::numeric, 4)
          )
      ),
      NULL
  )
  INTO feature_out
  FROM servidao_final sf;

  IF feature_out IS NOT NULL THEN
    features_out := features_out || feature_out;
  END IF;

  -----------------------------------------------------------------------
  -- 5) RETORNA RESULTADO
  -----------------------------------------------------------------------
  RETURN jsonb_build_object(
    'type', 'FeatureCollection',
    'features', features_clipped || features_out
  );

END;
$function$
;

-- DROP FUNCTION geometry_bases.f_merge_two_geojson(text, text);

CREATE OR REPLACE FUNCTION geometry_bases.f_merge_two_geojson(geojson_a text, geojson_b text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    jA           jsonb := NULL;
    jB           jsonb := NULL;
    features_out jsonb := '[]'::jsonb;

  a         jsonb := geojson_a::jsonb;
  feats_a     jsonb := COALESCE(a->'features','[]'::jsonb);

  b         jsonb := geojson_b::jsonb;
  feats_b     jsonb := COALESCE(b->'features','[]'::jsonb);
BEGIN

	RETURN jsonb_build_object(
    'type','FeatureCollection',
    'features', feats_a || feats_b
  );
END;
$function$
;


