-- Validation view for NH_ProviderInfo (one row per facility): the newest file, typed, with a reject_reason.
-- Placeholder: ${prefix} (for example hsl_dev).
CREATE OR REPLACE VIEW ${prefix}_staging.base_provider_info AS
-- The newest file is the newest ingest_date partition. (Athena views can't read "$partitions" metadata.)
WITH newest AS (
    SELECT *, "$path" AS source_file
    FROM ${prefix}_raw.nh_provider_info_oct2024
    WHERE ingest_date = (SELECT max(ingest_date) FROM ${prefix}_raw.nh_provider_info_oct2024)
),

typed AS (
    SELECT
        cms_certification_number_ccn                                                  AS provnum,
        provider_name,
        city_town                                                                     AS city,
        state,
        zip_code,
        county_parish                                                                 AS county,
        ownership_type,
        split_part(ownership_type, ' - ', 1)                                          AS ownership_group,
        try_cast(number_of_certified_beds AS integer)                                 AS certified_beds,
        try_cast(overall_rating AS integer)                                           AS overall_rating,
        try_cast(staffing_rating AS integer)                                          AS staffing_rating,
        try_cast(reported_total_nurse_staffing_hours_per_resident_per_day AS double) AS cms_reported_total_hprd,
        try_cast(total_nursing_staff_turnover AS double)                              AS nursing_staff_turnover,
        row_number() OVER (PARTITION BY cms_certification_number_ccn ORDER BY source_file) AS copy_number,
        ingest_date,
        source_file
    FROM newest
)

SELECT
    provnum,
    provider_name,
    city,
    state,
    zip_code,
    county,
    ownership_type,
    ownership_group,
    certified_beds,
    overall_rating,
    staffing_rating,
    cms_reported_total_hprd,
    nursing_staff_turnover,
    CASE
        WHEN coalesce(provnum, '') = ''                                THEN 'missing_key'
        WHEN NOT regexp_like(provnum, '^[0-9]{2}[0-9A-Z][0-9]{3}$')    THEN 'invalid_ccn'
        WHEN certified_beds IS NULL OR certified_beds <= 0             THEN 'invalid_beds'
        WHEN copy_number > 1                                           THEN 'duplicate_in_file'
    END AS reject_reason,
    ingest_date,
    source_file
FROM typed
