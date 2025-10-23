
-- ===================================================================
-- SCHEMA: geometry_bases
-- ===================================================================
CREATE SCHEMA IF NOT EXISTS geometry_bases;
SET search_path = geometry_bases, public;

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

  FOR f IN SELECT * FROM jsonb_array_elements(p_fc->'features') LOOP
    this_layer := upper(coalesce(f->'properties'->>'layerCode', f->'properties'->>'tipo',''));
    IF this_layer <> layer_want THEN CONTINUE; END IF;

    geom_type := upper(coalesce(f->'geometry'->>'type',''));
    IF want = 'POLYGON'    AND geom_type NOT IN ('POLYGON','MULTIPOLYGON') THEN CONTINUE;
    ELSIF want = 'LINESTRING' AND geom_type NOT IN ('LINESTRING','MULTILINESTRING') THEN CONTINUE;
    ELSIF want = 'POINT'      AND geom_type NOT IN ('POINT','MULTIPOINT') THEN CONTINUE; END IF;

    g := ST_SetSRID(ST_GeomFromGeoJSON((f->'geometry')::text), srid_in);

    g_out := CASE WHEN g_out IS NULL THEN g ELSE ST_Collect(g_out, g) END;
  END LOOP;

  IF g_out IS NULL THEN RETURN NULL; END IF;

  IF GeometryType(g_out) IN ('POLYGON','MULTIPOLYGON') THEN
    g_out := ST_Buffer(ST_MakeValid(g_out), 0);
  ELSE
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
  srid_in int := 4674;
  gjson  jsonb;
  gjson_with_crs jsonb;
BEGIN
  IF p_geom IS NULL THEN
    gjson_with_crs := NULL;
  ELSE
    gjson := ST_AsGeoJSON(ST_SetSRID(p_geom, srid_in))::jsonb;
    gjson_with_crs := gjson || jsonb_build_object(
      'crs', jsonb_build_object(
        'type','name',
        'properties', jsonb_build_object('name', 'EPSG:'||srid_in::text)
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'type','Feature',
    'properties', coalesce(p_properties, '{}'::jsonb) || jsonb_build_object('layerCode', p_layer_code),
    'geometry', gjson_with_crs
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
  srid_in  int := 4674;
  srid_met int := 31983;

  g_imovel   geometry;
  g_imovel_m geometry;

  area_ha    numeric;

  props_orig jsonb := '{}'::jsonb;
  feat_new   jsonb;
BEGIN
  -- 1) Geometria do imóvel
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;  -- nada a fazer
  END IF;

  -- 2) Sanitizar
  g_imovel   := ST_Buffer(ST_MakeValid(g_imovel), 0);
  g_imovel_m := ST_Transform(g_imovel, srid_met);

  -- 3) Área total (ha)
  area_ha := round( (ST_Area(g_imovel_m) / 10000.0)::numeric, 4 );

  -- 4) Trazer as propriedades originais do feature (para manter estilo, etc.)
  SELECT feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = 'RURAL_PROPERTY'
  LIMIT 1;

  props_orig := COALESCE(props_orig, '{}'::jsonb)
                || jsonb_build_object(
                     'area_ha', area_ha,
                     'area',    area_ha  -- chave extra (compatibilidade)
                   );

  -- 5) Criar novo feature com MESMO layerCode = "RURAL_PROPERTY"
  feat_new := geometry_bases.f_make_feature(
                'RURAL_PROPERTY',
                g_imovel,
                props_orig
              );

  -- 6) Substituir no FC o layer RURAL_PROPERTY pelo validado
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
  feats_out jsonb := '[]'::jsonb;

  is_hq boolean;
  g_pt geometry;
  props jsonb;
  new_ft jsonb;
BEGIN
  -- 1) Geometria do imóvel (obrigatória)
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
      feats_out := feats_out || jsonb_build_array(f);
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
      props := COALESCE(f->'properties','{}'::jsonb)
               || jsonb_build_object('inside_property', true);

      -- recria o feature com a mesma layerCode e propriedades originais
      new_ft := jsonb_build_object(
                  'type','Feature',
                  'properties', props,
                  'geometry', ST_AsGeoJSON(g_pt)::jsonb
                );

      feats_out := feats_out || jsonb_build_array(new_ft);
    END IF;
  END LOOP;

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
  srid_met int := 31983;

  -- imóvel
  g_imovel geometry;

  -- NV
  g_nv_raw     geometry;
  g_nv_clip    geometry;
  g_nv_clean   geometry;
  g_nv_clean_m geometry;
  area_nv_ha   numeric := 0;

  -- recortes "obrigatórios"
  g_river_poly geometry;
  g_lake_poly  geometry;
  g_pub_infra  geometry;
  g_spring_pt  geometry;
  g_river_line geometry;

  -- qual layer vamos preservar (preferência por REMAINING_NATIVE_VEGETATION)
  src_layer text := NULL;

  -- manter exatamente as properties originais
  props_orig jsonb := '{}'::jsonb;

  feat_new jsonb;
