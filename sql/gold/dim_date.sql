-- dim_date: one row per day, from the first to the last day of staffing data.
-- Placeholders: ${prefix}, ${bucket}, ${run_id}
CREATE TABLE ${prefix}_builds.dim_date_${run_id}
WITH (
    table_type  = 'ICEBERG',
    is_external = false,
    location    = 's3://${bucket}/builds/gold/dim_date/${run_id}/',
    format      = 'PARQUET'
)
AS
WITH bounds AS (
    SELECT min(work_date) AS first_day, max(work_date) AS last_day
    FROM ${prefix}_builds.silver_pbj_daily_staffing_${run_id}
    WHERE reject_reason IS NULL
),

days AS (
    -- Athena's sequence() only works with timestamps, so cast each day back to a date
    SELECT CAST(ts AS date) AS day
    FROM bounds
    CROSS JOIN UNNEST(sequence(CAST(first_day AS timestamp), CAST(last_day AS timestamp), INTERVAL '1' DAY)) AS t (ts)
)

SELECT
    day                                           AS work_date,
    year(day)                                     AS year,
    quarter(day)                                  AS quarter,
    month(day)                                    AS month,
    date_trunc('month', day)                      AS month_start,
    day_of_week(day)                              AS day_of_week,   -- 1 = Monday, 7 = Sunday
    date_format(CAST(day AS timestamp), '%W')     AS day_name,
    day_of_week(day) IN (6, 7)                    AS is_weekend
FROM days
