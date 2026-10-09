# Data Dictionary

All tables are in the AWS Glue Data Catalog and are queried with Athena. Database names carry the environment prefix (here `hsl_dev_`). The published views are what people and the dashboard read. Each one points at a run's stored tables in `builds`, named `<table>_<run_id>` (for example `fact_daily_staffing_r20261009_022415`).

| Layer | Database | What it holds |
|---|---|---|
| Bronze | `raw` | Source CSVs as delivered (UTF-8), every column as text, partitioned by `ingest_date` |
| Silver | `silver` / `quarantine` | Typed, validated rows / rejected rows with a `reject_reason` |
| Gold | `marts` | Star schema and monthly metrics: what the dashboard reads |
| Audit | `audit` | Data check results per run |

**Hour groupings** (CMS's own definitions, used throughout):
- **RN hours** = RN + RN director of nursing (`hrs_rndon`) + RN admin (`hrs_rnadmin`)
- **LPN hours** = LPN + LPN admin
- **Aide hours** = certified nurse aides (CNA) + aides in training (`natrn`) + medication aides
- **Total nurse hours** = RN + LPN + aide hours

**HPRD** (hours per resident day) = hours ÷ resident days (`mds_census`), counting only days with at least one resident.

## Bronze: `raw`

One table per source file, created by the ingestion job `drive_sync`, which names the table after the file in snake_case. For example, `NH_ProviderInfo_Oct2024.csv` becomes `nh_provider_info_oct2024`. Column names are the CSV headers in snake_case (`CMS Certification Number (CCN)` becomes `cms_certification_number_ccn`, and `WorkDate` becomes `work_date`). **Every column is text**, so codes such as `015009` and `39A433` arrive exactly as delivered. 21 tables; the pipeline uses three:

| Table | Source file | Rows | Grain |
|---|---|---|---|
| `pbj_daily_nurse_staffing_q2_2024` | PBJ_Daily_Nurse_Staffing_Q2_2024.csv | 1,325,324 | Facility × day |
| `nh_provider_info_oct2024` | NH_ProviderInfo_Oct2024.csv | 14,814 | Facility |
| `nh_quality_msr_claims_oct2024` | NH_QualityMsr_Claims_Oct2024.csv | 59,256 | Facility × measure |

Column meanings for the source files are in CMS's `NH_Data_Dictionary.pdf` (in the source folder).

## Silver: `silver` and `quarantine`

Each dataset has one stored table per run. **`silver.<dataset>`** shows the valid rows, and **`quarantine.<dataset>`** shows the rejected ones; together they hold every row of the newest bronze file. All silver tables also carry `reject_reason` (empty in silver), `ingest_date` (the bronze partition) and `source_file` (the S3 path of the CSV).

### `pbj_daily_staffing` (facility × day)

| Column | Type | Description |
|---|---|---|
| `provnum` | string | CMS Certification Number (CCN), 6 characters, which can include a letter (`39A433`) |
| `provider_name`, `city`, `state`, `county_name`, `county_fips` | string | Facility name and location as reported in PBJ. `county_fips` is 3 digits as text. |
| `cy_qtr` | string | Calendar quarter (`2024Q2`) |
| `work_date` | date | The day the hours were worked |
| `mds_census` | int | Residents in the facility that day (MDS census) |
| `hrs_<role>` | double | Hours worked that day by role: `rndon`, `rnadmin`, `rn`, `lpnadmin`, `lpn`, `cna`, `natrn`, `med_aide` |
| `hrs_<role>_emp` / `hrs_<role>_ctr` | double | The same hours split into **employees** and **contract** staff |
| `total_nurse_hours` | double | Sum of the eight role totals |

### `provider_info` (facility, October 2024)

| Column | Type | Description |
|---|---|---|
| `provnum` | string | CCN |
| `provider_name`, `city`, `state`, `zip_code`, `county` | string | Facility name and location. `zip_code` is text. |
| `ownership_type` | string | CMS ownership category, for example `For profit - Corporation` |
| `ownership_group` | string | First part of the ownership type: `For profit`, `Non profit` or `Government` |
| `certified_beds` | int | Number of certified beds |
| `overall_rating`, `staffing_rating` | int | CMS Five-Star ratings, 1–5 (empty when not rated) |
| `cms_reported_total_hprd` | double | CMS's own reported total nurse HPRD for the facility (a different period from Q2 2024) |
| `nursing_staff_turnover` | double | % of nursing staff who left in the year (CMS) |

### `quality_claims` (facility × claims measure, October 2024)

| Column | Type | Description |
|---|---|---|
| `provnum` | string | CCN |
| `measure_code`, `measure_description` | string | CMS measure. **521** = % of short-stay residents rehospitalised after admission; **551** = hospitalisations per 1,000 long-stay resident days (also 522, 552: outpatient ER visits) |
| `resident_type` | string | Short stay or long stay |
| `adjusted_score`, `observed_score`, `expected_score` | double | Risk-adjusted, observed and expected values. **Empty when CMS suppresses the score** (too few residents). |
| `footnote_for_score`, `measure_period` | string | CMS footnote code and the period the measure covers |

### Reject reasons (`quarantine.*`)

The first rule that applies wins, in this order:

| `reject_reason` | Rule | Datasets |
|---|---|---|
| `missing_key` | The CCN (or the date or measure code) is empty | All |
| `invalid_ccn` | The CCN doesn't match `^[0-9]{2}[0-9A-Z][0-9]{3}$` | All |
| `invalid_type` | The date doesn't parse, or the census or any hours value isn't a number | PBJ |
| `negative_value` | The census or any hours value is below 0 | PBJ |
| `duplicate_in_file` | A second row for the same key in one file | All |
| `no_nursing_hours` | Residents present, but zero RN, LPN and aide hours (a reporting gap) | PBJ |
| `hprd_above_24` | Total HPRD above 24 (impossible) | PBJ |
| `invalid_beds` | Certified beds missing or not above 0 | ProviderInfo |

In the first build: 2,522 `no_nursing_hours` and 75 `hprd_above_24`; nothing else was rejected.

## Gold: `marts`

### `fact_daily_staffing` (facility × day)

Built from the valid PBJ silver rows. It includes the 24 `hrs_<role>[_emp|_ctr]` columns described in silver, plus:

| Column | Type | Description |
|---|---|---|
| `provnum`, `work_date` | string, date | **Key** |
| `mds_census` | int | Residents that day |
| `rn_hours`, `lpn_hours`, `aide_hours`, `total_nurse_hours` | double | Hours by CMS grouping |
| `contract_hours` | double | Sum of all `_ctr` hours |
| `hprd_eligible` | boolean | `mds_census > 0`: the day counts towards HPRD |
| `total_hprd`, `rn_hprd` | double | That day's HPRD (empty when there are no residents) |
| `below_total_benchmark` | boolean | `total_hprd < 3.48` |
| `below_rn_benchmark` | boolean | `rn_hprd < 0.55` |

### `dim_facility` (facility)

Every facility with valid staffing data, **left-joined** to ProviderInfo and the Claims measures, so facilities missing from the October file keep their staffing rows.

| Column | Type | Description |
|---|---|---|
| `provnum` | string | **Key** (CCN) |
| `provider_name`, `city`, `state`, `county_name`, `county_fips` | string | From PBJ, taken from the facility's latest day in the quarter |
| `ownership_type`, `ownership_group` | string | From ProviderInfo; `Unknown` when the facility isn't in it |
| `certified_beds`, `overall_rating`, `staffing_rating` | int | From ProviderInfo |
| `cms_reported_total_hprd`, `nursing_staff_turnover` | double | From ProviderInfo |
| `short_stay_rehospitalisation_pct` | double | Claims measure 521, risk-adjusted score |
| `long_stay_hospitalisations_per_1000_days` | double | Claims measure 551, risk-adjusted score |
| `in_provider_info` | boolean | False for the 17 facilities not in the October ProviderInfo file |

### `dim_date` (day)

| Column | Type | Description |
|---|---|---|
| `work_date` | date | **Key**, every day from the first to the last day of staffing data |
| `year`, `quarter`, `month` | bigint | Calendar parts |
| `month_start` | date | First day of the month |
| `day_of_week`, `day_name` | bigint, string | 1 = Monday … 7 = Sunday |
| `is_weekend` | boolean | Saturday or Sunday |

### `agg_facility_month` (facility × month)

The dashboard's metrics, pre-computed. Ratios are calculated from sums (Σ hours ÷ Σ resident days), never by averaging daily ratios.

| Column | Type | Description |
|---|---|---|
| `provnum`, `month_start` | string, date | **Key** |
| `days_reported`, `days_with_residents` | bigint | Days with a staffing row; of those, days with residents |
| `resident_days` | bigint | Σ `mds_census` |
| `avg_daily_census` | double | Average residents per reported day |
| `total_nurse_hours`, `rn_hours`, `lpn_hours`, `aide_hours`, `contract_hours` | double | Hours in the month |
| `total_hprd`, `rn_hprd`, `lpn_hprd`, `aide_hprd` | double | **Nursing hours per resident day** (hours on days with residents ÷ resident days) |
| `contract_share` | double | `contract_hours ÷ total_nurse_hours` |
| `below_total_benchmark_rate` | double | Share of days with residents where total HPRD < 3.48 |
| `below_rn_benchmark_rate` | double | Share of days with residents where RN HPRD < 0.55 |
| `below_either_benchmark_rate` | double | Share of days below either benchmark |
| `weekend_total_hprd`, `weekday_total_hprd` | double | Total HPRD on weekend and weekday days. **Weekend gap** = weekend − weekday. |
| `occupancy` | double | `avg_daily_census ÷ certified_beds`. Not capped: beds are from October 2024, so it can exceed 1. |

## Audit: `audit.check_results`

One row per check per run. Any `error` check with `failures > 0` stops the run before publishing.

| Column | Type | Description |
|---|---|---|
| `run_id` | string | For example `r20261009_022415` (from the run's start time) |
| `check_name` | string | For example `fact_key_unique`, `silver_rows_match_bronze` |
| `severity` | string | `error` (blocks publishing) or `warning` (recorded only) |
| `failures` | bigint | Number of failing rows or items; 0 = pass |
| `checked_at` | timestamp | When the check ran |

The checks themselves are in [`sql/checks/run_checks.sql`](../sql/checks/run_checks.sql).
