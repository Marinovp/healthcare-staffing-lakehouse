-- Publish the valid rows of a run's silver table. Placeholders: ${prefix}, ${dataset}, ${run_id}
CREATE OR REPLACE VIEW ${prefix}_silver.${dataset} AS
SELECT *
FROM ${prefix}_builds.silver_${dataset}_${run_id}
WHERE reject_reason IS NULL
