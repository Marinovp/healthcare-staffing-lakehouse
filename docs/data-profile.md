# Bronze Data Profile

| | |
|---|---|
| **Profiled** | 2026-10-09, bronze partition `ingest_date=2026-10-09` |
| **Queries** | [`sql/profiling/profile_bronze.sql`](../sql/profiling/profile_bronze.sql), run in Athena (workgroup `hsl-dev-pipeline`) |
| **Scope** | PBJ daily nurse staffing (Q2 2024), plus the two supporting files the metrics use: `NH_ProviderInfo` and `NH_QualityMsr_Claims` (October 2024) |

Every finding below leads to a decision for silver (Module 7) or for the metrics. All bronze columns are text, so values were checked exactly as delivered.

## Summary

- **PBJ is complete and clean at the grain:** 1,325,324 rows, 14,564 facilities × 91 days (2024-04-01 to 2024-06-30), with no duplicate facility-days, no negative hours and no unreadable numbers.
- **Facility IDs (CCNs) must stay text.** 235 facilities have a letter in their CCN (for example `39A433`). Typing CCNs as numbers would break queries, which is why bronze stores every column as text (see [Why bronze is all text](#why-bronze-is-all-text)).
- **About 0.2% of facility-days can't produce a meaningful HPRD** (no census, no hours, or an impossible value). Silver quarantines or excludes them with a reason.
- **All five planned metrics can be computed**, and the values are plausible: median total HPRD is 3.69, and contract staff provide 7.0% of nursing hours.
- **Occupancy and rehospitalisation are possible:** certified beds are present for every facility, and rehospitalisation scores exist for about 80% of facilities.

## PBJ daily nurse staffing

| Check | Result | Decision |
|---|---|---|
| Rows, facilities, days | 1,325,324 rows · 14,564 facilities · 91 days, 2024-04-01 to 2024-06-30 · all `CY_Qtr = 2024Q2` | Matches the source. The row count is a data check in Module 8. |
| Grain (one row per facility per day) | No duplicates | `(provnum, work_date)` is the fact table's key. Duplicates are a failing data check. |
| CCN format | All 14,564 match `^[0-9]{2}[0-9A-Z][0-9]{3}$`. **235 contain a letter.** | Keep as 6-character text. Reject rows that don't match the pattern. No `lpad` is needed, because text keeps leading zeros. |
| County FIPS, work date | All FIPS are 3 digits; all dates are `YYYYMMDD` | Keep FIPS as text. Parse `work_date` into a `date`, and reject rows that fail. |
| Census (`MDScensus`) | All integers. **320** facility-days have census 0. | Keep the row (its hours still count), but leave HPRD empty: there's no denominator. |
| Hours | All numeric · no negatives · RN employee + contract hours always equal the RN total | Keep a "negative hours" rejection rule as a guard, even though it doesn't fire today |
| Residents but no nursing hours | **2,522** facility-days (0.19%) have census above 0 and zero RN, LPN and aide hours | **Quarantine** ("no nursing hours reported"). It's almost certainly a reporting gap, and keeping it would show HPRD 0 and inflate the below-benchmark rate. |
| Hours but no residents | **165** facility-days | Covered by the census 0 rule: hours kept, HPRD empty |
| Impossible staffing | **75** facility-days with total HPRD above 24 (more than one nurse per resident around the clock) | **Quarantine** ("total HPRD above 24") |

### Metric preview (facility-days with census above 0)

| Metric | Result | Notes |
|---|---|---|
| Total nurse HPRD | 1st pct 1.86 · 25th 3.21 · **median 3.69** · 75th 4.27 · 99th 7.59 | In line with published CMS national figures |
| RN HPRD | 1st pct 0.06 · 25th 0.34 · **median 0.55** · 75th 0.84 · 99th 2.70 | |
| Contract-staff share | **7.0%** of nursing hours | |
| Weekend staffing gap | Weekend HPRD is **0.65 lower** than weekdays | A clear, explainable pattern for the dashboard |
| Below-benchmark days | Below 3.48 total HPRD: **38.5%** · below 0.55 RN HPRD: **49.2%** · below either: **60.3%** | **Report the two rates separately**, plus the combined one. The RN threshold sits almost exactly at the median, so the combined rate on its own would mostly reflect RN staffing. |

HPRD groups follow CMS: RN includes the director of nursing and RN admin; LPN includes LPN admin; aides are CNAs, aides in training and medication aides.

## Joining to the supporting files

| Check | Result | Decision |
|---|---|---|
| PBJ facilities found in ProviderInfo | **14,547 of 14,564** | Join PBJ to ProviderInfo with a **LEFT JOIN**. Missing attributes show as "Unknown", and no staffing rows are dropped. |
| The 17 missing facilities | All have the full 91 days of PBJ data. They're spread across 12 states (IL, IN, IA, KS, ME, MI, MN, MO, MT, OH, PA, RI, TX). | Most likely facilities that closed or changed CCN between Q2 and October 2024. Listed by query 8. |
| Exact key match | `provnum` = `cms_certification_number_ccn` as text, with no padding or conversion | Confirms the all-text decision |

## NH_ProviderInfo (one row per facility)

| Check | Result | Decision |
|---|---|---|
| Rows vs facilities | 14,814 rows · 14,814 distinct CCNs | One row per facility, so it's `dim_facility`'s source |
| Certified beds | Present for **every** facility, 4 to 843 beds, none zero | **Occupancy (census ÷ certified beds) can be computed.** Caveat: beds are as of October 2024, while census is Q2 2024. |
| Ownership type | 13 values. For profit 10,760 (72.6%) · non-profit 3,102 (20.9%) · government 952 (6.4%) | Add a grouped `ownership_group` (For profit / Non profit / Government) for the dashboard, and keep the detailed value too |

## NH_QualityMsr_Claims (rehospitalisation)

| Measure | Description | Facilities with no score |
|---|---|---|
| **521** | % of short-stay residents rehospitalised after admission | 2,886 of 14,814 (19.5%) |
| 522 | % of short-stay residents with an outpatient ER visit | 2,886 (19.5%) |
| **551** | Hospitalisations per 1,000 long-stay resident days | 3,176 (21.4%) |
| 552 | Outpatient ER visits per 1,000 long-stay resident days | 3,176 (21.4%) |

**Decision:** use **521** (short-stay rehospitalisation) and **551** (long-stay hospitalisation) for staffing-versus-outcome comparisons. Facilities without a score (usually too few residents for CMS to report one) are left out of those comparisons, not counted as zero. The measure periods differ from Q2 2024, which the dashboard states.

## Why bronze is all text

The first design let a **Glue crawler** infer column types. It infers types from a sample at the start of each file, and the guesses were wrong:

- `provnum` and most CCN columns were typed as numbers, but 235 PBJ facilities have CCNs like `39A433`.
- `hrs_rn_ctr` was typed as an integer because the first rows are all zero, but later rows hold values like `11.5`.

Athena failed on any query that read those columns (`BAD_DATA`). A crawler classifier can only override types column by column, file by file, so the crawler was removed. **`drive_sync` now registers each bronze table itself, from the file's header, with every column as text.** Silver does the type conversion in one place, and any value that doesn't convert goes to quarantine with a reason instead of failing the query or quietly becoming empty.

## Silver rules from this profile (Module 7)

| Dataset | Rule | Type |
|---|---|---|
| PBJ | CCN doesn't match `^[0-9]{2}[0-9A-Z][0-9]{3}$` | Reject |
| PBJ | `work_date` doesn't parse as a date, or census or hours aren't numbers | Reject |
| PBJ | Any hours value is negative | Reject |
| PBJ | Census above 0 and zero RN, LPN and aide hours | Reject: "no nursing hours reported" |
| PBJ | Total HPRD above 24 | Reject: "total HPRD above 24" |
| PBJ | Census = 0 | Keep the row, but leave HPRD empty |
| ProviderInfo | CCN pattern as above; duplicate CCNs | Reject |
| Claims | Score empty or not numeric | Keep the row, but leave the score empty and exclude it from comparisons |
| All | Join to ProviderInfo with a LEFT JOIN; missing attributes become "Unknown" | Modelling rule |
