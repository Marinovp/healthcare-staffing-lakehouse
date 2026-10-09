-- agg_facility_month: the dashboard metrics per facility per month, calculated up front so the
-- dashboard queries stay small. HPRD = hours / resident days, only counting hours on days with residents.
-- Placeholders: ${prefix}, ${bucket}, ${run_id}
CREATE TABLE ${prefix}_builds.agg_facility_month_${run_id}
WITH (
    table_type  = 'ICEBERG',
    is_external = false,
    location    = 's3://${bucket}/builds/gold/agg_facility_month/${run_id}/',
    format      = 'PARQUET'
)
AS
SELECT
    f.provnum,
    d.month_start,
    count(*)                                                                   AS days_reported,
    count_if(f.hprd_eligible)                                                  AS days_with_residents,
    sum(f.mds_census)                                                          AS resident_days,
    avg(f.mds_census)                                                          AS avg_daily_census,

    sum(f.total_nurse_hours)                                                   AS total_nurse_hours,
    sum(f.rn_hours)                                                            AS rn_hours,
    sum(f.lpn_hours)                                                           AS lpn_hours,
    sum(f.aide_hours)                                                          AS aide_hours,
    sum(f.contract_hours)                                                      AS contract_hours,

    sum(IF(f.hprd_eligible, f.total_nurse_hours, 0)) / nullif(sum(f.mds_census), 0) AS total_hprd,
    sum(IF(f.hprd_eligible, f.rn_hours, 0))          / nullif(sum(f.mds_census), 0) AS rn_hprd,
    sum(IF(f.hprd_eligible, f.lpn_hours, 0))         / nullif(sum(f.mds_census), 0) AS lpn_hprd,
    sum(IF(f.hprd_eligible, f.aide_hours, 0))        / nullif(sum(f.mds_census), 0) AS aide_hprd,

    sum(f.contract_hours) / nullif(sum(f.total_nurse_hours), 0)                AS contract_share,

    CAST(count_if(f.below_total_benchmark) AS double)
        / nullif(count_if(f.hprd_eligible), 0)                                 AS below_total_benchmark_rate,
    CAST(count_if(f.below_rn_benchmark) AS double)
        / nullif(count_if(f.hprd_eligible), 0)                                 AS below_rn_benchmark_rate,
    CAST(count_if(f.below_total_benchmark OR f.below_rn_benchmark) AS double)
        / nullif(count_if(f.hprd_eligible), 0)                                 AS below_either_benchmark_rate,

    sum(IF(d.is_weekend AND f.hprd_eligible, f.total_nurse_hours, 0))
        / nullif(sum(IF(d.is_weekend, f.mds_census, 0)), 0)                    AS weekend_total_hprd,
    sum(IF(NOT d.is_weekend AND f.hprd_eligible, f.total_nurse_hours, 0))
        / nullif(sum(IF(NOT d.is_weekend, f.mds_census, 0)), 0)                AS weekday_total_hprd,

    avg(f.mds_census) / nullif(max(fac.certified_beds), 0)                     AS occupancy
FROM ${prefix}_builds.fact_daily_staffing_${run_id} AS f
JOIN ${prefix}_builds.dim_date_${run_id} AS d ON d.work_date = f.work_date
JOIN ${prefix}_builds.dim_facility_${run_id} AS fac ON fac.provnum = f.provnum
GROUP BY f.provnum, d.month_start
