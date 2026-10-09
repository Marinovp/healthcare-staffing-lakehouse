-- Data checks for one run, saved to audit.check_results. If any 'error' check has failures,
-- nothing gets published. 'warning' checks are only logged. Placeholders: ${prefix}, ${run_id}
INSERT INTO ${prefix}_audit.check_results
WITH
fact AS (SELECT * FROM ${prefix}_builds.fact_daily_staffing_${run_id}),
dim_facility AS (SELECT * FROM ${prefix}_builds.dim_facility_${run_id}),
dim_date AS (SELECT * FROM ${prefix}_builds.dim_date_${run_id}),
agg AS (SELECT * FROM ${prefix}_builds.agg_facility_month_${run_id}),
silver_pbj AS (SELECT * FROM ${prefix}_builds.silver_pbj_daily_staffing_${run_id}),
bronze_pbj AS (
    SELECT ingest_date, count(*) AS row_count
    FROM ${prefix}_raw.pbj_daily_nurse_staffing_q2_2024
    GROUP BY ingest_date
),
facility_quarter AS (
    SELECT provnum,
           sum(IF(hprd_eligible, total_nurse_hours, 0)) / nullif(sum(mds_census), 0) AS total_hprd
    FROM fact
    GROUP BY provnum
),

results (check_name, severity, failures) AS (
    -- keys: unique and not null
    SELECT 'fact_key_unique', 'error', count(*)
    FROM (SELECT provnum, work_date FROM fact GROUP BY 1, 2 HAVING count(*) > 1)
    UNION ALL
    SELECT 'fact_key_not_null', 'error', count_if(provnum IS NULL OR work_date IS NULL) FROM fact
    UNION ALL
    SELECT 'dim_facility_key_unique', 'error', count(*)
    FROM (SELECT provnum FROM dim_facility GROUP BY 1 HAVING count(*) > 1)
    UNION ALL
    SELECT 'dim_date_key_unique', 'error', count(*)
    FROM (SELECT work_date FROM dim_date GROUP BY 1 HAVING count(*) > 1)
    UNION ALL
    SELECT 'agg_key_unique', 'error', count(*)
    FROM (SELECT provnum, month_start FROM agg GROUP BY 1, 2 HAVING count(*) > 1)

    -- every fact row needs a facility and a date
    UNION ALL
    SELECT 'fact_facility_in_dim', 'error', count(*)
    FROM fact AS f LEFT JOIN dim_facility AS d ON d.provnum = f.provnum
    WHERE d.provnum IS NULL
    UNION ALL
    SELECT 'fact_date_in_dim', 'error', count(*)
    FROM fact AS f LEFT JOIN dim_date AS d ON d.work_date = f.work_date
    WHERE d.work_date IS NULL

    -- row counts: make sure nothing got lost between layers
    UNION ALL
    SELECT 'silver_rows_match_bronze', 'error',
           abs((SELECT count(*) FROM silver_pbj)
               - (SELECT row_count FROM bronze_pbj ORDER BY ingest_date DESC LIMIT 1))
    UNION ALL
    SELECT 'fact_rows_match_valid_silver', 'error',
           abs((SELECT count(*) FROM fact)
               - (SELECT count(*) FROM silver_pbj WHERE reject_reason IS NULL))

    -- sanity checks (warnings only)
    UNION ALL
    SELECT 'daily_hprd_in_0_to_24', 'warning', count_if(total_hprd < 0 OR total_hprd > 24) FROM fact
    UNION ALL
    SELECT 'facility_hprd_within_50pct_of_cms_reported', 'warning', count(*)
    FROM facility_quarter AS q JOIN dim_facility AS d ON d.provnum = q.provnum
    WHERE d.cms_reported_total_hprd > 0
      AND abs(q.total_hprd - d.cms_reported_total_hprd) > 0.5 * d.cms_reported_total_hprd
    UNION ALL
    SELECT 'pbj_rows_within_20pct_of_previous_file', 'warning',
           count_if(previous_rows IS NOT NULL AND abs(row_count - previous_rows) > 0.2 * previous_rows)
    FROM (
        SELECT ingest_date, row_count, lag(row_count) OVER (ORDER BY ingest_date) AS previous_rows
        FROM bronze_pbj
        ORDER BY ingest_date DESC
        LIMIT 1
    )
)

SELECT '${run_id}', check_name, severity, failures, CAST(current_timestamp AS timestamp(6))
FROM results
