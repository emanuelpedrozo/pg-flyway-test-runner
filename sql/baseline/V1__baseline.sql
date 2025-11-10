
-- ===================================================================
-- HELPERS
-- ===================================================================

-- FC vazia
CREATE OR REPLACE FUNCTION geometry_bases.f_empty_fc()
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT '{"type":"FeatureCollection","features":[]}'::jsonb;
$$;

-- Anexa novas features a um FC existente
-- DROP FUNCTION geometry_bases.f_append_features(jsonb, jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.f_append_features(p_fc jsonb, p_new_features jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT jsonb_build_object(
    'type','FeatureCollection',
    'features', (p_fc->'features') || (p_new_features->'features')
  );
$function$
;


-- DROP FUNCTION geometry_bases.f_get_layer_geom(jsonb, text, text);

CREATE OR REPLACE FUNCTION geometry_bases.f_get_layer_geom(p_fc jsonb, p_layer text, p_expected_geom text)
 RETURNS geometry
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in int := 4674;
  g_out geometry := NULL;
  f jsonb;
  geom_type text;
  want text := upper(coalesce(p_expected_geom,''));
  layer_want text := upper(coalesce(p_layer,''));
  this_layer text;
  g geometry;
BEGIN
  IF p_fc IS NULL OR p_fc->'features' IS NULL THEN
    RETURN NULL;
  END IF;

  -- PASSO 1: Itera em todas as features
  FOR f IN SELECT * FROM jsonb_array_elements(p_fc->'features') LOOP
    -- Encontra o layer (procurando por 'layerCode' ou 'tipo')
    this_layer := upper(coalesce(f->'properties'->>'layerCode', f->'properties'->>'tipo',''));
    IF this_layer <> layer_want THEN CONTINUE; END IF;

    -- Filtra pelo tipo de geometria esperado (POLYGON, LINESTRING, ou POINT)
    geom_type := upper(coalesce(f->'geometry'->>'type',''));
    IF want = 'POLYGON'    AND geom_type NOT IN ('POLYGON','MULTIPOLYGON') THEN CONTINUE;
    ELSIF want = 'LINESTRING' AND geom_type NOT IN ('LINESTRING','MULTILINESTRING') THEN CONTINUE;
    ELSIF want = 'POINT'      AND geom_type NOT IN ('POINT','MULTIPOINT') THEN CONTINUE; END IF;

    -- Converte a geometria do GeoJSON
    g := ST_SetSRID(ST_GeomFromGeoJSON((f->'geometry')::text), srid_in);

    -- PASSO 2: Agrega (Coleta) todas as geometrias encontradas
    g_out := CASE WHEN g_out IS NULL THEN g ELSE ST_Collect(g_out, g) END;
  END LOOP;

  IF g_out IS NULL THEN RETURN NULL; END IF;

   ---------------------------------------------------------------------------------
  -- PASSO 3: CORREÇÃO
   ---------------------------------------------------------------------------------
  -- Valida, Dissolve (ST_UnaryUnion) e extrai o tipo de geometria correto.
  -- Isso corrige o bug onde ST_Collect criava uma GeometryCollection que
  -- falhava ao tentar dissolver polígonos sobrepostos com ST_Buffer(..., 0).
  
  IF want = 'POLYGON' THEN
      -- 1. Valida a coleção de geometrias
      -- 2. Dissolve (une) todas as geometrias sobrepostas
      -- 3. Extrai apenas os Polígonos (tipo 3) do resultado
      -- 4. Garante que a saída seja um MultiPolygon
      g_out := ST_Multi(
                 ST_CollectionExtract(
                   ST_UnaryUnion(
                     ST_MakeValid(g_out)
                   ), 3
                 )
               );
  
  ELSIF want = 'LINESTRING' THEN
      -- Mesma lógica, mas extrai Linhas (tipo 2)
      g_out := ST_Multi(
                 ST_CollectionExtract(
                   ST_UnaryUnion(
                     ST_MakeValid(g_out)
                   ), 2
                 )
               );
  
  ELSIF want = 'POINT' THEN
      -- Mesma lógica, mas extrai Pontos (tipo 1)
      -- ST_UnaryUnion não é usado para pontos
      g_out := ST_Multi(
                 ST_CollectionExtract(
                   ST_MakeValid(g_out), 1
                 )
               );
  ELSE
      -- Se nenhum tipo específico foi pedido, apenas valida a coleção
      g_out := ST_MakeValid(g_out);
  END IF;

  RETURN g_out;
END;
$function$
;



-- DROP FUNCTION geometry_bases.f_make_feature(text, geometry, jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.f_make_feature(p_layer_code text, p_geom geometry, p_properties jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  -- O SRID do GeoJSON de saída (WGS 84)
  srid_out int := 4326; 
  gjson    jsonb;
BEGIN
  IF p_geom IS NULL THEN
    gjson := NULL;
  ELSE
    -- CORREÇÃO: Transforma a geometria do SRID de trabalho (assumido 4674)
    -- para o SRID padrão do GeoJSON (4326) e remove o 'crs'.
    gjson := ST_AsGeoJSON(ST_Transform(p_geom, srid_out))::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'type','Feature',
    'properties', coalesce(p_properties, '{}'::jsonb) || jsonb_build_object('layerCode', p_layer_code),
    'geometry', gjson
  );
END;
$function$
;



-- DROP FUNCTION geometry_bases.f_fc_append_one(jsonb, jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.f_fc_append_one(p_fc jsonb, p_ft jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
           WHEN p_fc IS NULL OR p_fc->>'type' IS DISTINCT FROM 'FeatureCollection' THEN
             jsonb_build_object('type','FeatureCollection','features', jsonb_build_array(p_ft))
           ELSE
             jsonb_build_object(
               'type','FeatureCollection',
               'features', coalesce(p_fc->'features','[]'::jsonb) || jsonb_build_array(p_ft)
             )
         END;
$function$
;



-- DROP FUNCTION geometry_bases.f_fc_replace_layer(jsonb, text, jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.f_fc_replace_layer(p_fc jsonb, p_layer text, p_new_feature jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  SELECT jsonb_build_object(
    'type','FeatureCollection',
    'features',
      COALESCE((
        SELECT jsonb_agg(f)
        FROM (
          SELECT f
          FROM jsonb_array_elements(p_fc->'features') AS f
          WHERE upper(f->'properties'->>'layerCode') <> upper(p_layer)
        ) s
      ), '[]'::jsonb)
      ||
      CASE WHEN p_new_feature IS NULL
           THEN '[]'::jsonb
           ELSE jsonb_build_array(p_new_feature)
      END
  );
$function$
;





-- ===================================================================
-- FUNÇÃO 1: Rural Property
-- ===================================================================

-- DROP FUNCTION geometry_bases.rural_property(jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.rural_property(p_fc jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  -- srid_in e srid_met não são mais necessários para o cálculo de área
  g_imovel   geometry;
  area_ha    numeric;
  props_orig jsonb := '{}'::jsonb;
  feat_new   jsonb;
BEGIN
  -- 1) Geometria do imóvel (Assumindo que f_get_layer_geom
  --    já agrega (ST_Union) e valida (ST_MakeValid) todas as
  --    features 'RURAL_PROPERTY' e retorna uma geometria única em SRID 4674)
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;  -- nada a fazer
  END IF;

   -- 2) Área total (ha)
  -- CORREÇÃO: Usando 'geography' para cálculo de área universal e preciso,
  -- sem depender de um SRID métrico (UTM) fixo.
  area_ha := round( (ST_Area(g_imovel::geography) / 10000.0)::numeric, 4 );

  -- 3) Trazer as propriedades originais da PRIMEIRA feature encontrada
  SELECT feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = 'RURAL_PROPERTY'
  LIMIT 1;

  -- Adiciona/Sobrescreve as propriedades de área
  props_orig := COALESCE(props_orig, '{}'::jsonb)
                || jsonb_build_object(
                     'area_ha', area_ha,
                     'area',    area_ha
                   );

  -- 4) Criar novo feature (Assumindo que f_make_feature
  --    sabe lidar com a geometria em SRID 4674)
  feat_new := geometry_bases.f_make_feature(
                'RURAL_PROPERTY',
                g_imovel,
                props_orig
              );

  -- 5) Substituir no FC o layer RURAL_PROPERTY pelo validado
  RETURN geometry_bases.f_fc_replace_layer(p_fc, 'RURAL_PROPERTY', feat_new);
END;
$function$
;

-- ===================================================================
-- FUNÇÃO 2: Headquarter (Point)
-- ===================================================================

-- DROP FUNCTION geometry_bases.headquarter(jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.headquarter(p_fc jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;

  g_imovel geometry;
  f jsonb;
  feats_out jsonb := '[]'::jsonb; -- Array de saída

  is_hq boolean;
  g_pt geometry;
  props jsonb;
  new_ft jsonb;
BEGIN
  -- 1) Geometria do imóvel (obrigatória)
  -- CORRETO: Reutiliza a f_get_layer_geom (que já valida e agrega)
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    -- Sem imóvel, não dá pra validar HQ -> retorna o FC original
    RETURN p_fc;
  END IF;

  -- 2) Reconstroi a FeatureCollection filtrando HQ fora do imóvel
  FOR f IN SELECT * FROM jsonb_array_elements(p_fc->'features') LOOP
    is_hq := (upper(f->'properties'->>'layerCode') = 'PROPERTY_HEADQUARTERS');

    IF NOT is_hq THEN
      -- mantém qualquer layer diferente de PROPERTY_HEADQUARTERS
      -- CORREÇÃO: Anexa o elemento 'f' diretamente ao array 'feats_out'
      feats_out := feats_out || f;
      CONTINUE;
    END IF;

    -- É HQ: valida a geometria e testa se está dentro do imóvel
    IF f ? 'geometry' AND (f->'geometry') IS NOT NULL THEN
      g_pt := ST_SetSRID(ST_GeomFromGeoJSON((f->'geometry')::text), srid_in);
    ELSE
      g_pt := NULL;
    END IF;

    IF g_pt IS NULL OR ST_IsEmpty(g_pt) THEN
      CONTINUE; -- ignora HQ inválido
    END IF;

    -- mantém apenas se contido no imóvel
    IF ST_Contains(g_imovel, g_pt) THEN
      
      -- Adiciona a nova propriedade
      props := COALESCE(f->'properties','{}'::jsonb)
               || jsonb_build_object('inside_property', true);

      new_ft := geometry_bases.f_make_feature(
                  'PROPERTY_HEADQUARTERS',
                  g_pt,  -- A geometria em 4674
                  props
                );

      -- CORREÇÃO: Anexa o elemento 'new_ft' diretamente ao array
      feats_out := feats_out || new_ft;
    END IF;
    -- (Se o HQ estiver fora do imóvel, ele é simplesmente ignorado)
    
  END LOOP;

  -- Reconstrói a FeatureCollection com a lista de features filtrada/validada
  RETURN jsonb_build_object('type','FeatureCollection','features',feats_out);
END;
$function$
;


-- ===================================================================
-- FUNÇÃO 3: native_vegetation
-- ===================================================================


-- DROP FUNCTION geometry_bases.native_vegetation(jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.native_vegetation(p_fc jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  -- srid_met e g_nv_clean_m REMOVIDOS - Usaremos 'geography'

  -- imóvel
  g_imovel geometry;

  -- NV
  g_nv_raw     geometry;
  g_nv_clip    geometry;
  g_nv_clean   geometry;
  area_nv_ha   numeric := 0;

  -- recortes "obrigatórios"
  g_river_poly geometry;
  g_lake_poly  geometry;
  g_pub_infra  geometry;
  g_spring_pt  geometry;
  g_river_line geometry;

  src_layer text := NULL;
  props_orig jsonb := '{}'::jsonb;
  feat_new jsonb;
BEGIN
  -- 1) imóvel
  -- CORREÇÃO: f_get_layer_geom já retorna geometria válida e unificada.
  -- A sanitização (ST_Buffer) foi removida.
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;

  -- 2) decidir fonte da NV e capturar suas PROPRIEDADES originais
  g_nv_raw := geometry_bases.f_get_layer_geom(p_fc, 'REMAINING_NATIVE_VEGETATION', 'POLYGON');
  IF g_nv_raw IS NOT NULL AND NOT ST_IsEmpty(g_nv_raw) THEN
    src_layer := 'REMAINING_NATIVE_VEGETATION';
  ELSE
    g_nv_raw := geometry_bases.f_get_layer_geom(p_fc, 'NATIVE_VEGETATION', 'POLYGON');
    IF g_nv_raw IS NOT NULL AND NOT ST_IsEmpty(g_nv_raw) THEN
      src_layer := 'NATIVE_VEGETATION';
    ELSE
      RETURN p_fc; -- não há NV para processar
    END IF;
  END IF;

  -- Captura propriedades originais
  SELECT feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = src_layer
  LIMIT 1;
  props_orig := COALESCE(props_orig, '{}'::jsonb);

  -- 3) recorte obrigatório ao imóvel
  -- CORREÇÃO: g_nv_raw já é válida, ST_Buffer(ST_MakeValid(...)) removido.
  g_nv_clip := ST_Intersection(g_nv_raw, g_imovel);
  IF g_nv_clip IS NULL OR ST_IsEmpty(g_nv_clip) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, src_layer, NULL);
  END IF;

  -- 4) carregar geometrias para recorte
  g_river_poly := geometry_bases.f_get_layer_geom(p_fc, 'RIVER',         'POLYGON');
  g_lake_poly  := geometry_bases.f_get_layer_geom(p_fc, 'LAKE_LAGOON',   'POLYGON');
  g_pub_infra  := geometry_bases.f_get_layer_geom(p_fc, 'PUBLIC_INFRASTRUCTURE', 'POLYGON');
  g_spring_pt  := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_SPRING',  'POINT');
  g_river_line := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M','LINESTRING');

  g_nv_clean := g_nv_clip; -- Começa com a NV clipada pelo imóvel

  -- 4.1) Aplicar recortes (ST_Difference)
  IF g_river_poly IS NOT NULL AND NOT ST_IsEmpty(g_river_poly) THEN
    g_nv_clean := ST_Difference(g_nv_clean, g_river_poly);
  END IF;
  IF g_lake_poly IS NOT NULL AND NOT ST_IsEmpty(g_lake_poly) THEN
    g_nv_clean := ST_Difference(g_nv_clean, g_lake_poly);
  END IF;
  IF g_pub_infra IS NOT NULL AND NOT ST_IsEmpty(g_pub_infra) THEN
    g_nv_clean := ST_Difference(g_nv_clean, g_pub_infra);
  END IF;

  /* -----------------------------------------------------------------
   * CORREÇÃO: Buffers de nascente e rio refeitos usando 'geography'
   * para garantir o cálculo correto em metros, independentemente do UTM.
   * -----------------------------------------------------------------
  */
  IF g_spring_pt IS NOT NULL AND NOT ST_IsEmpty(g_spring_pt) THEN
    g_nv_clean := ST_Difference(
      g_nv_clean,
      -- 1. Converte ponto para geography
      -- 2. Aplica buffer de 50m (em geography)
      -- 3. Converte o resultado de volta para geometry para o ST_Difference
      (ST_Buffer(g_spring_pt::geography, 50))::geometry
    );
  END IF;
  IF g_river_line IS NOT NULL AND NOT ST_IsEmpty(g_river_line) THEN
    g_nv_clean := ST_Difference(
      g_nv_clean,
      -- Mesma lógica, mas com buffer de 1m
      (ST_Buffer(g_river_line::geography, 1))::geometry
    );
  END IF;

  -- 5) saneamento final
  -- CORREÇÃO: O segundo ST_Intersection com g_imovel (linha 98) foi removido por ser redundante.
  IF g_nv_clean IS NULL OR ST_IsEmpty(g_nv_clean) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, src_layer, NULL);
  END IF;

  -- Garante que a geometria final seja válida e dissolvida
  g_nv_clean := ST_Buffer(ST_MakeValid(g_nv_clean), 0);

  /* -----------------------------------------------------------------
   * CORREÇÃO: Cálculo de área refeito usando 'geography'
   * -----------------------------------------------------------------
  */
  area_nv_ha := round((ST_Area(g_nv_clean::geography)/10000.0)::numeric, 4);

  -- 6) substitui o layer original, preservando properties + área
  feat_new := geometry_bases.f_make_feature(
                src_layer,      -- mantém o MESMO layerCode de entrada
                g_nv_clean,     -- geometria final limpa (em 4674)
                props_orig || jsonb_build_object(
                  'area_ha', area_nv_ha,
                  'area',    area_nv_ha
                )
              );
  -- f_make_feature irá converter g_nv_clean de 4674 para 4326 para o GeoJSON final

  RETURN geometry_bases.f_fc_replace_layer(p_fc, src_layer, feat_new);
