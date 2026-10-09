-- Validation view for PBJ daily nurse staffing: the newest file, typed, with a reject_reason per row.
-- Rules come from docs/data-profile.md. Placeholder: ${prefix} (for example hsl_dev).
CREATE OR REPLACE VIEW ${prefix}_staging.base_pbj_daily_staffing AS
-- The newest file is the newest ingest_date partition. (Athena views can't read "$partitions" metadata.)
WITH newest AS (
    SELECT *, "$path" AS source_file
    FROM ${prefix}_raw.pbj_daily_nurse_staffing_q2_2024
    WHERE ingest_date = (SELECT max(ingest_date) FROM ${prefix}_raw.pbj_daily_nurse_staffing_q2_2024)
),

typed AS (
    SELECT
        provnum,
        provname                                            AS provider_name,
        city,
        state,
        county_name,
        county_fips,
        cy_qtr,
        work_date                                           AS work_date_text,
        try(CAST(date_parse(work_date, '%Y%m%d') AS date))  AS work_date,
        try_cast(mdscensus AS integer)                      AS mds_census,
        try_cast(hrs_rndon AS double)                       AS hrs_rndon,
        try_cast(hrs_rndon_emp AS double)                   AS hrs_rndon_emp,
        try_cast(hrs_rndon_ctr AS double)                   AS hrs_rndon_ctr,
        try_cast(hrs_rnadmin AS double)                     AS hrs_rnadmin,
        try_cast(hrs_rnadmin_emp AS double)                 AS hrs_rnadmin_emp,
        try_cast(hrs_rnadmin_ctr AS double)                 AS hrs_rnadmin_ctr,
        try_cast(hrs_rn AS double)                          AS hrs_rn,
        try_cast(hrs_rn_emp AS double)                      AS hrs_rn_emp,
        try_cast(hrs_rn_ctr AS double)                      AS hrs_rn_ctr,
        try_cast(hrs_lpnadmin AS double)                    AS hrs_lpnadmin,
        try_cast(hrs_lpnadmin_emp AS double)                AS hrs_lpnadmin_emp,
        try_cast(hrs_lpnadmin_ctr AS double)                AS hrs_lpnadmin_ctr,
        try_cast(hrs_lpn AS double)                         AS hrs_lpn,
        try_cast(hrs_lpn_emp AS double)                     AS hrs_lpn_emp,
        try_cast(hrs_lpn_ctr AS double)                     AS hrs_lpn_ctr,
        try_cast(hrs_cna AS double)                         AS hrs_cna,
        try_cast(hrs_cna_emp AS double)                     AS hrs_cna_emp,
        try_cast(hrs_cna_ctr AS double)                     AS hrs_cna_ctr,
        try_cast(hrs_natrn AS double)                       AS hrs_natrn,
        try_cast(hrs_natrn_emp AS double)                   AS hrs_natrn_emp,
        try_cast(hrs_natrn_ctr AS double)                   AS hrs_natrn_ctr,
        try_cast(hrs_med_aide AS double)                    AS hrs_med_aide,
        try_cast(hrs_med_aide_emp AS double)                AS hrs_med_aide_emp,
        try_cast(hrs_med_aide_ctr AS double)                AS hrs_med_aide_ctr,
        row_number() OVER (PARTITION BY provnum, work_date ORDER BY source_file) AS copy_number,
        ingest_date,
        source_file
    FROM newest
),

checked AS (
    SELECT
        *,
        -- least() is NULL if any value is NULL, so one expression checks all 24 hours columns.
        least(
            hrs_rndon, hrs_rndon_emp, hrs_rndon_ctr, hrs_rnadmin, hrs_rnadmin_emp, hrs_rnadmin_ctr,
            hrs_rn, hrs_rn_emp, hrs_rn_ctr, hrs_lpnadmin, hrs_lpnadmin_emp, hrs_lpnadmin_ctr,
            hrs_lpn, hrs_lpn_emp, hrs_lpn_ctr, hrs_cna, hrs_cna_emp, hrs_cna_ctr,
            hrs_natrn, hrs_natrn_emp, hrs_natrn_ctr, hrs_med_aide, hrs_med_aide_emp, hrs_med_aide_ctr
        ) AS min_hours,
        hrs_rndon + hrs_rnadmin + hrs_rn + hrs_lpnadmin + hrs_lpn
            + hrs_cna + hrs_natrn + hrs_med_aide AS total_nurse_hours
    FROM typed
)

SELECT
    provnum,
    provider_name,
    city,
    state,
    county_name,
    county_fips,
    cy_qtr,
    work_date,
    mds_census,
    hrs_rndon, hrs_rndon_emp, hrs_rndon_ctr,
    hrs_rnadmin, hrs_rnadmin_emp, hrs_rnadmin_ctr,
    hrs_rn, hrs_rn_emp, hrs_rn_ctr,
    hrs_lpnadmin, hrs_lpnadmin_emp, hrs_lpnadmin_ctr,
    hrs_lpn, hrs_lpn_emp, hrs_lpn_ctr,
    hrs_cna, hrs_cna_emp, hrs_cna_ctr,
    hrs_natrn, hrs_natrn_emp, hrs_natrn_ctr,
    hrs_med_aide, hrs_med_aide_emp, hrs_med_aide_ctr,
    total_nurse_hours,
    CASE
        WHEN coalesce(provnum, '') = '' OR coalesce(work_date_text, '') = ''      THEN 'missing_key'
        WHEN NOT regexp_like(provnum, '^[0-9]{2}[0-9A-Z][0-9]{3}$')               THEN 'invalid_ccn'
        WHEN work_date IS NULL OR mds_census IS NULL OR min_hours IS NULL          THEN 'invalid_type'
        WHEN mds_census < 0 OR min_hours < 0                                       THEN 'negative_value'
        WHEN copy_number > 1                                                       THEN 'duplicate_in_file'
        WHEN mds_census > 0 AND total_nurse_hours = 0                              THEN 'no_nursing_hours'
        WHEN mds_census > 0 AND total_nurse_hours / mds_census > 24                THEN 'hprd_above_24'
    END AS reject_reason,
    ingest_date,
    source_file
FROM checked
