\set ON_ERROR_STOP on
\pset pager off
\pset footer off
\t on
\a
\o /dev/null

-- entrada única (altere o GeoJSON aqui quando quiser)
DROP TABLE IF EXISTS tmp_fc1;
CREATE TEMP TABLE tmp_fc1 (j jsonb);
INSERT INTO tmp_fc1(j) VALUES (
$json$
{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-37.902317,-9.266361],[-37.90236,-9.2603],[-37.889142,-9.260427],[-37.888906,-9.26653],[-37.902317,-9.266361]]]},"properties":{"tipo":"AREA_IMOVEL"}},{"type":"Feature","geometry":{"type":"Point","coordinates":[-37.90133,-9.260978]},"properties":{"tipo":"SEDE_IMOVEL"}},{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-37.895826,-9.26504],[-37.895837,-9.262603],[-37.8925,-9.262698],[-37.892425,-9.265156],[-37.895826,-9.26504]]]},"properties":{"tipo":"LAGO_NATURAL"}}]}
$json$::jsonb
);

WITH s0 AS (SELECT j AS fc FROM tmp_fc1),
-- 1) HIDRICO_IMOVEL (base)
s_hidrico AS (
  SELECT geometry_bases.f_calcula_hidrico_imovel_geojson((SELECT fc::text FROM s0))::jsonb AS fc
),
-- 3) SERVIDÃO_TOTAL
s_servidao AS (
  SELECT geometry_bases.f_calcula_servidao_total_geojson((SELECT fc::text FROM s0))::jsonb AS fc
),
-- 4) area_liquida (sobre a saída de Servidão; a função preserva o conjunto + anota modulo_fiscal)
s_area_liquida AS (
  SELECT geometry_bases.f_calcula_area_imovel_liquida_geojson((SELECT fc::text FROM s_servidao))::jsonb AS fc
),
-- 5) MERGE (HIDRICO + AREA_LIQUIDA)
s_merge3 AS (
  SELECT geometry_bases.f_merge_two_geojson(
           (SELECT fc::text FROM s_hidrico),
           (SELECT fc::text FROM s_area_liquida)
         )::jsonb AS fc
),
-- 7) COBERTURA DO SOLO (sem sobreposição)
s_csolo AS (
  SELECT geometry_bases.f_calcula_cobertura_solo_geojson(
           (SELECT fc::text FROM s_merge3)
         )::jsonb AS fc
),

-- 9) ÁREA NÃO CLASSIFICADA
s_anc AS (
  SELECT geometry_bases.f_calcula_area_nao_classificada_geojson(
           (SELECT fc::text FROM s_csolo)
         )::jsonb AS fc
),
-- 2) RL_TOTAL (base)  [usaremos no merge inicial e também como RL final]
s_rl_ini AS (
  SELECT geometry_bases.f_calcula_rl_total_geojson((SELECT fc::text FROM s_anc))::jsonb AS fc
),
-- 10) APPs (derivadas)
s_apps AS (
  SELECT geometry_bases.f_calcula_app_geojson(
           (SELECT fc::text FROM s_rl_ini)
         )::jsonb AS fc
),
-- 14) APPs_ESCADINHA (por classe) a partir de APP_AREA_VN
s_app_escad AS (
  SELECT geometry_bases.f_calcula_app_escadinha_geojson(
           (SELECT fc::text FROM s_apps)
         )::jsonb AS fc
)
-- =========================================================
-- SAÍDAS 
-- =========================================================
select
--  geometry_bases._pretty((SELECT fc FROM s_hidrico))        AS saida_hidrico,
--  geometry_bases._pretty((SELECT fc FROM s_servidao))       AS saida_servidao,
--  geometry_bases._pretty((SELECT fc FROM s_area_liquida))   AS saida_area_liquidao,
--  geometry_bases._pretty((SELECT fc FROM s_mf))  			AS saida_s_mf,
--  geometry_bases._pretty((SELECT fc FROM s_merge3))         AS saida_merge3
--  geometry_bases._pretty((SELECT fc FROM s_csolo))          AS saida_cobertura_solo
--  geometry_bases._pretty((SELECT fc FROM s_anc))            AS saida_area_nao_classificada,
--  geometry_bases._pretty((SELECT fc FROM s_rl_ini))         AS saida_rl_ini,
--  geometry_bases._pretty((SELECT fc FROM s_apps))           AS saida_apps,
  jsonb_pretty((SELECT fc FROM s_app_escad))      AS saida_apps_escadinha;
\g /tests_output/test_prepreenchido_result.json
