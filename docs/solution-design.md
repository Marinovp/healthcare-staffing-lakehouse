# Healthcare Metrics Pipeline: Solution Design

| | |
|---|---|
| **Status** | Draft for SME review |
| **Version** | 0.17 (2026-10-09): the Glue crawler is removed. Its type guessing broke queries on PBJ (CCNs such as `39A433`), so `drive_sync` now registers each bronze table itself, with every column as text. Profiling results are in [data-profile.md](data-profile.md). (0.16: `drive_sync` as built: temporary file, one file at a time, verified by real runs. 0.15: Glue Python shell, Python 3.9, as provided by AWS. 0.14: Google Drive layout; UTF-8 conversion.) |
| **Decision requested** | Approve the architecture in §5 so the build (Step 4) can start |
| **Diagram** | [architecture.drawio.svg](architecture.drawio.svg): one file that is both the editable draw.io source and the image shown below |
| **Summary** | [solution-design-summary.md](solution-design-summary.md) |

---

## 1. Purpose

Management needs one view of nursing-facility staffing across the network: how nurse hours, contract-staff use, and resident census vary by facility, state, and time, and where staffing is out of line with patient load.

This document proposes an AWS pipeline that moves the source files from Google Drive into an S3 data lake, transforms them with Athena SQL, and serves the results to a Streamlit dashboard. It explains **what** each component does and **why** it was chosen.

## 2. Scope

**In scope**
- Incremental ingestion of the master CSV and 20 supporting CSVs from Google Drive into an S3 landing zone.
- Cleaning, modelling and checking the data with SQL in Amazon Athena, with results stored as tables in S3.
- A dimensional model and metric tables for the dashboard.
- Orchestration, alerting, security and cost controls, all deployed with Terraform.

**Out of scope**
- Real-time or streaming ingestion. The source is published quarterly.
- Public hosting of the dashboard. It runs locally against Athena for this phase (see §13).
- Patient-level or PHI data. None is present in the source.

## 3. Source data

| Item | Detail |
|---|---|
| Master file | `PBJ_Daily_Nurse_Staffing_Q2_2024.csv`: CMS Payroll-Based Journal. One row per facility per day, with 33 columns: facility identifiers, `MDScensus` (residents), and hours by role (RN, LPN, CNA, aides) split into employee vs contract. |
| Volume (profiled) | 209 MB, **1,325,324 rows**, each a distinct `(PROVNUM, WorkDate)`, covering **14,564 facilities** over the 91 days of Q2 2024. |
| Supporting files | **20 CSVs** plus `NH_Data_Dictionary.pdf`, from the CMS Provider Data Catalog for nursing homes, as of **October 2024**. The useful ones: `NH_ProviderInfo` (one row per facility, 14,814 facilities, 103 columns including **`Number of Certified Beds`** and **`Ownership Type`**) and `NH_QualityMsr_Claims` (hospitalisation and **rehospitalisation** measures). The other 18 are inspection, penalty, ownership, vaccination and reference tables. |
| Join key | The supporting files' `CMS Certification Number (CCN)` = PBJ's `PROVNUM`. **14,547 of the 14,564 PBJ facilities are in ProviderInfo**; 17 (0.1%) aren't, probably closed between Q2 and October. |
| Encoding | All files are UTF-8 **except PBJ, which is Windows-1252**: 455 lines (5 facilities × 91 days) have a curly apostrophe, en dash or non-breaking space in the facility name. |
| Time alignment | PBJ covers April–June 2024; the supporting files are an October 2024 snapshot. Facility attributes are therefore "as of October 2024". |
| Location | Google Drive folder **`HealthCare_Metrics/`**: PBJ at the top level, the supporting files in the subfolder `Nursing_Home_data/`. This folder stands in for the CMS source the brief describes. |
| Update pattern | Delivered once for this project. Corrections are re-delivered as replacement files. |
| Sensitivity | Public, facility-level aggregate data. No patient identifiers. |

**What the data can and can't support:** PBJ has no beds, shifts, overtime, pay, readmissions or length of stay. ProviderInfo supplies **certified beds** (so occupancy can be calculated) and **ownership type**, and the Claims file supplies **rehospitalisation** rates. Overtime, pay, shifts and length of stay remain unavailable, so those metrics aren't produced. The pipeline does not invent them.

## 4. Requirements

| # | Requirement | How it is met |
|---|---|---|
| R1 | AWS services only | Every component in §5 is an AWS service. Google Drive is only the external source. Terraform is a deployment tool, not part of the running system: everything it creates is an AWS resource. |
| R2 | Incremental ingestion from Google Drive | A file manifest compares Drive `md5Checksum` and `modifiedTime`, and only new or changed files are copied (§6). |
| R3 | Raw data kept, reprocessing possible | Files in S3 `raw/` are never modified. Every downstream table can be rebuilt from them. |
| R4 | Data quality visible | Every invalid row appears in a quarantine view with a reason, never dropped silently. Checks run on every build, before anything is published (§9). |
| R5 | Queryable warehouse layer for SQL analysis and the dashboard | A lakehouse with bronze, silver and gold layers (§5): the validated data and the star schema are Apache Iceberg tables in S3, catalogued in the Glue Data Catalog and queried with Athena (§8). |
| R6 | Reruns are safe, and a bad build never reaches the dashboard | Each run builds new tables and publishes them only after its checks pass (write-audit-publish, §10). Raw files are immutable, and the manifest tracks two states. |
| R7 | Controlled cost | Serverless, pay-per-query services with no always-on compute. Runs with no changes stop after one short Glue job. Athena workgroups cap how much data a query may scan (§11, §12). |
| R8 | Failures are noticed | Failed runs send an SNS email, and all logs go to CloudWatch (§11). |

