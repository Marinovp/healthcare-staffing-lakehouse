-- Bronze profiling queries. Run them one at a time in Athena
-- (workgroup hsl-dev-pipeline, database hsl_dev_raw).
-- Everything in bronze is text, so this checks the values exactly as they came in.
-- What I found and what I decided: docs/data-profile.md

-- 1. Do the codes in PBJ look right?
SELECT
    count(DISTINCT provnum)                                                    AS facilities,
    count(DISTINCT CASE WHEN regexp_like(provnum, '[A-Z]') THEN provnum END)    AS ccn_with_letter,
    count_if(NOT regexp_like(provnum, '^[0-9]{2}[0-9A-Z][0-9]{3}$'))            AS ccn_bad_format,
    count_if(NOT regexp_like(county_fips, '^[0-9]{3}$'))                       AS fips_not_3_digits,
    count_if(NOT regexp_like(work_date, '^[0-9]{8}$'))                          AS work_date_not_yyyymmdd,
    count_if(cy_qtr <> '2024Q2')                                                AS other_quarter
FROM pbj_daily_nurse_staffing_q2_2024;

-- 2. Partitions (should be only one ingest_date)
SELECT ingest_date, count(*) AS row_count
FROM pbj_daily_nurse_staffing_q2_2024
GROUP BY ingest_date;

-- 3. PBJ overview: size, date range, census
SELECT
    count(*)                                              AS row_count,
    min(work_date)                                        AS first_day,
    max(work_date)                                        AS last_day,
    count(DISTINCT work_date)                             AS days,
    count_if(try_cast(mdscensus AS integer) IS NULL)      AS census_not_integer,
    count_if(try_cast(mdscensus AS integer) = 0)          AS census_zero
FROM pbj_daily_nurse_staffing_q2_2024;

-- 4. Grain check: one row per facility per day (should return nothing)
SELECT provnum, work_date, count(*) AS copies
FROM pbj_daily_nurse_staffing_q2_2024
GROUP BY provnum, work_date
HAVING count(*) > 1
LIMIT 10;

-- 5. Sanity checks on the hours (CMS groups: RN incl. DON + admin, LPN incl. admin,
--    aides = CNA + trainees + med aides)
WITH pbj AS (
    SELECT
        try_cast(mdscensus AS integer) AS census,
        try_cast(hrs_rndon AS double) + try_cast(hrs_rnadmin AS double) + try_cast(hrs_rn AS double) AS rn_hours,
        try_cast(hrs_lpnadmin AS double) + try_cast(hrs_lpn AS double)                               AS lpn_hours,
        try_cast(hrs_cna AS double) + try_cast(hrs_natrn AS double) + try_cast(hrs_med_aide AS double) AS aide_hours,
        try_cast(hrs_rn AS double) - try_cast(hrs_rn_emp AS double) - try_cast(hrs_rn_ctr AS double)   AS rn_split_gap
    FROM pbj_daily_nurse_staffing_q2_2024
)
SELECT
    count_if(rn_hours IS NULL OR lpn_hours IS NULL OR aide_hours IS NULL)          AS hours_not_numeric,
    count_if(rn_hours < 0 OR lpn_hours < 0 OR aide_hours < 0)                      AS negative_hours,
    count_if(abs(rn_split_gap) > 0.01)                                             AS rn_split_mismatch,
    count_if(census > 0 AND rn_hours + lpn_hours + aide_hours = 0)                 AS census_but_no_hours,
    count_if(census = 0 AND rn_hours + lpn_hours + aide_hours > 0)                 AS hours_but_no_census,
    count_if(census > 0 AND (rn_hours + lpn_hours + aide_hours) / census > 24)     AS total_hprd_over_24
FROM pbj;