END;
$function$
;


-- ===================================================================
-- FUNÇÃO 4: consolidated_area
-- ===================================================================

-- DROP FUNCTION geometry_bases.consolidated_area(jsonb, numeric, numeric, numeric);

CREATE OR REPLACE FUNCTION geometry_bases.consolidated_area(p_fc jsonb, p_opt1 numeric DEFAULT 1, p_opt2 numeric DEFAULT 1, p_rl_min_percent numeric DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  -- srid_met e g_agro_clean_m REMOVIDOS - Usaremos 'geography'

  g_imovel geometry;

  -- Agro (entrada/saída)
  g_agro_raw   geometry;
  g_agro_clip  geometry;
  g_agro_clean geometry;
  area_agro_ha numeric := 0;

  -- Camadas para recortes
  g_infra      geometry;
  g_pub_infra  geometry;
  g_river_poly geometry;
  g_lake_poly  geometry;
  g_spring_pt  geometry;
  g_river_line geometry;

  -- Vegetação nativa (prioritária)
  g_nv_raw   geometry;
  g_nv_clip  geometry;
  g_nv_union geometry; -- Esta variável agora é 'g_nv_clip'

  -- Propriedades originais a preservar
  props_orig jsonb := '{}'::jsonb;
  feat_new   jsonb;
BEGIN
  -- 1) Imóvel
  -- CORREÇÃO: f_get_layer_geom já retorna geometria válida e unificada.
  -- A sanitização (ST_Buffer) foi removida.
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;

  -- 2) Guardar as PROPRIEDADES ORIGINAIS
  SELECT feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = 'CONSOLIDATED_AREA'
  LIMIT 1;
  props_orig := COALESCE(props_orig, '{}'::jsonb);

  -- 3) Agro original
  g_agro_raw := geometry_bases.f_get_layer_geom(p_fc, 'CONSOLIDATED_AREA', 'POLYGON');
  IF g_agro_raw IS NULL OR ST_IsEmpty(g_agro_raw) THEN
    RETURN p_fc;
  END IF;

  -- 4) Recorte obrigatório ao imóvel
  -- CORREÇÃO: g_agro_raw já é válida, ST_Buffer(ST_MakeValid(...)) removido.
  g_agro_clip := ST_Intersection(g_agro_raw, g_imovel);
  IF g_agro_clip IS NULL OR ST_IsEmpty(g_agro_clip) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'CONSOLIDATED_AREA', NULL);
  END IF;

  -- 5) Vegetação nativa (prioritária) → retira da Agro
  g_nv_raw := geometry_bases.f_get_layer_geom(p_fc, 'REMAINING_NATIVE_VEGETATION', 'POLYGON');
  IF g_nv_raw IS NULL OR ST_IsEmpty(g_nv_raw) THEN
    g_nv_raw := geometry_bases.f_get_layer_geom(p_fc, 'NATIVE_VEGETATION', 'POLYGON');
  END IF;

  g_agro_clean := g_agro_clip; -- Começa com a área consolidada já clipada

  IF g_nv_raw IS NOT NULL AND NOT ST_IsEmpty(g_nv_raw) THEN
    -- CORREÇÃO: Lógica simplificada. g_nv_raw já é válida e unificada.
    -- g_nv_union agora é apenas a NV clipada pelo imóvel.
    g_nv_union := ST_Intersection(g_nv_raw, g_imovel);
    
    IF g_nv_union IS NOT NULL AND NOT ST_IsEmpty(g_nv_union) THEN
      g_agro_clean := ST_Difference(g_agro_clean, g_nv_union);
    END IF;
  END IF;

  -- 6) Demais recortes (rios, lagos, infra…)
  g_infra      := geometry_bases.f_get_layer_geom(p_fc, 'PROPERTY_INFRASTRUCTURE', 'POLYGON');
  g_pub_infra  := geometry_bases.f_get_layer_geom(p_fc, 'PUBLIC_INFRASTRUCTURE',   'POLYGON');
  g_river_poly := geometry_bases.f_get_layer_geom(p_fc, 'RIVER',                   'POLYGON');
  g_lake_poly  := geometry_bases.f_get_layer_geom(p_fc, 'LAKE_LAGOON',             'POLYGON');
  g_spring_pt  := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_SPRING',            'POINT');
  g_river_line := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M',         'LINESTRING');

  IF g_infra IS NOT NULL AND NOT ST_IsEmpty(g_infra) THEN
    g_agro_clean := ST_Difference(g_agro_clean, g_infra);
  END IF;
  IF g_pub_infra IS NOT NULL AND NOT ST_IsEmpty(g_pub_infra) THEN
    g_agro_clean := ST_Difference(g_agro_clean, g_pub_infra);
  END IF;
  IF g_river_poly IS NOT NULL AND NOT ST_IsEmpty(g_river_poly) THEN
    g_agro_clean := ST_Difference(g_agro_clean, g_river_poly);
  END IF;
  IF g_lake_poly IS NOT NULL AND NOT ST_IsEmpty(g_lake_poly) THEN
    g_agro_clean := ST_Difference(g_agro_clean, g_lake_poly);
  END IF;

  IF g_spring_pt IS NOT NULL AND NOT ST_IsEmpty(g_spring_pt) THEN
    g_agro_clean := ST_Difference(
      g_agro_clean,
      (ST_Buffer(g_spring_pt::geography, 1))::geometry -- Buffer de 1m
    );
  END IF;
  IF g_river_line IS NOT NULL AND NOT ST_IsEmpty(g_river_line) THEN
    g_agro_clean := ST_Difference(
      g_agro_clean,
      (ST_Buffer(g_river_line::geography, 1))::geometry -- Buffer de 1m
    );
  END IF;

  -- 7) Reforço de recorte + consolidação
  -- CORREÇÃO: Recorte duplo (ST_Intersection) removido por ser redundante.
  IF g_agro_clean IS NULL OR ST_IsEmpty(g_agro_clean) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'CONSOLIDATED_AREA', NULL);
  END IF;

  -- Aplica uma limpeza final. (ST_Union é redundante, mas ST_Buffer(ST_MakeValid) é bom)
  g_agro_clean   := ST_Buffer(ST_MakeValid(g_agro_clean), 0);
  
  -- CORREÇÃO: Cálculo de área refeito usando 'geography'
  area_agro_ha   := round( (ST_Area(g_agro_clean::geography) / 10000.0)::numeric, 4 );

  -- 8) Substitui o layer mantendo as properties originais + área (ha)
  feat_new := geometry_bases.f_make_feature(
                'CONSOLIDATED_AREA',
                g_agro_clean,
                props_orig || jsonb_build_object(
                  'area_ha', area_agro_ha,
                  'area',    area_agro_ha
                )
              );

  RETURN geometry_bases.f_fc_replace_layer(p_fc, 'CONSOLIDATED_AREA', feat_new);
