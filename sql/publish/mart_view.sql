-- Point the dashboard view at this run's gold table. Placeholders: ${prefix}, ${mart}, ${run_id}
CREATE OR REPLACE VIEW ${prefix}_marts.${mart} AS
SELECT *
FROM ${prefix}_builds.${mart}_${run_id}