BEGIN
  -- 1) imóvel
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;
  g_imovel := ST_Buffer(ST_MakeValid(g_imovel), 0);

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

  SELECT feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = src_layer
  LIMIT 1;

  props_orig := COALESCE(props_orig, '{}'::jsonb);

  -- 3) recorte obrigatório ao imóvel (prioridade NV → não recorta por Agro)
  g_nv_clip := ST_Intersection(ST_Buffer(ST_MakeValid(g_nv_raw),0), g_imovel);
  IF g_nv_clip IS NULL OR ST_IsEmpty(g_nv_clip) THEN
    -- nenhuma NV dentro do imóvel → remove layer
    RETURN geometry_bases.f_fc_replace_layer(p_fc, src_layer, NULL);
  END IF;

  -- 4) recortes por rio/lago/infra pública/nascentes/linhas de rio até 10m
  g_river_poly := geometry_bases.f_get_layer_geom(p_fc, 'RIVER',         'POLYGON');
  g_lake_poly  := geometry_bases.f_get_layer_geom(p_fc, 'LAKE_LAGOON',   'POLYGON');
  g_pub_infra  := geometry_bases.f_get_layer_geom(p_fc, 'PUBLIC_INFRASTRUCTURE', 'POLYGON');
  g_spring_pt  := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_SPRING',  'POINT');
  g_river_line := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M','LINESTRING');

  g_nv_clean := g_nv_clip;

  IF g_river_poly IS NOT NULL AND NOT ST_IsEmpty(g_river_poly) THEN
    g_nv_clean := ST_Difference(g_nv_clean, g_river_poly);
  END IF;
  IF g_lake_poly IS NOT NULL AND NOT ST_IsEmpty(g_lake_poly) THEN
    g_nv_clean := ST_Difference(g_nv_clean, g_lake_poly);
  END IF;
  IF g_pub_infra IS NOT NULL AND NOT ST_IsEmpty(g_pub_infra) THEN
    g_nv_clean := ST_Difference(g_nv_clean, g_pub_infra);
  END IF;
  IF g_spring_pt IS NOT NULL AND NOT ST_IsEmpty(g_spring_pt) THEN
    g_nv_clean := ST_Difference(
      g_nv_clean,
      ST_Transform(ST_Buffer(ST_Transform(g_spring_pt, srid_met), 50), srid_in)  -- furo/APP da nascente (50m)
    );
  END IF;
  IF g_river_line IS NOT NULL AND NOT ST_IsEmpty(g_river_line) THEN
    g_nv_clean := ST_Difference(
      g_nv_clean,
      ST_Transform(ST_Buffer(ST_Transform(g_river_line, srid_met), 1), srid_in)  -- “fio d’água” (1m) para limpar tangências
    );
  END IF;

  -- 5) reforço de recorte ao imóvel + saneamento
  g_nv_clean := ST_Intersection(g_nv_clean, g_imovel);
  IF g_nv_clean IS NULL OR ST_IsEmpty(g_nv_clean) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, src_layer, NULL);
  END IF;

  g_nv_clean    := ST_Buffer(ST_MakeValid(ST_Union(g_nv_clean)), 0);
  g_nv_clean_m  := ST_Transform(g_nv_clean, srid_met);
  area_nv_ha    := round((ST_Area(g_nv_clean_m)/10000.0)::numeric, 4);

  -- 6) substitui o layer original, preservando properties + área
  feat_new := geometry_bases.f_make_feature(
                src_layer,      -- mantém o MESMO layerCode de entrada
                g_nv_clean,
                props_orig || jsonb_build_object(
                  'area_ha', area_nv_ha,
                  'area',    area_nv_ha
                )
              );

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
  srid_met int := 31983;

  g_imovel geometry;

  -- Agro (entrada/saída)
  g_agro_raw   geometry;
  g_agro_clip  geometry;
  g_agro_clean geometry;
  g_agro_clean_m geometry;
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
  g_nv_union geometry;

  -- Propriedades originais a preservar
  props_orig jsonb := '{}'::jsonb;
  feat_new   jsonb;
