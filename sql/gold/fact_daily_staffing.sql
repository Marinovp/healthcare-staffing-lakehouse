-- fact_daily_staffing: one row per facility per day, from the valid silver rows.
-- Hour groups follow CMS: RN includes the director of nursing and RN admin; LPN includes LPN admin;
-- aides are CNAs, aides in training and medication aides. The 3.48 / 0.55 HPRD benchmarks are the
-- 2024 CMS minimum staffing rule, used as a benchmark only. Placeholders: ${prefix}, ${bucket}, ${run_id}
CREATE TABLE ${prefix}_builds.fact_daily_staffing_${run_id}
WITH (
    table_type  = 'ICEBERG',
    is_external = false,
    location    = 's3://${bucket}/builds/gold/fact_daily_staffing/${run_id}/',
    format      = 'PARQUET'
)
AS
WITH grouped AS (
    SELECT
        provnum,
        work_date,
        mds_census,
        hrs_rndon + hrs_rnadmin + hrs_rn                   AS rn_hours,
        hrs_lpnadmin + hrs_lpn                             AS lpn_hours,
        hrs_cna + hrs_natrn + hrs_med_aide                 AS aide_hours,
        total_nurse_hours,
        hrs_rndon_ctr + hrs_rnadmin_ctr + hrs_rn_ctr + hrs_lpnadmin_ctr + hrs_lpn_ctr
            + hrs_cna_ctr + hrs_natrn_ctr + hrs_med_aide_ctr AS contract_hours,
        hrs_rndon, hrs_rndon_emp, hrs_rndon_ctr,
        hrs_rnadmin, hrs_rnadmin_emp, hrs_rnadmin_ctr,
        hrs_rn, hrs_rn_emp, hrs_rn_ctr,
        hrs_lpnadmin, hrs_lpnadmin_emp, hrs_lpnadmin_ctr,
        hrs_lpn, hrs_lpn_emp, hrs_lpn_ctr,
        hrs_cna, hrs_cna_emp, hrs_cna_ctr,
        hrs_natrn, hrs_natrn_emp, hrs_natrn_ctr,
        hrs_med_aide, hrs_med_aide_emp, hrs_med_aide_ctr
    FROM ${prefix}_builds.silver_pbj_daily_staffing_${run_id}
    WHERE reject_reason IS NULL
),

with_hprd AS (
    SELECT
        *,
        mds_census > 0                                              AS hprd_eligible,
        IF(mds_census > 0, total_nurse_hours / mds_census)          AS total_hprd,
        IF(mds_census > 0, rn_hours / mds_census)                   AS rn_hprd
    FROM grouped
)

SELECT
    *,
    total_hprd < 3.48   AS below_total_benchmark,   -- NULL on days without residents
    rn_hprd < 0.55      AS below_rn_benchmark
FROM with_hprd