END;
$function$
;


-- ===================================================================
-- FUNÇÃO 5: rivers_up_to_10m
-- ===================================================================


-- DROP FUNCTION geometry_bases.rivers_up_to_10m(jsonb, numeric, numeric);

CREATE OR REPLACE FUNCTION geometry_bases.rivers_up_to_10m(p_fc jsonb, p_capture_m numeric DEFAULT NULL::numeric, p_stream_width_m numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  srid_met int := 31983;

  g_prop   geometry;
  g_prop_m geometry;

  g_line_raw geometry;
  g_line_m   geometry;

  feat_new jsonb;
  props_orig jsonb := '{}'::jsonb;
BEGIN
  -- imóvel
  g_prop := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_prop IS NULL OR ST_IsEmpty(g_prop) THEN
    RETURN p_fc;
  END IF;
  g_prop   := ST_Buffer(ST_MakeValid(g_prop), 0);
  g_prop_m := ST_Transform(g_prop, srid_met);

  -- manter props
  SELECT feat->'properties' INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = 'RIVER_UP_TO_10M'
  LIMIT 1;
  props_orig := COALESCE(props_orig, '{}'::jsonb);

  -- fonte linear
  g_line_raw := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M', 'LINESTRING');
  IF g_line_raw IS NULL OR ST_IsEmpty(g_line_raw) THEN
    g_line_raw := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'LINESTRING');
  END IF;
  IF g_line_raw IS NULL OR ST_IsEmpty(g_line_raw) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'RIVER_UP_TO_10M', NULL);
  END IF;

  g_line_m := ST_Transform(ST_MakeValid(g_line_raw), srid_met);

  -- (opcional) filtrar por proximidade ao imóvel
  IF p_capture_m IS NOT NULL THEN
    g_line_m := ST_Intersection(g_line_m, ST_Buffer(g_prop_m, p_capture_m));
    IF g_line_m IS NULL OR ST_IsEmpty(g_line_m) THEN
      RETURN geometry_bases.f_fc_replace_layer(p_fc, 'RIVER_UP_TO_10M', NULL);
    END IF;
  END IF;

  feat_new := geometry_bases.f_make_feature(
               'RIVER_UP_TO_10M',
               ST_Transform(ST_LineMerge(ST_UnaryUnion(g_line_m)), srid_in),
               props_orig || jsonb_build_object('capture_m', p_capture_m)
             );

  RETURN geometry_bases.f_fc_replace_layer(p_fc, 'RIVER_UP_TO_10M', feat_new);
