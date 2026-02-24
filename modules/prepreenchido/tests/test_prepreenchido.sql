\set ON_ERROR_STOP on
\pset pager off
\pset footer off
\t on
\a
\o /dev/null

SELECT jsonb_pretty(geometry_bases.prepreenchido_status());
\g /tests_output/test_prepreenchido_result.json