## 5. Architecture

![Solution architecture](architecture.drawio.svg)

*To edit the diagram, open `architecture.drawio.svg` in draw.io (desktop, app.diagrams.net, or the VS Code Draw.io extension) and save. The same file is both the source and the image.*

**Flow in one paragraph.** Someone starts a Step Functions run by hand, from the console or the AWS CLI. First, a Glue Python shell job (`drive_sync`) lists the `HealthCare_Metrics/` Drive folder and its subfolder, and compares each file with the DynamoDB manifest. For every new or changed CSV file, it downloads the file, verifies the MD5 of the original bytes, converts the text to UTF-8, uploads it to S3 `raw/`, registers it as a bronze table (every column as text) with a new partition, and marks it `LANDED`. Step Functions then checks the manifest: if no file is `LANDED`, the run ends. Athena reads the landed CSVs **where they sit in S3**, so there is no load step. Step Functions runs the build as a series of Athena queries: it refreshes the validation views, writes this run's **silver** tables (validated data) and **gold** tables (the star schema and metrics) to S3 as Iceberg tables, and runs the data checks. Only if the checks pass does it **publish**: the silver, quarantine and dashboard views are switched to the new tables and old builds are cleaned up. Finally, the files are marked as processed. The Streamlit dashboard queries the published views through Athena.

### Why a lakehouse with Athena SQL

The files stay in S3 as they arrived. Athena queries them in place, and all cleaning and modelling is SQL that writes its results back to S3.

- **No load step and no warehouse to run.** Athena reads the raw CSVs directly, so there's no `COPY`, no database, no VPC, and nothing billing while idle.
- **Fewest moving parts.** Step Functions starts each Athena query and waits for it natively, so there's no polling loop and no transformation service to host.
- **Right-sized.** About 1.3M rows is small for Athena: queries take seconds, and a full build costs about a cent.
- **Fits the brief's data-lake design.** Raw, validated and modelled data all live in S3, with one catalog describing them.
- **Reprocessing is trivial:** S3 `raw/` holds every original file, and every table can be rebuilt from it.

**Alternatives rejected:**

| Option | Why not |
|---|---|
| **Glue ETL jobs (PySpark)** | Spark is built for data 100–1000× this size. It adds PySpark code and per-job cost, with no benefit at this volume. (The Drive retrieval does use Glue, but as a *Python shell* job, which runs plain Python without Spark: §6.) |
| **Redshift Serverless** | A full warehouse this data doesn't need. It needs a VPC, a load step and a polling loop, has cold starts, and costs about $10–25 a month versus under $5. |
| **dbt** | Needs either a SaaS outside AWS (dbt Cloud) or a container to build and run (dbt Core on Fargate). |

**Trade-offs accepted:**
- Athena has no transaction spanning several tables. The build uses write-audit-publish instead (§10), which gives the same guarantee that the dashboard only sees checked data.
- Dashboard queries take about 1–3 seconds instead of sub-second. A 24-hour cache hides this.
- There are no built-in tests or lineage graph as dbt would give. Checks are explicit queries (§9), and the data dictionary is maintained from the CMS dictionary, the catalog and the SQL (§13).

### Medallion layers (bronze, silver, gold)

The design follows the medallion pattern for data lakes. Each layer is built only from the one below it:

| Layer | Purpose | In this design | Stored as |
|---|---|---|---|
| **Bronze** | Source data as received, never changed afterwards; the basis for reprocessing | S3 `raw/`, read through the `raw` tables that `drive_sync` registers (every column as text) | The source CSV files (content unchanged, encoding normalised to UTF-8), versioned, partitioned by `ingest_date` |
| **Silver** | One clean, typed, validated version of each dataset | Built each run from the newest bronze file by the `base_` validation views, and stored in `builds/silver/`. Published as `silver.<dataset>` (valid rows) and `quarantine.<dataset>` (rejected rows, with a reason). | Iceberg tables (Parquet data files) |
| **Gold** | The business-ready model for the dashboard: star schema and metrics | Built each run from the valid silver rows, stored in `builds/gold/`, and published as the `marts` views | Iceberg tables (Parquet data files) |

Everything above bronze can be deleted and recreated just by rerunning the pipeline. One step beyond a basic medallion setup: silver and gold are **published only after the run's checks pass** (write-audit-publish, §10), so readers of either layer never see an unchecked build.

### Component choices