END;
$function$
;



-- ===================================================================
-- FUNÇÃO 6: rivers_wider_than_10m
-- ===================================================================


-- DROP FUNCTION geometry_bases.rivers_wider_than_10m(jsonb, numeric);

CREATE OR REPLACE FUNCTION geometry_bases.rivers_wider_than_10m(p_fc jsonb, p_max_distance_m numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  g_imovel   geometry;
  g_river_poly     geometry;
  g_river_poly_alt geometry;
  src_layer  text := NULL;
  g_source   geometry; 
  g_near     geometry; 
  g_final    geometry; 
  area_ha numeric := 0;
  props_orig jsonb := '{}'::jsonb;  
  feat_new   jsonb; 


BEGIN
  -- 1) Carrega o Imóvel
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;

  -- 2) Identifica a fonte do Rio
  g_river_poly     := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'POLYGON');
  g_river_poly_alt := geometry_bases.f_get_layer_geom(p_fc, 'RIVER',               'POLYGON');

  IF g_river_poly IS NOT NULL AND NOT ST_IsEmpty(g_river_poly) THEN
    src_layer := 'RIVER_WIDER_THAN_10M';
    g_source  := g_river_poly;
  ELSIF g_river_poly_alt IS NOT NULL AND NOT ST_IsEmpty(g_river_poly_alt) THEN
    src_layer := 'RIVER';
    g_source  := g_river_poly_alt;
  ELSE
    RETURN p_fc; -- Nenhum rio poligonal encontrado
  END IF;

  -- 3) Captura propriedades originais
  SELECT feat->'properties' INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = src_layer
  LIMIT 1;
  props_orig := COALESCE(props_orig, '{}'::jsonb);

  -- 4) (Opcional) Filtra rios próximos ao imóvel
  IF p_max_distance_m IS NOT NULL THEN
    g_near := ST_Intersection(
                g_source, 
                (ST_Buffer(g_imovel::geography, p_max_distance_m))::geometry
              );
              
    IF g_near IS NULL OR ST_IsEmpty(g_near) THEN
      RETURN geometry_bases.f_fc_replace_layer(p_fc, src_layer, NULL);
    END IF;
  ELSE
    g_near := g_source; -- Usa todos os rios
  END IF;

  -- 5) LÓGICA ALTERADA (NÃO RECORTA MAIS PELO IMÓVEL)
  g_final := g_near;
  
  IF g_final IS NULL OR ST_IsEmpty(g_final) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, src_layer, NULL);
  END IF;

  -- 6) Saneamento final e cálculo de área
  g_final := ST_Buffer(ST_MakeValid(g_final), 0); 
  area_ha := round((ST_Area(g_final::geography)/10000.0)::numeric, 4);

  -- 7) Cria a nova feature
  feat_new := geometry_bases.f_make_feature(
               src_layer,
               g_final, 
               props_orig || jsonb_build_object(
                 'area_ha', area_ha,
                 'area',    area_ha,
                 'source_layer', src_layer,
                 'max_distance_filter_m', p_max_distance_m
               )
             );

  RETURN geometry_bases.f_fc_replace_layer(p_fc, src_layer, feat_new);