-- 6. Quick preview of the metrics: can I calculate them, and do they look right?
WITH pbj AS (
    SELECT
        try_cast(mdscensus AS integer) AS census,
        day_of_week(date_parse(work_date, '%Y%m%d')) IN (6, 7) AS is_weekend,
        try_cast(hrs_rndon AS double) + try_cast(hrs_rnadmin AS double) + try_cast(hrs_rn AS double) AS rn_hours,
        try_cast(hrs_rndon AS double) + try_cast(hrs_rnadmin AS double) + try_cast(hrs_rn AS double)
          + try_cast(hrs_lpnadmin AS double) + try_cast(hrs_lpn AS double)
          + try_cast(hrs_cna AS double) + try_cast(hrs_natrn AS double) + try_cast(hrs_med_aide AS double) AS total_hours,
        try_cast(hrs_rndon_ctr AS double) + try_cast(hrs_rnadmin_ctr AS double) + try_cast(hrs_rn_ctr AS double)
          + try_cast(hrs_lpnadmin_ctr AS double) + try_cast(hrs_lpn_ctr AS double)
          + try_cast(hrs_cna_ctr AS double) + try_cast(hrs_natrn_ctr AS double) + try_cast(hrs_med_aide_ctr AS double) AS contract_hours
    FROM pbj_daily_nurse_staffing_q2_2024
)
SELECT
    approx_percentile(total_hours / census, ARRAY[0.01, 0.25, 0.5, 0.75, 0.99]) AS total_hprd_p01_p25_p50_p75_p99,
    approx_percentile(rn_hours / census, ARRAY[0.01, 0.25, 0.5, 0.75, 0.99])    AS rn_hprd_p01_p25_p50_p75_p99,
    avg(IF(total_hours / census < 3.48 OR rn_hours / census < 0.55, 1.0, 0.0))   AS share_days_below_benchmark,
    sum(contract_hours) / sum(total_hours)                                      AS contract_share,
    sum(IF(is_weekend, total_hours, 0)) / sum(IF(is_weekend, census, 0))
      - sum(IF(NOT is_weekend, total_hours, 0)) / sum(IF(NOT is_weekend, census, 0)) AS weekend_minus_weekday_hprd
FROM pbj
WHERE census > 0;

-- 7. How many PBJ facilities can I find in ProviderInfo?
SELECT
    count(DISTINCT p.provnum)                        AS pbj_facilities,
    count(DISTINCT i.cms_certification_number_ccn)   AS matched_in_provider_info
FROM pbj_daily_nurse_staffing_q2_2024 AS p
LEFT JOIN nh_provider_info_oct2024 AS i
    ON p.provnum = i.cms_certification_number_ccn;

-- 8. PBJ facilities missing from ProviderInfo
SELECT p.provnum, p.state, count(*) AS days
FROM pbj_daily_nurse_staffing_q2_2024 AS p
LEFT JOIN nh_provider_info_oct2024 AS i
    ON p.provnum = i.cms_certification_number_ccn
WHERE i.cms_certification_number_ccn IS NULL
GROUP BY 1, 2
ORDER BY 1;

-- 9. ProviderInfo: one row per facility? And are the beds filled in (needed for occupancy)?
SELECT
    count(*)                                                          AS row_count,
    count(DISTINCT cms_certification_number_ccn)                      AS facilities,
    count_if(try_cast(number_of_certified_beds AS integer) IS NULL)   AS beds_missing,
    count_if(try_cast(number_of_certified_beds AS integer) = 0)       AS beds_zero,
    min(try_cast(number_of_certified_beds AS integer))                AS beds_min,
    max(try_cast(number_of_certified_beds AS integer))                AS beds_max
FROM nh_provider_info_oct2024;

-- 10. Claims: which measures are there, and how many facilities have a score?
SELECT
    measure_code,
    measure_description,
    count(*)                                               AS facilities,
    count_if(try_cast(adjusted_score AS double) IS NULL)   AS no_score
FROM nh_quality_msr_claims_oct2024
GROUP BY 1, 2
ORDER BY 1;

-- 11. Facilities by ownership type
SELECT ownership_type, count(*) AS facilities
FROM nh_provider_info_oct2024
GROUP BY 1
ORDER BY facilities DESC;
