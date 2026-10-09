-- Audit table: one row per check per run. Created once, then every run adds to it. Placeholders: ${prefix}, ${bucket}
CREATE TABLE IF NOT EXISTS ${prefix}_audit.check_results (
    run_id      string,
    check_name  string,
    severity    string,
    failures    bigint,
    checked_at  timestamp
)
LOCATION 's3://${bucket}/audit/check_results/'
TBLPROPERTIES ('table_type' = 'ICEBERG')