END;
$function$
;



-- ===================================================================
-- FUNÇÃO 7: legal_reserve
-- ===================================================================

-- DROP FUNCTION geometry_bases.legal_reserve(jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.legal_reserve(p_fc jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;

  -- parâmetros fixos
  min_rl_percent numeric := 50;
  exclude_app boolean := false;  -- NÃO cortar por APP

  -- imóvel
  g_imovel geometry;

  -- RL
  g_rl_input geometry;
  g_rl_sel geometry;     -- 4674

  -- Hidrografia p/ recorte da RL (NÃO usar PPA)
  g_river_poly geometry;        -- RIVER (ou WIDER)
  g_river_poly_alt geometry;    -- fallback
  g_river_final geometry;       -- união final (4674)
  g_lake_poly geometry;         -- LAKE_LAGOON
  g_river_u10 geometry;         -- RIVER_UP_TO_10M (LINESTRING)

  -- Vegetação nativa (apenas métricas, sem cortar RL)
  g_nv_input geometry;
  g_nv_in_rl geometry; -- Geometria de intersecção (em 4674)

  -- métricas
  area_imovel_m2 numeric := 0;
  area_req_m2    numeric := 0;
  area_sel_m2    numeric := 0;
  area_nv_rl_m2  numeric := 0;

  required_ha  numeric := 0;
  selected_ha  numeric := 0;
  nativa_ha    numeric := 0;
  deficit_ha   numeric := 0;
  meets_minimum boolean := false;

  props_orig jsonb := '{}'::jsonb;
  feat_new jsonb;
BEGIN
  -- 1) Imóvel
  -- CORREÇÃO: f_get_layer_geom já valida e une. ST_Buffer(ST_MakeValid) removido.
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;

  -- 2) Área mínima exigida
  -- CORREÇÃO: Cálculo de área usando 'geography' para precisão universal.
  area_imovel_m2 := ST_Area(g_imovel::geography);
  area_req_m2    := area_imovel_m2 * (min_rl_percent / 100.0);
  required_ha    := round((area_req_m2/10000.0)::numeric, 4);

  -- 3) RL declarada
  g_rl_input := geometry_bases.f_get_layer_geom(p_fc, 'LEGAL_RESERVE', 'POLYGON');
  IF g_rl_input IS NULL OR ST_IsEmpty(g_rl_input) THEN
    RETURN p_fc;
  END IF;

  -- 4) Recorte obrigatório ao imóvel
  -- CORREÇÃO: ST_Buffer(ST_MakeValid) removido por ser redundante.
  g_rl_sel := ST_Intersection(g_rl_input, g_imovel);
  IF g_rl_sel IS NULL OR ST_IsEmpty(g_rl_sel) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'LEGAL_RESERVE', NULL);
  END IF;

  -- 6) Cortar RL pela HIDROGRAFIA
  -- 6.1) RIO poligonal
  g_river_poly     := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'POLYGON');
  IF g_river_poly IS NULL OR ST_IsEmpty(g_river_poly) THEN
    g_river_poly_alt := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'POLYGON');
    IF g_river_poly_alt IS NOT NULL AND NOT ST_IsEmpty(g_river_poly_alt) THEN
      g_river_poly := g_river_poly_alt;
    END IF;
  END IF;

  IF g_river_poly IS NOT NULL AND NOT ST_IsEmpty(g_river_poly) THEN
    -- CORREÇÃO: g_river_poly já vem unificado de f_get_layer_geom.
    g_river_final := g_river_poly;
    g_rl_sel := ST_Difference(g_rl_sel, g_river_final);
  END IF;

  -- 6.2) LAGO/LAGOA poligonal
  g_lake_poly := geometry_bases.f_get_layer_geom(p_fc, 'LAKE_LAGOON', 'POLYGON');
  IF g_lake_poly IS NOT NULL AND NOT ST_IsEmpty(g_lake_poly) THEN
    -- CORREÇÃO: ST_Buffer(ST_MakeValid) removido.
    g_rl_sel := ST_Difference(g_rl_sel, g_lake_poly);
  END IF;

  -- 6.3) RIO ATÉ 10 m (linhas) → remover "fio d'água"
  g_river_u10 := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M', 'LINESTRING');
  IF g_river_u10 IS NOT NULL AND NOT ST_IsEmpty(g_river_u10) THEN

    g_rl_sel := ST_Difference(
                  g_rl_sel,
                  (ST_Buffer(g_river_u10::geography, 1.0))::geometry  -- Buffer de 1m
                );
  END IF;

  -- Se esvaziou após os cortes, remove layer
  IF g_rl_sel IS NULL OR ST_IsEmpty(g_rl_sel) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'LEGAL_RESERVE', NULL);
  END IF;

  -- 7) Consolidar geometria final da RL
  -- CORREÇÃO: Removido o ST_Intersection(..., g_imovel) redundante.
  -- ST_Union é necessário caso ST_Difference tenha dividido a RL em múltiplos polígonos.
  g_rl_sel   := ST_Buffer(ST_MakeValid(ST_Union(g_rl_sel)), 0);

  -- 8) Métricas recalculadas após cortes
  -- CORREÇÃO: Cálculo de área usando 'geography'
  area_sel_m2 := ST_Area(g_rl_sel::geography);
  selected_ha := round((area_sel_m2/10000.0)::numeric, 4);

  -- NV × RL: **NÃO** cortamos RL por NV. Apenas medimos a interseção.
  g_nv_input := geometry_bases.f_get_layer_geom(p_fc, 'REMAINING_NATIVE_VEGETATION', 'POLYGON');
  IF g_nv_input IS NULL OR ST_IsEmpty(g_nv_input) THEN
    g_nv_input := geometry_bases.f_get_layer_geom(p_fc, 'NATIVE_VEGETATION', 'POLYGON');
  END IF;

  IF g_nv_input IS NOT NULL AND NOT ST_IsEmpty(g_nv_input) THEN
    -- CORREÇÃO: Lógica de interseção e área simplificada e corrigida.
    g_nv_in_rl := ST_Intersection(g_nv_input, g_rl_sel);
    area_nv_rl_m2 := COALESCE(ST_Area(g_nv_in_rl::geography), 0);
    nativa_ha     := round((area_nv_rl_m2/10000.0)::numeric, 4);
  ELSE
    nativa_ha := 0;
  END IF;

  deficit_ha    := GREATEST(required_ha - selected_ha, 0);
  meets_minimum := (selected_ha >= required_ha);

  -- 9) Propriedades originais + métricas
  SELECT feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') feat
  WHERE upper(feat->'properties'->>'layerCode') = 'LEGAL_RESERVE'
  LIMIT 1;

  props_orig := COALESCE(props_orig,'{}'::jsonb) ||
                jsonb_build_object(
                  'required_ha',   required_ha,
                  'selected_ha',   selected_ha,
                  'nativa_ha',     nativa_ha,
                  'deficit_ha',    deficit_ha,
                  'meets_minimum', meets_minimum,
                  'area_ha',       selected_ha
                );

  -- 10) Substituir o layer
  feat_new := geometry_bases.f_make_feature(
                'LEGAL_RESERVE',
                g_rl_sel, -- Geometria final em 4674 (f_make_feature converte para 4326)
                props_orig
              );

  RETURN geometry_bases.f_fc_replace_layer(p_fc, 'LEGAL_RESERVE', feat_new);
