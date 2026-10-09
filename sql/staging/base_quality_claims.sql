-- Validation view for NH_QualityMsr_Claims (one row per facility and measure): the newest file, typed,
-- with a reject_reason. A missing score is not an error: CMS leaves it empty when there are too few residents.
-- Placeholder: ${prefix} (for example hsl_dev).
CREATE OR REPLACE VIEW ${prefix}_staging.base_quality_claims AS
-- The newest file is the newest ingest_date partition. (Athena views can't read "$partitions" metadata.)
WITH newest AS (
    SELECT *, "$path" AS source_file
    FROM ${prefix}_raw.nh_quality_msr_claims_oct2024
    WHERE ingest_date = (SELECT max(ingest_date) FROM ${prefix}_raw.nh_quality_msr_claims_oct2024)
),

typed AS (
    SELECT
        cms_certification_number_ccn                 AS provnum,
        measure_code,
        measure_description,
        resident_type,
        try_cast(adjusted_score AS double)           AS adjusted_score,
        try_cast(observed_score AS double)           AS observed_score,
        try_cast(expected_score AS double)           AS expected_score,
        footnote_for_score,
        measure_period,
        row_number() OVER (
            PARTITION BY cms_certification_number_ccn, measure_code ORDER BY source_file
        )                                            AS copy_number,
        ingest_date,
        source_file
    FROM newest
)

SELECT
    provnum,
    measure_code,
    measure_description,
    resident_type,
    adjusted_score,
    observed_score,
    expected_score,
    footnote_for_score,
    measure_period,
    CASE
        WHEN coalesce(provnum, '') = '' OR coalesce(measure_code, '') = ''  THEN 'missing_key'
        WHEN NOT regexp_like(provnum, '^[0-9]{2}[0-9A-Z][0-9]{3}$')         THEN 'invalid_ccn'
        WHEN copy_number > 1                                                THEN 'duplicate_in_file'
    END AS reject_reason,
    ingest_date,
    source_file
FROM typed
