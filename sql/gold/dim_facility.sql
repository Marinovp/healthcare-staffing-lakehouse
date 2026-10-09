-- dim_facility: one row per facility in PBJ. LEFT JOIN to ProviderInfo and Claims so the facilities
-- that aren't in the October file still keep their staffing rows (they show up as "Unknown").
-- Placeholders: ${prefix}, ${bucket}, ${run_id}
CREATE TABLE ${prefix}_builds.dim_facility_${run_id}
WITH (
    table_type  = 'ICEBERG',
    is_external = false,
    location    = 's3://${bucket}/builds/gold/dim_facility/${run_id}/',
    format      = 'PARQUET'
)
AS
WITH pbj_facilities AS (
    -- name and location come from PBJ, taken from the facility's last day in the quarter
    SELECT
        provnum,
        max_by(provider_name, work_date) AS provider_name,
        max_by(city, work_date)          AS city,
        max_by(state, work_date)         AS state,
        max_by(county_name, work_date)   AS county_name,
        max_by(county_fips, work_date)   AS county_fips
    FROM ${prefix}_builds.silver_pbj_daily_staffing_${run_id}
    WHERE reject_reason IS NULL
    GROUP BY provnum
),

provider_info AS (
    SELECT *
    FROM ${prefix}_builds.silver_provider_info_${run_id}
    WHERE reject_reason IS NULL
),

claims AS (
    -- 521 = % of short-stay residents rehospitalised, 551 = hospitalisations per 1,000 long-stay days
    SELECT
        provnum,
        max(IF(measure_code = '521', adjusted_score)) AS short_stay_rehospitalisation_pct,
        max(IF(measure_code = '551', adjusted_score)) AS long_stay_hospitalisations_per_1000_days
    FROM ${prefix}_builds.silver_quality_claims_${run_id}
    WHERE reject_reason IS NULL
    GROUP BY provnum
)

SELECT
    f.provnum,
    f.provider_name,
    f.city,
    f.state,
    f.county_name,
    f.county_fips,
    coalesce(p.ownership_type, 'Unknown')   AS ownership_type,
    coalesce(p.ownership_group, 'Unknown')  AS ownership_group,
    p.certified_beds,
    p.overall_rating,
    p.staffing_rating,
    p.cms_reported_total_hprd,
    p.nursing_staff_turnover,
    c.short_stay_rehospitalisation_pct,
    c.long_stay_hospitalisations_per_1000_days,
    p.provnum IS NOT NULL                   AS in_provider_info
FROM pbj_facilities AS f
LEFT JOIN provider_info AS p ON p.provnum = f.provnum
LEFT JOIN claims AS c ON c.provnum = f.provnum