END;
$function$
;


-- ===================================================================
-- FUNÇÃO 8: ppa_up_to_10m
-- ===================================================================

-- DROP FUNCTION geometry_bases.ppa_up_to_10m(jsonb, numeric, numeric);

CREATE OR REPLACE FUNCTION geometry_bases.ppa_up_to_10m(p_fc jsonb, p_buffer_m numeric DEFAULT 30, p_capture_m numeric DEFAULT 80)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  g_prop      geometry;
  g_lines     geometry;
  g_ppa       geometry;
  g_ppa_final geometry;
  
  -- Geometrias para recorte
  g_clip_hydro_polys  geometry; -- "Buraco" 1: Rios/Lagos
  g_clip_ppa_priority geometry; -- "Buraco" 2: APP Prioritária (calculada)

  -- Variáveis para recalcular a PPA prioritária
  g_river_poly_source geometry;
  p_buffer_m_wider numeric := 50; -- Buffer padrão da PPA WIDER

  area_ha numeric := 0;
  props_orig jsonb := '{}'::jsonb;
BEGIN
  g_prop := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_prop IS NULL OR ST_IsEmpty(g_prop) THEN RETURN p_fc; END IF;

  SELECT it.feat->'properties' INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS it(feat)
  WHERE upper(it.feat->'properties'->>'layerCode') = 'PPA_UP_TO_10M'
  LIMIT 1;
  props_orig := COALESCE(props_orig, '{}'::jsonb);

  g_lines := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M', 'LINESTRING');
  IF g_lines IS NULL OR ST_IsEmpty(g_lines) THEN
    g_lines := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'LINESTRING');
  END IF;
  IF g_lines IS NULL OR ST_IsEmpty(g_lines) THEN RETURN p_fc; END IF;

  IF p_capture_m IS NOT NULL THEN
    IF NOT ST_DWithin(g_lines::geography, g_prop::geography, p_capture_m) THEN
      RETURN p_fc;
    END IF;
  END IF;

  -- PASSO 1: Carrega e HIGIENIZA os "buracos"
  
  -- Buraco 1: Massas de água (Rios, Lagos)
  g_clip_hydro_polys := ST_Union(
      geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'POLYGON'),
      geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'POLYGON')
  );
  g_clip_hydro_polys := ST_Union(
      g_clip_hydro_polys,
      geometry_bases.f_get_layer_geom(p_fc, 'LAKE_LAGOON', 'POLYGON')
  );
  
  IF g_clip_hydro_polys IS NOT NULL THEN
      g_clip_hydro_polys := ST_Buffer(ST_MakeValid(g_clip_hydro_polys), 0);
  END IF;

  -- Buraco 2: RECALCULA a PPA prioritária
  g_river_poly_source := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'POLYGON');
  IF g_river_poly_source IS NULL OR ST_IsEmpty(g_river_poly_source) THEN
    g_river_poly_source := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'POLYGON');
  END IF;

  IF g_river_poly_source IS NOT NULL AND NOT ST_IsEmpty(g_river_poly_source) THEN
      -- 1. Cria o buffer (polígono maior)
      g_clip_ppa_priority := (ST_Buffer(
                               g_river_poly_source::geography,
                               p_buffer_m_wider,
                               'endcap=flat join=mitre mitre_limit=5.0'
                             ))::geometry;
                             
      -- 2. Higieniza o buffer
      g_clip_ppa_priority := ST_Buffer(ST_MakeValid(g_clip_ppa_priority), 0);
      
      -- 3. Subtrai o "furo" (rios/lagos) para criar o "donut"
      IF g_clip_hydro_polys IS NOT NULL THEN
        g_clip_ppa_priority := ST_Difference(g_clip_ppa_priority, g_clip_hydro_polys);
      END IF;
  END IF;


  -- PASSO 2: Calcula e HIGIENIZA o Buffer da PPA Fina
  g_ppa := (ST_Buffer(
             ST_LineMerge(ST_UnaryUnion(g_lines))::geography,
             p_buffer_m,
             'endcap=flat join=mitre mitre_limit=5.0'
           ))::geometry;
           
  g_ppa := ST_Buffer(ST_MakeValid(g_ppa), 0);


  -- PASSO 3: Aplica os recortes (ST_Difference) em ETAPAS
  
  -- Etapa 1: Subtrai o "furo" (rios/lagos)
  IF g_clip_hydro_polys IS NOT NULL AND NOT ST_IsEmpty(g_clip_hydro_polys) THEN
      g_ppa := ST_Difference(g_ppa, g_clip_hydro_polys);
  END IF;
  
  -- Etapa 2: Subtrai a "hierarquia" (PPA maior, recalculada)
  IF g_clip_ppa_priority IS NOT NULL AND NOT ST_IsEmpty(g_clip_ppa_priority) THEN
      g_ppa := ST_Difference(
                 ST_Buffer(ST_MakeValid(g_ppa), 0), -- Higieniza o resultado da Etapa 1
                 g_clip_ppa_priority -- Já foi higienizado ao ser criado
               );
  END IF;

  -- PASSO 4: Recorte final ao imóvel
  g_ppa_final := ST_Intersection(g_ppa, g_prop);
  IF g_ppa_final IS NULL OR ST_IsEmpty(g_ppa_final) THEN RETURN p_fc; END IF;
  
  g_ppa_final := ST_Buffer(ST_MakeValid(g_ppa_final), 0);
  area_ha := round((ST_Area(g_ppa_final::geography)/10000.0)::numeric, 4);

  -- PASSO 5: Retorno
  RETURN geometry_bases.f_fc_replace_layer(
           p_fc,
           'PPA_UP_TO_10M',
           geometry_bases.f_make_feature(
             'PPA_UP_TO_10M',
             g_ppa_final,
             props_orig || jsonb_build_object('area_ha', area_ha, 'area', area_ha, 'buffer_m', p_buffer_m)
           )
         );
