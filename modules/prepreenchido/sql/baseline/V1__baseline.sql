-- Baseline inicial do módulo prepreenchido

CREATE SCHEMA IF NOT EXISTS geometry_bases;

-- Retorna metadados básicos para validar pipeline de migração/teste do módulo.
CREATE OR REPLACE FUNCTION geometry_bases.prepreenchido_status()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'module', 'prepreenchido',
    'status', 'ok',
    'version', 'v1'
  );
$$;