| Component | Role | Why this service | Alternatives considered |
|---|---|---|---|
| **Manual start** (Step Functions console or AWS CLI) | Starts a run when one is needed | This is a one-time project, so a schedule adds nothing. Clicking **Start execution**, or running `aws stepfunctions start-execution`, is all it takes. A rerun copies only new or changed files. | EventBridge Scheduler (a daily run), used until v0.11. |
| **Step Functions** (Standard) | Orders the steps, handles retries and branching, and records each run's history | The whole pipeline can be seen and rerun from the console. Starts the Glue job and waits for it natively (`.sync`), runs each Athena query and polls it every 3 seconds, and reads and updates DynamoDB directly. | MWAA (Airflow) needs an always-on environment of about $350/month, far too much for 5 steps. |
| **Glue Python shell job `drive_sync`** | Lists Drive, diffs against the manifest, and copies each new or changed CSV to S3 as UTF-8 after verifying its MD5 | Plain Python run by Glue on demand, with **no 15-minute limit**, so one job handles every file with no per-file splitting. **Runs Python 3.9**, the only version AWS offers for Glue Python shell jobs (per AWS's documentation). Glue is already in the design for its Data Catalog. Costs cents: 1/16 DPU with a 1-minute minimum. | Lambda: Python 3.14 and instant start, but a 15-minute limit that forced a split into two functions plus a Map state (used until v0.9). Glue 6.0 Spark job: Python 3.13, but a Spark cluster isn't needed to copy files. Both were compared on 2026-10-07; Python shell was kept for simplicity. |
| **Secrets Manager** | Stores the Google service-account key | Encrypted and access-controlled through IAM. Keeps credentials out of code, environment variables and Terraform state. | SSM Parameter Store (SecureString) also works. Secrets Manager was chosen for rotation support. |
| **DynamoDB manifest** | One item per Drive file: MD5, modified time, S3 key, status | Makes ingestion incremental and restartable. On-demand billing costs next to nothing at this volume. Step Functions reads and updates it natively. | A JSON manifest file in S3 has no per-item updates and needs custom code to change it. Listing S3 can't detect changed content. |
| **S3** | The data lake: `raw/` (bronze: original files), `builds/` (silver and gold tables), `athena-results/` (query output) | Cheap, durable storage separated from compute. The immutable raw copy is what makes every downstream table rebuildable. | |
| **Glue Data Catalog** | Table definitions for every table and view | Athena's metadata store, free at this size. Bronze tables are registered by `drive_sync` from each file's header (§7); silver, gold, quarantine and audit tables by the build SQL. | A Glue crawler (used until v0.16): it guessed column types from a sample, typed CCNs such as `39A433` as numbers, and broke queries on PBJ. Tables written by hand in Terraform: about 400 columns to maintain. |
| **Amazon Athena** | Runs all SQL: validation views, silver and gold builds, checks, and dashboard queries | Serverless SQL over S3, billed per data scanned ($5/TB), with no infrastructure. Reads CSV in place and writes Parquet-based Iceberg tables. | See "Alternatives rejected" above. |
| **Apache Iceberg** (table format) | Format of the silver and gold tables in `builds/` | Tables that Athena creates and drops cleanly, including their data files. Stored as Parquet, so gold builds and dashboard queries scan very little. | Plain Parquet tables leave their files behind when dropped, which would need a separate cleanup job. |
| **CloudWatch + SNS** | Logs, metrics, alarms, and failure email | Built in for Glue, Athena and Step Functions, with no extra tooling. | |
| **Terraform** | Defines all AWS resources as code, including the Glue job and the build SQL | Already the team's infrastructure tool, so there's one workflow (`plan` → `apply`) for everything. | AWS CDK or CloudFormation are AWS-native, but would add a second infrastructure tool alongside the existing Terraform setup. |

## 6. Incremental ingestion (`drive_sync` Glue job)

The job reads **one** Drive folder, `HealthCare_Metrics/`, recursively: PBJ sits at the top level and the supporting files in `Nursing_Home_data/`. The folder is identified by its **Drive ID**, not its name.

**`drive_sync`** (one Glue Python shell run per pipeline run):
1. Read the service-account key from Secrets Manager. Connect to the Drive API with the read-only scope `drive.readonly`.
2. List every file in `HealthCare_Metrics/` and its subfolders (id, name, MIME type, `md5Checksum`), following pagination, and keep only the **CSV** files. Anything else, such as the data dictionary PDF, is ignored.
3. Compare each CSV with the manifest. **New** (no item) or **changed** (a different `md5Checksum`) → copy it (steps 4–9). Anything else is skipped. An unchanged file that is still `LANDED` (a previous run failed after landing it) needs no action from the job, because it's already in S3 and Step Functions picks it up from the manifest.
4. **Download** the file in 8 MB chunks to a temporary file on the job's local disk (Glue provides about 14 GiB in `/tmp`). The Drive client retries 429 and 5xx errors with exponential backoff.
5. **Read it once, line by line.** Each line is added to the MD5 of the **original bytes**, decoded as UTF-8 or, failing that, as **Windows-1252** (the only other encoding found when profiling, used by PBJ), and written as **UTF-8** to a second temporary file. A line that is neither fails the file.
6. Compare the MD5 with Drive's value. If they don't match, the file fails **before anything is uploaded**.
7. **Upload** the UTF-8 file to `s3://<bucket>/raw/<dataset>/ingest_date=YYYY-MM-DD/<file name>`, where `<dataset>` is the file name in snake_case (for example `nh_provider_info_oct2024`). That folder becomes the bronze table's name. boto3's managed upload (`upload_fileobj`) sends large files as a multipart upload and retries failed parts itself.
8. **Register the bronze table** from the file's header (every column as text, §7) and add the `ingest_date` partition.
9. Write the manifest item with `status = LANDED` and the MD5. This happens **last**: if the job dies before it, the next run simply copies and registers the file again. The reverse order could mark a file as landed that never arrived.

**Why a temporary file, not a pure stream:** a file's encoding is only known after reading all of it (a single Windows-1252 byte in the last row makes the whole file Windows-1252). Spooling to local disk keeps memory use to one chunk at a time and keeps the code simple. Both temporary files are deleted as soon as the file is done.

**Why line by line:** decoding each line separately needs no separate detection pass. In theory, a Windows-1252 line could also be valid UTF-8, but that needs unusual byte sequences that don't occur in this data. PBJ's 455 affected lines (5 facility names) are converted correctly.

Files are copied **one at a time**: 21 files, about 600 MB in total, take a few minutes, well within the timeout, so threads would add complexity for little gain. If one file fails, the job carries on with the others, then **exits with an error** at the end. The run fails and alerts, but every good file is still landed, and the failed ones, which aren't in the manifest, are retried on the next run.

**Job settings:** **Python 3.9**, as provided by AWS for Python shell jobs. The `analytics` library set provides `boto3`. The Google client libraries are installed by Glue when the job starts, through the `--additional-python-modules` job parameter; Terraform reads their **pinned versions** from `glue/drive_sync/requirements.txt`, the same file used for local runs. The job's settings (Drive folder ID, bucket, manifest table, secret name, region) are passed as job arguments, so the same script runs on a laptop and in Glue. 1/16 DPU (1 GB of memory) to start, raised to 1 DPU if copying turns out slow. A 60-minute timeout, and 1 retry. **At most one concurrent run**, so Glue itself refuses to start a second copy job while one is active.

**How it's verified:** the job is a thin layer over the Drive, S3 and DynamoDB APIs, so it's checked by **real runs** instead of unit tests. (1) A first run lands every file. (2) A second run copies nothing, which proves the manifest makes it incremental. (3) Deleting one manifest item makes the next run copy exactly that file again, which proves the job can write to S3 and DynamoDB. (4) The UTF-8 copy of PBJ in S3 is slightly larger than the original, because Windows-1252 characters take 2–3 bytes in UTF-8. Runs (1) and (2) were done locally against `dev` on 2026-10-07: 21 files landed, then 0 copied. Check (3) was then run as the deployed Glue job, which copied the one file as expected.

**After the job:** Step Functions scans the manifest for `LANDED` items. The table holds one item per file, so the scan is tiny and needs no index. If there are none, the run ends. Otherwise, after a successful publish, the same list is used to set `status = PROCESSED` (a Map state calling DynamoDB `UpdateItem`).

**Why two statuses:** if the build fails after `drive_sync` has landed a file, the file stays `LANDED` and is picked up again on the next run. A single "ingested" flag would silently skip it forever.

## 7. Storage and raw tables

### S3 layout

| Prefix | Contents | Retention |
|---|---|---|
| `raw/` | Source files (CSV, UTF-8), in `raw/<dataset>/ingest_date=YYYY-MM-DD/`. Content as received; only the encoding is normalised. | Permanent |
| `builds/` | Silver (`builds/silver/`) and gold (`builds/gold/`) tables: Iceberg, with Parquet data files, one set per run | Every build is kept: old builds are dropped by hand when needed (§10) |
| `athena-results/` | Athena query output | Deleted after 7 days (lifecycle rule) |
| `audit/` | `check_results`: one row per check per run (Iceberg) | Permanent |
| `glue-scripts/` | The Glue job's script, uploaded by Terraform | Replaced on each deploy |

A bucket lifecycle rule also aborts unfinished multipart uploads after 7 days, so failed uploads don't leave hidden storage charges behind.

### Bronze tables (registered by `drive_sync`, no load step)

After uploading a file, `drive_sync` creates or updates its table in the `raw` database, then writes the manifest:
- **One table per dataset folder**, with the `ingest_date=` folders below it as **partitions**. Each landed file adds its partition.
- **Every column is text** (`string`). Codes such as the CCN (`015009`, `39A433`), county FIPS and ZIP keep their exact value, leading zeros included, and no query fails on a value of an unexpected type. Silver converts types in one place, and a value that doesn't convert is quarantined with a reason.
- **Column names come from the file's header**, converted to snake_case (`CMS Certification Number (CCN)` → `cms_certification_number_ccn`, `WorkDate` → `work_date`), so no query has to quote them.
- **OpenCSVSerde with the header line skipped**, so quoted values such as facility names containing commas parse correctly.
- **Schema changes** follow the file: if a new file has different columns, the table is updated to its header.
- Athena's `"$path"` pseudo-column tells each row which file it came from. The validation views use it to pick the newest file (§8).

**Why not a Glue crawler:** the crawler used until v0.16 guessed each column's type from a sample at the start of the file. It typed PBJ's `provnum` as a number, but 235 facilities have CCNs with a letter (`39A433`), and it typed `hrs_rn_ctr` as an integer because the early rows are zero. Athena then failed on any query reading those columns. A classifier can only override types column by column, file by file. Registering the tables in the job removes the problem, one service, the crawler's 10-minute minimum billing, and a polling loop in Step Functions. Details: [data-profile.md](data-profile.md#why-bronze-is-all-text).

Every landed file stays in `raw/` as history. Only the newest file of each dataset is used downstream, so a corrected file re-delivered under the same name lands in the same folder with a new `ingest_date` and replaces the old one.

## 8. Data model

```
BRONZE                          SILVER                                                               GOLD
raw (tables over CSV) → base_ views (newest file, validated) → builds.silver_<dataset>_<run>  → builds.<mart>_<run>
                                                                  │  published as                    │  published as
                                                                  ├→ silver.<dataset>   (valid rows)  └→ marts.<mart>
                                                                  └→ quarantine.<dataset> (rejected rows)

gold (marts):  dim_facility (1) ──< fact_daily_staffing >── (1) dim_date
                                              │
                                    agg_facility_month (metrics)
```

| Glue database | What it holds | Type |
|---|---|---|
| `raw` | **Bronze.** One table per dataset, registered by `drive_sync`: snake_case column names from the CSV header, every column as text, partitioned by `ingest_date` | Table over CSV files |
| `staging` | The validation logic: one `base_<dataset>` view per dataset. It reads only the **newest file** of the dataset (the newest `ingest_date` partition; each PBJ quarter is its own dataset, because the quarter is in the file name), casts the text columns to their types, and sets a `reject_reason` for every invalid row. Read once per run to build silver. | View |
| `builds` | Each run's stored tables, named with the run ID. **Silver:** `silver_<dataset>_<run_id>`, every row of the newest file with its `reject_reason`. **Gold:** `<mart>_<run_id>` (for example `fact_daily_staffing_r20260928_060012`), built from the valid silver rows. | Iceberg table |
| `silver` | **Published silver:** one view per dataset, the valid rows (empty `reject_reason`) of the latest published build | View |
| `quarantine` | **Published rejects:** one view per dataset, the rows of the same silver table where `reject_reason` is set | View |
| `marts` | **Published gold**, what the dashboard reads: one view per mart, pointing at the latest published build | View |
| `audit` | `check_results`: one row per check per run, with severity and failure count | Iceberg table |

| Mart | Grain | Key columns |
|---|---|---|
| `fact_daily_staffing` | Facility × day | `provnum`, `work_date`, `mds_census`, hours for each role (RN, RN DON, RN admin, LPN, LPN admin, CNA, NA trainee, med aide) split into `_emp` and `_ctr` |
| `dim_facility` | Facility | `provnum`, name, city, state, county, county FIPS, plus **ownership type and group**, **certified beds**, overall and staffing ratings and CMS's **reported HPRD** from `NH_ProviderInfo`, and **rehospitalisation** (Claims measures 521 and 551, empty when CMS suppresses the score). Built from PBJ's facilities **left-joined** to ProviderInfo, so the 17 facilities missing from ProviderInfo keep their staffing rows, with ownership "Unknown". |
| `dim_date` | Day | `work_date`, month, quarter, day of week, weekend flag. Generated for every day between the first and last date in the data. |
| `agg_facility_month` | Facility × month | Metrics below, pre-computed so dashboard queries stay small and fast |

**Core metrics** (all calculable from PBJ alone), defined once in the build SQL. Hour groupings follow CMS's own definitions, so results can be compared with published CMS figures:
- **RN hours** = `Hrs_RN` + `Hrs_RNDON` + `Hrs_RNadmin`
- **LPN hours** = `Hrs_LPN` + `Hrs_LPNadmin`
- **Nurse aide hours** = `Hrs_CNA` + `Hrs_NAtrn` + `Hrs_MedAide`
- **Total nurse hours** = RN + LPN + nurse aide hours

| Metric | Definition |
|---|---|
| Nursing hours per resident day (HPRD): total, RN, LPN, nurse aide | Σ hours / Σ `MDScensus` |
| Total nursing hours | Σ total nurse hours by facility, state, month |
| Contract-staff share | Σ contract (`_ctr`) hours / Σ total nurse hours |
| Below-benchmark day rates | % of days (with residents) below 3.48 total HPRD, % below 0.55 RN HPRD, and % below either. Reported **separately**: the RN threshold sits almost exactly at the national median, so the combined rate alone would mostly reflect RN staffing ([data profile](data-profile.md)). |
| Weekend staffing gap | Weekend HPRD − weekday HPRD |

The 3.48 / 0.55 thresholds come from the CMS minimum staffing rule published in 2024. That rule has since been challenged and its enforcement delayed, so it is used here **as a benchmark, not a legal requirement**. Its current status must be checked before the final report.

**Additional metrics enabled by the supporting files:** **occupancy** (average daily census ÷ certified beds, from ProviderInfo) and **rehospitalisation** rates (from the Claims measures), compared with HPRD. Both use October 2024 facility attributes against Q2 2024 staffing (§3). Occupancy is not capped: 261 facility-months exceed 105%, most likely because beds are counted in October 2024 while census is from Q2. The dashboard flags it rather than hiding it.

**Why newest file wins:** if a corrected file removes rows, keeping "the newest row per key" across files would leave the removed rows alive. Reading only the newest file makes a correction replace the dataset (or the quarter, for PBJ) exactly.

**Rebuild strategy:** every run builds silver from bronze, then gold from silver, from scratch. That takes seconds to minutes at this volume, guarantees every layer matches `raw`, and means a change to any table's SQL takes effect on the next run with no migration. Gold reads the compact Parquet silver tables rather than re-parsing the CSVs.

## 9. Data quality

Checks happen during ingestion (encoding), in the `base_` views, and as one check query that runs before anything is published.

| Check | Where | Action on failure |
|---|---|---|
| File is neither UTF-8 nor Windows-1252 | `drive_sync` | **The file fails and the run alerts.** |
| An expected column is missing (the source layout changed) | `base_` view | **The build fails**, because the view names the column. Nothing is published and the run alerts. |
| A code doesn't match its documented format (CCN `^[0-9]{2}[0-9A-Z][0-9]{3}$`, FIPS 3 digits) | `base_` view | Row quarantined with a reason (codes are text in bronze, so they arrive exactly as delivered, §7) |
| `PROVNUM` or `WorkDate` missing | `base_` view | `reject_reason = missing_key` → quarantine |
| `WorkDate` not a valid date; census or hours not numeric | `base_` view | `reject_reason = invalid_type` → quarantine |
| Census or any hours value < 0 | `base_` view | `reject_reason = negative_value` → quarantine |
| Same `(PROVNUM, WorkDate)` twice in one file | `base_` view | First row kept. Others get `reject_reason = duplicate_in_file` → quarantine. (None in the current file; the rule protects re-deliveries.) |
| Census > 0 but zero RN, LPN and aide hours (a reporting gap; 2,522 facility-days) | `base_` view | `reject_reason = no_nursing_hours` → quarantine |
| Total HPRD above 24 (impossible; 75 facility-days) | `base_` view | `reject_reason = hprd_above_24` → quarantine |
| Certified beds missing or not above 0 (ProviderInfo) | `base_` view | `reject_reason = invalid_beds` → quarantine |
| Census = 0 | `base_` view | Row kept. Its hours count, but it's excluded from HPRD so it can't divide by zero. |
| Each mart's key is unique and not null | Check query | **Error:** the build is not published |
| Every fact row has its facility in `dim_facility` and its day in `dim_date` | Check query | **Error** |
| Silver rows = rows of the newest bronze file, and fact rows = valid silver rows (nothing lost between layers) | Check query | **Error** |
| Daily HPRD within a plausible range (0–24) | Check query | Warning |
| Each facility's Q2 HPRD within ±50% of CMS's reported HPRD (`NH_ProviderInfo`, a different period, so informational; 32 facilities on the first build) | Check query | Warning |
| Row count of the newest file within ±20% of the previous file of the same dataset. Passes when there is no previous file. | Check query | Warning |

All check results are written to `audit.check_results`. If any error-level check has failures, Step Functions stops before publishing, the run fails, and the SNS alert names the failing checks. **The dashboard keeps showing the last good build.** Warnings don't stop the run and can be reviewed in the audit table.

The `silver` and `quarantine` views are two filters on the same stored silver table, so every row of the newest file lands in exactly one of them. The validation rules are written once, and nothing can be dropped silently. Anyone can query the quarantine views to see what was rejected and why.

## 10. Orchestration and failure handling

| Step | What happens | Retries | On final failure |
|---|---|---|---|
| 1. `drive_sync` (Glue job) | List Drive and compare with the manifest. For each new or changed CSV: download, MD5 check, convert to UTF-8, upload to `raw/`, mark `LANDED`. | Inside the job: exponential backoff on Drive API 429 and 5xx errors. Plus 1 retry of the whole job. | Run fails and alerts. Files that did land stay `LANDED` and are built on the next run. |
| 2. Anything to build? | Scan the manifest for `LANDED` files. None → end the run. | 3 attempts | Run fails and alerts. |
| 3. Build + audit | Athena queries in order: refresh the validation views, create this run's silver tables, then its gold tables, in `builds`, then write the check results | 1 retry for each query | Run fails and alerts. Nothing has been published. |
| 4. Publish | If no error-level check failed: point the `silver`, `quarantine` and `marts` views at this run's tables | Retries on Athena throttling | Run fails and alerts. See "Publishing" below. |
| 5. Mark `PROCESSED` | Update the manifest | 3 attempts | Run fails. The files are simply rebuilt next time, which is harmless. |

The Glue job is started with Step Functions' native `glue:startJobRun.sync` integration, which waits for it to finish. Athena queries are **not** run with `.sync`: that integration checks for completion only about once a minute, so the first automated run took 23 minutes for 23 queries that need about 3 minutes of actual Athena time. Instead, each query is started, then checked every 3 seconds (`getQueryExecution`) until it succeeds or fails. A failed query stops the run, with Athena's error message as the cause. The state machine uses **JSONata**. Terraform renders every file in `sql/` at deploy time and embeds them in the definition as two ordered lists, one for build and audit (12 statements) and one for publish (10). Each list is a `Map` state that runs one statement at a time, in order. The run ID (for example `r20261009_183005`) is built from the execution's start time and replaces a `__RUN_ID__` marker in each statement, so every run's tables have unique names. A SQL change therefore takes effect on the next `terraform apply`.

### Write-audit-publish

Athena can't wrap several tables in one transaction, so the build never writes into what the dashboard reads:
1. **Write:** each run creates its own new tables in `builds`.
2. **Audit:** the checks run against those new tables.
3. **Publish:** only if the checks pass are the `silver`, `quarantine` and `marts` views switched to the new tables.

A failed build is never published, and the dashboard keeps using the previous build. Earlier builds stay in `builds`, so going back to an earlier good build is just re-pointing the views. **Old builds are not dropped automatically:** this is a one-time project with a handful of runs, and each build is about 80 MB (well under a cent a month), so an automated cleanup step isn't worth its complexity. A long-running pipeline would add it.

**Publishing:** the views are switched by a Step Functions Map state, one at a time, so a publish takes seconds. The `silver` and `quarantine` views go first and the `marts` views last. If a publish query fails part-way, the views may briefly point at different builds, and the alert tells someone to rerun the run (§14 K10).

A Step Functions run timeout of 2 hours prevents hung runs. Start a run only after the previous one has finished. If a second run is started while one is active, Glue refuses its job (at most one concurrent run), so the second run stops at step 1.

## 11. Security and monitoring

- **Data sensitivity:** facility-level public CMS data with no PHI, so HIPAA controls don't apply. Baseline AWS controls are still used.
- **S3:** public access blocked, SSE-S3 encryption by default, TLS-only bucket policy, versioning on `raw/`.
- **No network or database to secure:** there's no VPC, no database endpoint and no database password. All access is through IAM-authenticated AWS APIs.
- **Athena workgroups:** `pipeline` for the build and `dashboard` for the app. Each has its own output location under `athena-results/` and a **per-query scan limit** (for example 10 GB), so a runaway query is stopped automatically.
- **IAM:** one least-privilege role per component:
  - `drive_sync` Glue job: read one secret, read `glue-scripts/`, write `raw/`, read and write the manifest table, register bronze tables, write its logs. The catalog and log permissions come from AWS's managed `AWSGlueServiceRole`, which allows all Glue actions. That's broader than the job needs (it only writes to the `raw` database), and is accepted for this one-time project. A production setup would replace it with a policy limited to the `raw` database and the job's log group.
  - Step Functions: start the `drive_sync` job; run queries in the `pipeline` workgroup; read `raw/`, write `builds/` and its results prefix; create and drop tables in the `staging`, `builds`, `silver`, `quarantine`, `marts` and `audit` databases; scan and update the manifest table.
  - Dashboard: run queries in the `dashboard` workgroup; read the `marts` views and the `builds/` data behind them; write its results prefix. *(Not created yet: the dashboard currently runs locally with the developer's credentials.)*
- **Google access:** the service account has read-only access to the shared `HealthCare_Metrics` folder only.
- **Monitoring:** the Glue job and Step Functions log to CloudWatch. An EventBridge rule on Step Functions `FAILED` or `TIMED_OUT` publishes to an SNS email topic.
- **Cost guard:** an AWS Budgets alert at $10 per month, alongside the workgroup scan limits.

## 12. Cost estimate (monthly, us-west-2, approximate)

| Service | Assumption | Cost |
|---|---|---|
| Step Functions, EventBridge (failure rule), DynamoDB | A handful of manual runs | ≈ $0 (free tier) |
| Glue job (`drive_sync`) | A few minutes per run at 1/16 DPU ($0.44 per DPU-hour, 1-minute minimum) | < $0.10 |
| Athena | A build reads the raw CSVs once to build silver, then small Parquet tables for gold (≈ $0.01). Dashboard queries read small Parquet tables (10 MB billing minimum each). | < $1 |
| Glue Data Catalog | Under 100 tables and views | $0 (free tier) |
| S3 | < 5 GB across all prefixes | ≈ $0.10 |
| Secrets Manager | 1 secret | $0.40 |
| **Total** | | **under $5 per month** |

## 13. Deployment and dashboard access

- All AWS resources are defined in one Terraform configuration and deployed to a single account in `us-west-2` (Oregon): S3 bucket and lifecycle rules, DynamoDB table, the `drive_sync` Glue job, Glue databases, Athena workgroups, state machine, failure alert (EventBridge rule and SNS topic) and budget.
- Terraform state is stored remotely (S3, encrypted, with state locking), in line with the existing Terraform setup. The job is an `aws_glue_job` of type `pythonshell`. It runs **Python 3.9**, as provided by AWS. Its script is uploaded to `glue-scripts/` with `aws_s3_object` on each `apply`, and the Google client libraries are installed by Glue at start (`--additional-python-modules`, pinned to the versions in `glue/drive_sync/requirements.txt`).
- **Bronze tables are not defined in Terraform.** The `drive_sync` job, which is, registers them from each file's header.
- **Build SQL** lives in the repository's `sql/` folder, one file per view, silver table, gold table and check. Terraform embeds the files into the state machine definition with `templatefile`, so each deploy ships exactly the SQL that runs, and there's no separate SQL deployment step.
- **Secrets stay out of Terraform state:** the Google key secret is *created* by Terraform, but its value is set once outside it (console or CLI).
- **Development vs production:** an `env` local (`dev` or `prod`) in each environment's root configuration (`terraform/envs/<env>`) prefixes every Glue database, S3 prefix and resource name. Changes are deployed and tested in `dev` first. The dashboard reads `prod` only.
- **Data dictionary (Step 7 deliverable):** `docs/data-dictionary.md`, written from the CMS data dictionary (`NH_Data_Dictionary.pdf` and the PBJ column list in the brief), the silver renames and the mart SQL, and checked against the Glue Data Catalog.
- The Streamlit dashboard (`dashboard/app.py`) runs locally. It queries the `marts` views in the `dashboard` workgroup (1 GB scan limit) with boto3, reading each result's CSV straight from S3, and caches results for 24 hours: two small queries load everything, and every filter is then re-aggregated in pandas from sums, so ratios stay correct. It runs with the developer's AWS credentials; a dedicated dashboard role (below) would be added before sharing it. `awswrangler` was not needed for two queries. If shared hosting is needed later, AWS App Runner or a small EC2 instance keeps it within AWS.

## 14. Risks and open questions

**Q** = question for the SME (both now decided), **K** = risk. (Requirements in §4 use **R**.)

| # | Item | Proposed handling |
|---|---|---|
| Q1 | AWS region | **Decided: `us-west-2` (Oregon).** Chosen for stability: `us-east-1` is AWS's oldest and busiest region and has had the most widely felt outages. Prices for the services in this design are the same in both regions. |
| Q2 | Schedule | **Decided: none.** This is a one-time project, so runs are started by hand from the Step Functions console or the AWS CLI. |
| K1 | Supporting files may lack beds, overtime, length of stay, or readmissions | **Partly resolved by profiling:** ProviderInfo has certified beds (occupancy) and the Claims file has rehospitalisation rates. Overtime, pay, shifts and length of stay remain unavailable, so those metrics aren't produced. |
| K2 | Athena cost grows (for example, a query over the raw CSVs from the dashboard) | The dashboard role can read only the `marts` views. Per-query scan limits on both workgroups. Budget alert. |
| K3 | Dashboard queries take 1–3 seconds | Acceptable for an internal dashboard. The 24-hour cache and small pre-aggregated tables hide it for repeat views. |
| K4 | Glue Python shell runs **only Python 3.9** (per AWS's documentation), and Python 3.9 stopped receiving upstream security fixes in October 2025 | Accepted for a one-time project. The job is developed and run locally in a **dedicated Python 3.9 environment** (`glue/drive_sync/.venv`), so local runs match AWS. Library versions are pinned to releases that support 3.9. The job's 60-minute timeout and the failure alert cover a copy that runs unexpectedly long. If the project continued, the job would move to Lambda (Python 3.14) or a newer Glue runtime. |
| K5 | Source layout changes (columns added, removed or reordered) | `drive_sync` updates the bronze table to the new header. The silver `base_` view names the columns it needs, so a missing column **fails the build** and alerts, and nothing is published. |
| K6 | Drive folder structure or file names change | The job reads one folder by its Drive ID, and the manifest is keyed on each file's Drive ID, not its name. New files are landed and registered as tables. |
| K7 | Google service-account key leak | Read-only scope on one folder, stored only in Secrets Manager, and rotated after the project. |
| K8 | Staffing benchmark thresholds lose relevance | Presented as benchmarks with their source and date. Current regulatory status checked before the final report. |
| K9 | Plain SQL has no automatic lineage or test framework (which dbt would give) | Checks are explicit queries logged in `audit.check_results`. Dependencies are kept simple (raw → views → builds → marts), and the data dictionary is maintained from the CMS dictionary, the catalog and the SQL. |
| K10 | Publishing switches the `silver`, `quarantine` and `marts` views in batches rather than all at once | For a few seconds, some views can point at a newer build than others. Accepted, because publishes are rare, the dashboard caches, and gold is switched last. A failed publish alerts, and a rerun fixes it. |
| K11 | Source files may not be UTF-8, which would garble text such as facility names | **Confirmed for PBJ** (Windows-1252, 455 lines, 5 facility names). Handled at ingestion: decoded as Windows-1252 and stored as UTF-8 (§6). |
| K12 | Inferred column types could misread identifier codes | **Happened and resolved (v0.17).** The crawler typed CCNs as numbers, but 235 PBJ facilities have codes like `39A433`, and queries failed. Bronze now stores every column as text, so codes arrive exactly as delivered. Silver checks their format and quarantines rows that don't match. |
| K13 | Snapshot dates differ: staffing is Q2 2024, facility attributes are October 2024 | Stated wherever attributes are used. Facilities missing from the snapshot keep their staffing rows (left join). |

## 15. Approval

| Role | Name | Decision | Date | Comments |
|---|---|---|---|---|
| Subject Matter Expert | | ☐ Approved ☐ Approved with changes ☐ Rejected | | |
| Author | | Submitted | 2026-09-28 | |