END;
$function$
;


-- ===================================================================
-- FUNÇÃO 9: ppa_wider_than_10m
-- ===================================================================


-- DROP FUNCTION geometry_bases.ppa_wider_than_10m(jsonb, numeric, numeric);

CREATE OR REPLACE FUNCTION geometry_bases.ppa_wider_than_10m(p_fc jsonb, p_buffer_m numeric DEFAULT 50, p_capture_m numeric DEFAULT 80)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  g_prop      geometry;
  g_river     geometry;
  g_ppa       geometry;
  g_ppa_final geometry;
  
  -- Geometrias para recorte
  g_clip_hydro  geometry; -- União de rios/lagos

  area_ha numeric := 0;
  props_orig jsonb := '{}'::jsonb;
BEGIN
  g_prop := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_prop IS NULL OR ST_IsEmpty(g_prop) THEN RETURN p_fc; END IF;

  SELECT it.feat->'properties' INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS it(feat)
  WHERE upper(it.feat->'properties'->>'layerCode') = 'PPA_WIDER_THAN_10M'
  LIMIT 1;
  props_orig := COALESCE(props_orig, '{}'::jsonb);

  g_river := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'POLYGON');
  IF g_river IS NULL OR ST_IsEmpty(g_river) THEN
    g_river := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'POLYGON');
  END IF;
  IF g_river IS NULL OR ST_IsEmpty(g_river) THEN RETURN p_fc; END IF;

  -- PASSO 1: Carrega geometrias de recorte (Massas d'água)
  g_clip_hydro := ST_Union(
                      g_river, -- O próprio rio que está sendo bufferizado
                      geometry_bases.f_get_layer_geom(p_fc, 'LAKE_LAGOON', 'POLYGON')
                  );

  -- *** CORREÇÃO: Higieniza a geometria do "buraco" (g_clip_hydro) ***
  IF g_clip_hydro IS NOT NULL AND NOT ST_IsEmpty(g_clip_hydro) THEN
      g_clip_hydro := ST_Buffer(ST_MakeValid(g_clip_hydro), 0);
  ELSE
      g_clip_hydro := g_river; -- Fallback
  END IF;


  -- PASSO 2: Calcula o Buffer da APP (baseado no POLÍGONO)
  g_ppa := (ST_Buffer(
              g_river::geography, -- Buffer no polígono
              p_buffer_m,
              'endcap=flat join=mitre mitre_limit=5.0'
           ))::geometry;
           
  g_ppa := ST_Buffer(ST_MakeValid(g_ppa), 0);


  -- PASSO 3: Aplica os recortes (ST_Difference)
  -- Ambas as geometrias estão higienizadas, a subtração vai funcionar.
  g_ppa := ST_Difference(g_ppa, g_clip_hydro); -- Remove a água

  -- PASSO 4: Recorte final ao imóvel
  g_ppa_final := ST_Intersection(g_ppa, g_prop);
  IF g_ppa_final IS NULL OR ST_IsEmpty(g_ppa_final) THEN RETURN p_fc; END IF;

  g_ppa_final := ST_Buffer(ST_MakeValid(g_ppa_final), 0);
  area_ha := round((ST_Area(g_ppa_final::geography)/10000.0)::numeric, 4);

  RETURN geometry_bases.f_fc_replace_layer(
           p_fc,
           'PPA_WIDER_THAN_10M',
           geometry_bases.f_make_feature(
             'PPA_WIDER_THAN_10M',
             g_ppa_final,
             props_orig || jsonb_build_object('area_ha', area_ha, 'area', area_ha, 'buffer_m', p_buffer_m)
           )
         );
END;
$function$
;
