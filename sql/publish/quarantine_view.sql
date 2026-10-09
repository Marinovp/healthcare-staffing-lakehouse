-- Rejected rows from this run's silver table, with the reason. Placeholders: ${prefix}, ${dataset}, ${run_id}
CREATE OR REPLACE VIEW ${prefix}_quarantine.${dataset} AS
SELECT *
FROM ${prefix}_builds.silver_${dataset}_${run_id}
WHERE reject_reason IS NOT NULL
