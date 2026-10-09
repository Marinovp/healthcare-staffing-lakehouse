-- Save this run's silver table for a dataset: every row of the newest file plus its reject_reason.
-- Placeholders: ${prefix}, ${bucket}, ${dataset}, ${run_id}
CREATE TABLE ${prefix}_builds.silver_${dataset}_${run_id}
WITH (
    table_type  = 'ICEBERG',
    is_external = false,
    location    = 's3://${bucket}/builds/silver/${dataset}/${run_id}/',
    format      = 'PARQUET'
)
AS SELECT * FROM ${prefix}_staging.base_${dataset}