BEGIN
  -- 1) Imóvel
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;
  g_imovel := ST_Buffer(ST_MakeValid(g_imovel), 0);

  -- 2) Guardar as PROPRIEDADES ORIGINAIS da CONSOLIDATED_AREA (primeiro feature encontrado)
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
  g_agro_clip := ST_Intersection(ST_Buffer(ST_MakeValid(g_agro_raw),0), g_imovel);
  IF g_agro_clip IS NULL OR ST_IsEmpty(g_agro_clip) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'CONSOLIDATED_AREA', NULL);
  END IF;

  -- 5) Vegetação nativa (prioritária) → retira da Agro
  g_nv_raw := geometry_bases.f_get_layer_geom(p_fc, 'REMAINING_NATIVE_VEGETATION', 'POLYGON');
  IF g_nv_raw IS NULL OR ST_IsEmpty(g_nv_raw) THEN
    g_nv_raw := geometry_bases.f_get_layer_geom(p_fc, 'NATIVE_VEGETATION', 'POLYGON');
  END IF;

  IF g_nv_raw IS NOT NULL AND NOT ST_IsEmpty(g_nv_raw) THEN
    g_nv_clip := ST_Intersection(ST_Buffer(ST_MakeValid(g_nv_raw),0), g_imovel);
    IF g_nv_clip IS NOT NULL AND NOT ST_IsEmpty(g_nv_clip) THEN
      g_nv_union := ST_Buffer(ST_MakeValid(ST_Union(g_nv_clip)), 0);
    ELSE
      g_nv_union := NULL;
    END IF;
  ELSE
    g_nv_union := NULL;
  END IF;

  g_agro_clean := g_agro_clip;

  IF g_nv_union IS NOT NULL AND NOT ST_IsEmpty(g_nv_union) THEN
    g_agro_clean := ST_Difference(g_agro_clean, g_nv_union);
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
      ST_Transform(ST_Buffer(ST_Transform(g_spring_pt, srid_met), 1), srid_in)
    );
  END IF;
  IF g_river_line IS NOT NULL AND NOT ST_IsEmpty(g_river_line) THEN
    g_agro_clean := ST_Difference(
      g_agro_clean,
      ST_Transform(ST_Buffer(ST_Transform(g_river_line, srid_met), 1), srid_in)
    );
  END IF;

  -- 7) Reforço de recorte + consolidação
  g_agro_clean := ST_Intersection(g_agro_clean, g_imovel);
  IF g_agro_clean IS NULL OR ST_IsEmpty(g_agro_clean) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'CONSOLIDATED_AREA', NULL);
  END IF;

  g_agro_clean   := ST_Buffer(ST_MakeValid(ST_Union(g_agro_clean)), 0);
  g_agro_clean_m := ST_Transform(g_agro_clean, srid_met);
  area_agro_ha   := round( (ST_Area(g_agro_clean_m) / 10000.0)::numeric, 4 );

  -- 8) Substitui o layer mantendo as properties originais + área (ha)
  feat_new := geometry_bases.f_make_feature(
                'CONSOLIDATED_AREA',
                g_agro_clean,
                props_orig || jsonb_build_object(
                  'area_ha', area_agro_ha,
                  'area',    area_agro_ha    -- chave extra de compatibilidade
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

CREATE OR REPLACE FUNCTION geometry_bases.rivers_up_to_10m(p_fc jsonb, p_max_distance_m numeric DEFAULT NULL::numeric, p_stream_width_m numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  srid_met int := 31983;

  -- imóvel
  g_imovel    geometry;
  g_imovel_m  geometry;

  -- fonte (linhas de até 10m)
  g_line_raw      geometry;
  g_line_m        geometry;
  g_line_clean_m  geometry;
  g_line_final_m  geometry;
  g_line_final    geometry;

  -- recortes
  g_river_poly   geometry;
  g_river_poly_m geometry;
  g_lake_poly    geometry;
  g_lake_poly_m  geometry;

  -- manter EXACT props do layer original
  props_orig jsonb := '{}'::jsonb;
  feat_new   jsonb;
BEGIN
  -- 1) imóvel
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;
  g_imovel   := ST_Buffer(ST_MakeValid(g_imovel), 0);
  g_imovel_m := ST_Transform(g_imovel, srid_met);

  -- 2) guardar as PROPRIEDADES originais de RIVER_UP_TO_10M
  SELECT feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = 'RIVER_UP_TO_10M'
  LIMIT 1;

  props_orig := COALESCE(props_orig, '{}'::jsonb);

  -- 3) linhas fonte
  g_line_raw := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M', 'LINESTRING');
  IF g_line_raw IS NULL OR ST_IsEmpty(g_line_raw) THEN
    -- não altera se não houver a camada
    RETURN p_fc;
  END IF;

  -- reprojeta para métrico para limpar/topologia e (opcional) limitar distância
  g_line_m := ST_Transform(g_line_raw, srid_met);

  IF p_max_distance_m IS NOT NULL THEN
    g_line_m := ST_Intersection(g_line_m, ST_Buffer(g_imovel_m, p_max_distance_m));
    IF g_line_m IS NULL OR ST_IsEmpty(g_line_m) THEN
      -- remove layer se ficou vazio
      RETURN geometry_bases.f_fc_replace_layer(p_fc, 'RIVER_UP_TO_10M', NULL);
    END IF;
  END IF;

  -- 4) remover trechos que pertencem a rios largos (polígono) e lagos
  g_river_poly := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'POLYGON');
  IF g_river_poly IS NOT NULL AND NOT ST_IsEmpty(g_river_poly) THEN
    g_river_poly_m := ST_Transform(ST_Buffer(ST_MakeValid(g_river_poly),0), srid_met);
    g_line_m := ST_Difference(g_line_m, g_river_poly_m);
  END IF;

  g_lake_poly := geometry_bases.f_get_layer_geom(p_fc, 'LAKE_LAGOON', 'POLYGON');
  IF g_lake_poly IS NOT NULL AND NOT ST_IsEmpty(g_lake_poly) THEN
    g_lake_poly_m := ST_Transform(ST_Buffer(ST_MakeValid(g_lake_poly),0), srid_met);
    g_line_m := ST_Difference(g_line_m, g_lake_poly_m);
  END IF;

  -- 5) consolidar linhas (union + linemerge)
  IF g_line_m IS NULL OR ST_IsEmpty(g_line_m) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'RIVER_UP_TO_10M', NULL);
  END IF;

  g_line_clean_m := ST_LineMerge(ST_Union(g_line_m));

  -- 6) recorte obrigatório ao imóvel (em métrico para robustez)
  g_line_final_m := ST_Intersection(g_line_clean_m, g_imovel_m);
  IF g_line_final_m IS NULL OR ST_IsEmpty(g_line_final_m) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'RIVER_UP_TO_10M', NULL);
  END IF;

  -- 7) volta para 4674 e saneia
  g_line_final := ST_Transform(g_line_final_m, srid_in);
  g_line_final := ST_LineMerge(ST_Union(g_line_final)); -- reforço

  -- 8) cria novo feature com MESMO layerCode e MESMAS properties
  feat_new := geometry_bases.f_make_feature(
                'RIVER_UP_TO_10M',
                g_line_final,
                props_orig
              );

  -- 9) substitui o layer no FC
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
  srid_met int := 31983;

  -- imóvel
  g_imovel    geometry;
  g_imovel_m  geometry;

  -- fontes possíveis
  g_river_poly     geometry;   -- 4674
  g_river_poly_alt geometry;   -- 4674

  -- escolhido
  src_layer  text := NULL;
  g_source   geometry;     -- 4674
  g_source_m geometry;     -- 31983

  -- derivado
  g_near_m     geometry;   -- opcionalmente recortado por distância
  g_in_prop_m  geometry;   -- recorte ao imóvel (para área/relatório)
  g_final      geometry;   -- 4674

  area_ha   numeric := 0;

  props_orig jsonb := '{}'::jsonb;
  feat_new   jsonb;
  layer_out  text;
