-- Publish a run's gold table to the dashboard. Placeholders: ${prefix}, ${mart}, ${run_id}
CREATE OR REPLACE VIEW ${prefix}_marts.${mart} AS
SELECT *
FROM ${prefix}_builds.${mart}_${run_id}