BEGIN
  -- 1) Imóvel
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;
  g_imovel   := ST_Buffer(ST_MakeValid(g_imovel), 0);
  g_imovel_m := ST_Transform(g_imovel, srid_met);

  -- 2) Fonte poligonal (preferir RIVER_WIDER_THAN_10M; senão RIVER)
  g_river_poly     := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'POLYGON');
  g_river_poly_alt := geometry_bases.f_get_layer_geom(p_fc, 'RIVER',               'POLYGON');

  IF g_river_poly IS NOT NULL AND NOT ST_IsEmpty(g_river_poly) THEN
    src_layer := 'RIVER_WIDER_THAN_10M';
    g_source  := g_river_poly;
  ELSIF g_river_poly_alt IS NOT NULL AND NOT ST_IsEmpty(g_river_poly_alt) THEN
    src_layer := 'RIVER';
    g_source  := g_river_poly_alt;
  ELSE
    -- não há rio poligonal para processar → apenas retorna o FC
    RETURN p_fc;
  END IF;

  -- 3) Propriedades originais do layer escolhido (para herdar)
  SELECT feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS feat
  WHERE upper(feat->'properties'->>'layerCode') = src_layer
  LIMIT 1;
  props_orig := COALESCE(props_orig, '{}'::jsonb);

  -- 4) Reprojetar e (opcional) filtrar por distância, SEM mexer no original
  g_source_m := ST_Transform(ST_Buffer(ST_MakeValid(g_source), 0), srid_met);

  IF p_max_distance_m IS NOT NULL THEN
    -- apenas para performance/visualização; não sobrescreve o original
    g_near_m := ST_Intersection(g_source_m, ST_Buffer(g_imovel_m, p_max_distance_m));
    IF g_near_m IS NULL OR ST_IsEmpty(g_near_m) THEN
      -- nada perto do imóvel: não cria derivado; retorna p_fc intacto
      RETURN p_fc;
    END IF;
  ELSE
    g_near_m := g_source_m;
  END IF;

  -- 5) DERIVADO: recorte ao imóvel (para área/relatório)
  g_in_prop_m := ST_Intersection(
                   ST_Buffer(ST_MakeValid(ST_UnaryUnion(g_near_m)), 0),
                   g_imovel_m
                 );
  IF g_in_prop_m IS NULL OR ST_IsEmpty(g_in_prop_m) THEN
    -- sem interseção com o imóvel → apenas retorna p_fc intacto
    RETURN p_fc;
  END IF;

  area_ha := round( (ST_Area(g_in_prop_m) / 10000.0)::numeric, 4 );

  g_final := ST_Buffer(ST_MakeValid(ST_Transform(g_in_prop_m, srid_in)), 0);

  -- 6) Nome do layer derivado (não toca no original!)
  layer_out := src_layer;

  -- 7) Cria a feature derivada com as props originais + métrica
  feat_new := geometry_bases.f_make_feature(
                layer_out,
                g_final,
                props_orig || jsonb_build_object(
                  'area_ha', area_ha,
                  'area',    area_ha,
                  'source_layer', src_layer,
                  'max_distance_filter_m', p_max_distance_m
                )
              );

  -- 8) Acrescenta o novo layer (não substitui o original)
  RETURN geometry_bases.f_fc_append_one(p_fc, feat_new);
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
  srid_met int := 31983;

  -- parâmetros fixos
  min_rl_percent numeric := 50;
  exclude_app boolean := false;  -- NÃO cortar por APP

  -- imóvel
  g_imovel geometry;

  -- RL
  g_rl_input geometry;
  g_rl_sel geometry;     -- 4674
  g_rl_sel_m geometry;   -- 31983

  -- Hidrografia p/ recorte da RL (NÃO usar PPA)
  g_river_poly geometry;        -- RIVER (ou WIDER)
  g_river_poly_alt geometry;    -- fallback
  g_river_final geometry;       -- união final (4674)
  g_lake_poly geometry;         -- LAKE_LAGOON
  g_river_u10 geometry;         -- RIVER_UP_TO_10M (LINESTRING)

  -- Vegetação nativa (apenas métricas, sem cortar RL)
  g_nv_input geometry;
  g_nv_in_rl_m geometry;

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
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;
  g_imovel := ST_Buffer(ST_MakeValid(g_imovel), 0);

  -- 2) Área mínima exigida
  area_imovel_m2 := ST_Area(ST_Transform(g_imovel, srid_met));
  area_req_m2    := area_imovel_m2 * (min_rl_percent / 100.0);
  required_ha    := round((area_req_m2/10000.0)::numeric, 4);

  -- 3) RL declarada
  g_rl_input := geometry_bases.f_get_layer_geom(p_fc, 'LEGAL_RESERVE', 'POLYGON');
  IF g_rl_input IS NULL OR ST_IsEmpty(g_rl_input) THEN
    RETURN p_fc;
  END IF;

  -- 4) Recorte obrigatório ao imóvel
  g_rl_sel := ST_Intersection(ST_Buffer(ST_MakeValid(g_rl_input),0), g_imovel);
  IF g_rl_sel IS NULL OR ST_IsEmpty(g_rl_sel) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'LEGAL_RESERVE', NULL);
  END IF;

  -- 5) NÃO cortar por APP (exclude_app = false)  → ignoramos PPA_* aqui

  -- 6) Cortar RL pela HIDROGRAFIA (rio/lago e rio até 10m como linha)
  -- 6.1) RIO poligonal
  g_river_poly     := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'POLYGON');
  IF g_river_poly IS NULL OR ST_IsEmpty(g_river_poly) THEN
    g_river_poly_alt := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'POLYGON');
    IF g_river_poly_alt IS NOT NULL AND NOT ST_IsEmpty(g_river_poly_alt) THEN
      g_river_poly := g_river_poly_alt;
    END IF;
  END IF;

  IF g_river_poly IS NOT NULL AND NOT ST_IsEmpty(g_river_poly) THEN
    g_river_final := ST_Buffer(ST_MakeValid(ST_Union(g_river_poly)), 0);
    g_rl_sel := ST_Difference(g_rl_sel, g_river_final);
  END IF;

  -- 6.2) LAGO/LAGOA poligonal
  g_lake_poly := geometry_bases.f_get_layer_geom(p_fc, 'LAKE_LAGOON', 'POLYGON');
  IF g_lake_poly IS NOT NULL AND NOT ST_IsEmpty(g_lake_poly) THEN
    g_rl_sel := ST_Difference(g_rl_sel, ST_Buffer(ST_MakeValid(g_lake_poly),0));
  END IF;

  -- 6.3) RIO ATÉ 10 m (linhas) → remover só a linha (buffer mínimo p/ diferença)
  g_river_u10 := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M', 'LINESTRING');
  IF g_river_u10 IS NOT NULL AND NOT ST_IsEmpty(g_river_u10) THEN
    g_rl_sel := ST_Difference(
                  g_rl_sel,
                  ST_Transform(
                    ST_Buffer(ST_Transform(g_river_u10, srid_met), 1.0),  -- 1 m só para "abrir" a linha
                    srid_in
                  )
                );
  END IF;

  -- Se esvaziou após os cortes, remove layer
  IF g_rl_sel IS NULL OR ST_IsEmpty(g_rl_sel) THEN
    RETURN geometry_bases.f_fc_replace_layer(p_fc, 'LEGAL_RESERVE', NULL);
  END IF;

  -- 7) Consolidar e garantir recorte ao imóvel
  g_rl_sel   := ST_Intersection(ST_Buffer(ST_MakeValid(ST_Union(g_rl_sel)), 0), g_imovel);
  g_rl_sel_m := ST_Transform(g_rl_sel, srid_met);

  -- 8) Métricas recalculadas após cortes
  area_sel_m2 := ST_Area(g_rl_sel_m);
  selected_ha := round((area_sel_m2/10000.0)::numeric, 4);

  -- NV × RL: **NÃO** cortamos RL por NV. Apenas medimos a interseção.
  g_nv_input := geometry_bases.f_get_layer_geom(p_fc, 'REMAINING_NATIVE_VEGETATION', 'POLYGON');
  IF g_nv_input IS NULL OR ST_IsEmpty(g_nv_input) THEN
    g_nv_input := geometry_bases.f_get_layer_geom(p_fc, 'NATIVE_VEGETATION', 'POLYGON');
  END IF;

  IF g_nv_input IS NOT NULL AND NOT ST_IsEmpty(g_nv_input) THEN
    g_nv_in_rl_m := ST_Transform(
                      ST_Intersection(ST_Transform(g_nv_input, srid_met), g_rl_sel_m),
                      srid_met
                    );
    area_nv_rl_m2 := COALESCE(ST_Area(g_nv_in_rl_m), 0);
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
                  'nativa_ha',     nativa_ha,     -- quanto de NV coincide com RL (apenas diagnóstico)
                  'deficit_ha',    deficit_ha,
                  'meets_minimum', meets_minimum,
                  'area_ha',       selected_ha
                );

  -- 10) Substituir o layer com a RL recortada pela HIDROGRAFIA (e NÃO pela NV)
  feat_new := geometry_bases.f_make_feature(
                'LEGAL_RESERVE',
                g_rl_sel,
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

CREATE OR REPLACE FUNCTION geometry_bases.ppa_up_to_10m(p_fc jsonb, p_buffer_m numeric, p_max_distance_m numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  srid_met int := 31983;

  g_imovel geometry;
  g_imovel_m geometry;

  g_river_line geometry;
  g_river_line_m geometry;

  g_ppa_m geometry;
  g_ppa_final_m geometry;

  area_ha numeric := 0;
  feat jsonb;

  -- recorte final dos rios
  lyr   text;
  g_src geometry;
  g_clip geometry;
  props jsonb;
BEGIN
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;
  g_imovel   := ST_Buffer(ST_MakeValid(g_imovel), 0);
  g_imovel_m := ST_Transform(g_imovel, srid_met);

  g_river_line := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_UP_TO_10M', 'LINESTRING');
  IF g_river_line IS NULL OR ST_IsEmpty(g_river_line) THEN
    RETURN p_fc;
  END IF;

  g_river_line_m := ST_Transform(g_river_line, srid_met);

  IF p_max_distance_m IS NOT NULL THEN
    g_river_line_m := ST_Intersection(g_river_line_m, ST_Buffer(g_imovel_m, p_max_distance_m));
    IF g_river_line_m IS NULL OR ST_IsEmpty(g_river_line_m) THEN
      RETURN p_fc;
    END IF;
  END IF;

  g_ppa_m := ST_Buffer(ST_LineMerge(ST_Union(g_river_line_m)), p_buffer_m);
  g_ppa_final_m := ST_Intersection(g_ppa_m, g_imovel_m);
  IF g_ppa_final_m IS NULL OR ST_IsEmpty(g_ppa_final_m) THEN
    RETURN p_fc;
  END IF;

  g_ppa_final_m := ST_MakeValid(ST_Union(g_ppa_final_m));
  area_ha := round( (ST_Area(g_ppa_final_m) / 10000.0)::numeric, 4 );

  feat := geometry_bases.f_make_feature(
           'PPA_UP_TO_10M',
           ST_Transform(g_ppa_final_m, srid_in),
           jsonb_build_object(
             'area_ha', area_ha,
             'buffer_m', p_buffer_m,
             'max_distance_filter_m', p_max_distance_m
           )
         );

  p_fc := geometry_bases.f_fc_append_one(p_fc, feat);

  -- RECORTE FINAL DOS RIOS AO IMÓVEL — trata POLYGON e LINE separadamente
  FOR lyr IN SELECT unnest(ARRAY['RIVER_UP_TO_10M','RIVER','RIVER_WIDER_THAN_10M']) LOOP
    g_src := geometry_bases.f_get_layer_geom(p_fc, lyr, 'POLYGON');
    IF g_src IS NULL OR ST_IsEmpty(g_src) THEN
      g_src := geometry_bases.f_get_layer_geom(p_fc, lyr, 'LINESTRING');
    END IF;
    IF g_src IS NULL OR ST_IsEmpty(g_src) THEN
      CONTINUE;
    END IF;

    SELECT it.feat->'properties' INTO props
    FROM jsonb_array_elements(p_fc->'features') AS it(feat)
    WHERE upper(it.feat->'properties'->>'layerCode') = upper(lyr)
    LIMIT 1;
    props := COALESCE(props, '{}'::jsonb);

    IF GeometryType(g_src) LIKE 'POLYGON%' OR ST_Dimension(g_src) = 2 THEN
      g_clip := ST_Intersection(ST_Buffer(ST_MakeValid(g_src),0), g_imovel);
      g_clip := ST_CollectionExtract(ST_MakeValid(g_clip), 3);
      IF g_clip IS NULL OR ST_IsEmpty(g_clip) THEN
        p_fc := geometry_bases.f_fc_replace_layer(p_fc, lyr, NULL);
      ELSE
        p_fc := geometry_bases.f_fc_replace_layer(
                 p_fc, lyr,
                 geometry_bases.f_make_feature(
                   lyr,
                   ST_Buffer(ST_MakeValid(g_clip),0),
                   props
                 )
               );
      END IF;
    ELSE
      -- LINESTRING: NUNCA dar buffer(0)
      g_clip := ST_Intersection(ST_MakeValid(g_src), g_imovel);
      g_clip := ST_LineMerge(ST_CollectionExtract(ST_MakeValid(g_clip), 2));
      IF g_clip IS NULL OR ST_IsEmpty(g_clip) THEN
        p_fc := geometry_bases.f_fc_replace_layer(p_fc, lyr, NULL);
      ELSE
        p_fc := geometry_bases.f_fc_replace_layer(
                 p_fc, lyr,
                 geometry_bases.f_make_feature(
                   lyr,
                   g_clip,            -- << sem buffer(0) aqui!
                   props
                 )
               );
      END IF;
    END IF;
  END LOOP;

  RETURN p_fc;
END;
$function$
;


-- ===================================================================
-- FUNÇÃO 9: ppa_wider_than_10m
-- ===================================================================

-- DROP FUNCTION geometry_bases.ppa_wider_than_10m(jsonb);

CREATE OR REPLACE FUNCTION geometry_bases.ppa_wider_than_10m(p_fc jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  srid_in  int := 4674;
  srid_met int := 31983;

  buffer_m numeric := 50;          -- fixo
  max_distance_m numeric := NULL;  -- fixo

  g_imovel   geometry;
  g_imovel_m geometry;

  -- hidros de entrada
  g_hydro_poly_all geometry;
  g_hydro_line_all geometry;

  g_hydro_poly_m geometry;
  g_hydro_line_m geometry;

  -- resultado PPA
  g_ppa_m        geometry;
  g_ppa_final_m  geometry;

  area_ha   numeric := 0;
  geom_source text := NULL;

  props_orig jsonb := '{}'::jsonb;
  feat_new   jsonb;

  -- recorte final dos rios
  lyr   text;
  g_src geometry;
  g_clip geometry;
  props jsonb;
BEGIN
  -- 1) Imóvel
  g_imovel := geometry_bases.f_get_layer_geom(p_fc, 'RURAL_PROPERTY', 'POLYGON');
  IF g_imovel IS NULL OR ST_IsEmpty(g_imovel) THEN
    RETURN p_fc;
  END IF;
  g_imovel   := ST_Buffer(ST_MakeValid(g_imovel), 0);
  g_imovel_m := ST_Transform(g_imovel, srid_met);

  -- 2) props existentes (se houver)
  SELECT it.feat->'properties'
    INTO props_orig
  FROM jsonb_array_elements(p_fc->'features') AS it(feat)
  WHERE upper(it.feat->'properties'->>'layerCode') = 'PPA_WIDER_THAN_10M'
  LIMIT 1;
  props_orig := COALESCE(props_orig, '{}'::jsonb);

  -- 3) fonte poligonal preferencial; senão linha
  g_hydro_poly_all := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'POLYGON');
  IF g_hydro_poly_all IS NULL OR ST_IsEmpty(g_hydro_poly_all) THEN
    g_hydro_poly_all := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'POLYGON');
  END IF;

  IF g_hydro_poly_all IS NOT NULL AND NOT ST_IsEmpty(g_hydro_poly_all) THEN
    g_hydro_poly_all := ST_CollectionExtract(ST_Buffer(ST_MakeValid(g_hydro_poly_all),0), 3);
    IF g_hydro_poly_all IS NOT NULL AND NOT ST_IsEmpty(g_hydro_poly_all) THEN
      g_hydro_poly_m := ST_Transform(
                          ST_Buffer(
                            ST_MakeValid(ST_UnaryUnion(g_hydro_poly_all)), 0
                          ),
                          srid_met
                        );
      IF max_distance_m IS NOT NULL THEN
        g_hydro_poly_m := ST_Intersection(g_hydro_poly_m, ST_Buffer(g_imovel_m, max_distance_m));
        IF g_hydro_poly_m IS NULL OR ST_IsEmpty(g_hydro_poly_m) THEN
          g_hydro_poly_all := NULL; -- força cair no ramo de linha
        END IF;
      END IF;
    ELSE
      g_hydro_poly_all := NULL; -- força cair no ramo de linha
    END IF;
  END IF;

  IF g_hydro_poly_all IS NULL OR ST_IsEmpty(g_hydro_poly_all) THEN
    g_hydro_line_all := geometry_bases.f_get_layer_geom(p_fc, 'RIVER_WIDER_THAN_10M', 'LINESTRING');
    IF g_hydro_line_all IS NULL OR ST_IsEmpty(g_hydro_line_all) THEN
      g_hydro_line_all := geometry_bases.f_get_layer_geom(p_fc, 'RIVER', 'LINESTRING');
    END IF;
    IF g_hydro_line_all IS NULL OR ST_IsEmpty(g_hydro_line_all) THEN
      RETURN p_fc;
    END IF;

    g_hydro_line_all := ST_CollectionExtract(ST_MakeValid(g_hydro_line_all), 2);
    IF g_hydro_line_all IS NULL OR ST_IsEmpty(g_hydro_line_all) THEN
      RETURN p_fc;
    END IF;

    g_hydro_line_m := ST_Transform(g_hydro_line_all, srid_met);
    IF max_distance_m IS NOT NULL THEN
      g_hydro_line_m := ST_Intersection(g_hydro_line_m, ST_Buffer(g_imovel_m, max_distance_m));
      IF g_hydro_line_m IS NULL OR ST_IsEmpty(g_hydro_line_m) THEN
        RETURN p_fc;
      END IF;
    END IF;

    geom_source := 'LINESTRING';
    g_ppa_m := ST_Buffer(
                ST_LineMerge(ST_UnaryUnion(g_hydro_line_m)),
                buffer_m
              );
  ELSE
    geom_source := 'POLYGON';
    g_ppa_m := ST_Difference(
                ST_Buffer(ST_Boundary(g_hydro_poly_m), buffer_m),
                g_hydro_poly_m
              );
  END IF;

  IF g_ppa_m IS NULL OR ST_IsEmpty(g_ppa_m) THEN
    RETURN p_fc;
  END IF;

  -- 6) recorte ao imóvel
  g_ppa_final_m := ST_Intersection(
                     ST_Buffer(ST_MakeValid(ST_UnaryUnion(g_ppa_m)), 0),
                     g_imovel_m
                   );
  IF g_ppa_final_m IS NULL OR ST_IsEmpty(g_ppa_final_m) THEN
    RETURN p_fc;
  END IF;

  area_ha := round( (ST_Area(g_ppa_final_m) / 10000.0)::numeric, 4 );

  feat_new := geometry_bases.f_make_feature(
                'PPA_WIDER_THAN_10M',
                ST_Transform(g_ppa_final_m, srid_in),
                props_orig || jsonb_build_object(
                  'area_ha', area_ha,
                  'area',    area_ha,
                  'buffer_m', buffer_m,
                  'geom_source', geom_source,
                  'max_distance_filter_m', max_distance_m
                )
              );

  p_fc := geometry_bases.f_fc_replace_layer(p_fc, 'PPA_WIDER_THAN_10M', feat_new);

  -- 8) RECORTE FINAL DOS RIOS AO IMÓVEL — trata POLYGON e LINE separadamente
  FOR lyr IN SELECT unnest(ARRAY['RIVER','RIVER_WIDER_THAN_10M','RIVER_UP_TO_10M']) LOOP
    g_src := geometry_bases.f_get_layer_geom(p_fc, lyr, 'POLYGON');
    IF g_src IS NULL OR ST_IsEmpty(g_src) THEN
      g_src := geometry_bases.f_get_layer_geom(p_fc, lyr, 'LINESTRING');
    END IF;
    IF g_src IS NULL OR ST_IsEmpty(g_src) THEN
      CONTINUE;
    END IF;

    SELECT it.feat->'properties' INTO props
    FROM jsonb_array_elements(p_fc->'features') AS it(feat)
    WHERE upper(it.feat->'properties'->>'layerCode') = upper(lyr)
    LIMIT 1;
    props := COALESCE(props, '{}'::jsonb);

    IF GeometryType(g_src) LIKE 'POLYGON%' OR ST_Dimension(g_src) = 2 THEN
      g_clip := ST_Intersection(ST_Buffer(ST_MakeValid(g_src),0), g_imovel);
      g_clip := ST_CollectionExtract(ST_MakeValid(g_clip), 3);
      IF g_clip IS NULL OR ST_IsEmpty(g_clip) THEN
        p_fc := geometry_bases.f_fc_replace_layer(p_fc, lyr, NULL);
      ELSE
        p_fc := geometry_bases.f_fc_replace_layer(
                 p_fc, lyr,
                 geometry_bases.f_make_feature(
                   lyr,
                   ST_Buffer(ST_MakeValid(g_clip),0),
                   props
                 )
               );
      END IF;
    ELSE
      -- LINESTRING: NUNCA dar buffer(0)
      g_clip := ST_Intersection(ST_MakeValid(g_src), g_imovel);
      g_clip := ST_LineMerge(ST_CollectionExtract(ST_MakeValid(g_clip), 2));
      IF g_clip IS NULL OR ST_IsEmpty(g_clip) THEN
        p_fc := geometry_bases.f_fc_replace_layer(p_fc, lyr, NULL);
      ELSE
        p_fc := geometry_bases.f_fc_replace_layer(
                 p_fc, lyr,
                 geometry_bases.f_make_feature(
                   lyr,
                   g_clip,            -- << sem buffer(0) aqui!
                   props
                 )
               );
      END IF;
    END IF;
  END LOOP;

  RETURN p_fc;
END;
$function$
;