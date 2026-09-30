# Healthcare Metrics Pipeline: Solution Design

| | |
|---|---|
| **Status** | Draft for SME review |
| **Version** | 0.13 (2026-09-29): silver layer stored as Iceberg tables, and the medallion (bronze/silver/gold) mapping added. (0.12: runs started by hand.) |
| **Decision requested** | Approve the architecture in §5 so the build (Step 4) can start |
| **Diagram** | [architecture.drawio.svg](architecture.drawio.svg): one file that is both the editable draw.io source and the image shown below |
| **Summary** | [solution-design-summary.md](solution-design-summary.md) |

---

## 1. Purpose

Management needs one view of nursing-facility staffing across the network: how nurse hours, contract-staff use, and resident census vary by facility, state, and time, and where staffing is out of line with patient load.

This document proposes an AWS pipeline that moves the source files from Google Drive into an S3 data lake, transforms them with Athena SQL, and serves the results to a Streamlit dashboard. It explains **what** each component does and **why** it was chosen.

## 2. Scope

**In scope**
- Incremental ingestion of the master CSV and 15 supporting CSVs from Google Drive into an S3 landing zone.
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
| Expected volume | About 15,000 facilities × 91 days ≈ 1.3M rows, a few hundred MB of CSV (confirmed during EDA). |
| Supporting files | 15 CSVs in `Supporting_CSV/`. Expected to be CMS facility reference and quality tables joined on `PROVNUM` (CCN). The exact list and keys are confirmed during EDA. |
| Location | Google Drive folders `Nursing_Data/` and `Supporting_CSV/` |
| Update pattern | New quarters and occasional corrections. Files arrive in batches, not continuously. |
| Sensitivity | Public, facility-level aggregate data. No patient identifiers. |

**Important limitation:** the source has no bed counts, shifts, overtime, pay, readmission or length-of-stay fields. Metrics that need these are only produced if a supporting file supplies them. The pipeline does not invent them.

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

**Flow in one paragraph.** Someone starts a Step Functions run by hand, from the console or the AWS CLI. First, a Glue Python shell job (`drive_sync`) lists both Drive folders and compares each file with the DynamoDB manifest. For every new or changed file, it checks the header, streams the file into S3 `raw/`, verifies its MD5, and marks it `LANDED`. Step Functions then checks the manifest: if no file is `LANDED`, the run ends. Athena reads the landed CSVs **where they sit in S3**, so there is no load step. Step Functions runs the build as a series of Athena queries: it refreshes the validation views, writes this run's **silver** tables (validated data) and **gold** tables (the star schema and metrics) to S3 as Iceberg tables, and runs the data checks. Only if the checks pass does it **publish**: the silver, quarantine and dashboard views are switched to the new tables and old builds are cleaned up. Finally, the files are marked as processed. The Streamlit dashboard queries the published views through Athena.

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
- There are no built-in tests or lineage graph as dbt would give. Checks are explicit queries (§9), and the data dictionary is maintained from the dataset definitions (§13).

### Medallion layers (bronze, silver, gold)

The design follows the medallion pattern for data lakes. Each layer is built only from the one below it:

| Layer | Purpose | In this design | Stored as |
|---|---|---|---|
| **Bronze** | Source data exactly as received, never changed; the basis for reprocessing | S3 `raw/`, read through the `raw` tables in the Glue Data Catalog | The original CSV files, versioned, partitioned by `ingest_date` |
| **Silver** | One clean, typed, validated version of each dataset | Built each run from the newest bronze file by the `base_` validation views, and stored in `builds/silver/`. Published as `silver.<dataset>` (valid rows) and `quarantine.<dataset>` (rejected rows, with a reason). | Iceberg tables (Parquet data files) |
| **Gold** | The business-ready model for the dashboard: star schema and metrics | Built each run from the valid silver rows, stored in `builds/gold/`, and published as the `marts` views | Iceberg tables (Parquet data files) |

Everything above bronze can be deleted and recreated just by rerunning the pipeline. One step beyond a basic medallion setup: silver and gold are **published only after the run's checks pass** (write-audit-publish, §10), so readers of either layer never see an unchecked build.

### Component choices

| Component | Role | Why this service | Alternatives considered |
|---|---|---|---|
| **Manual start** (Step Functions console or AWS CLI) | Starts a run when one is needed | This is a one-time project, so a schedule adds nothing. Clicking **Start execution**, or running `aws stepfunctions start-execution`, is all it takes. A rerun copies only new or changed files. | EventBridge Scheduler (a daily run), used until v0.11. |
| **Step Functions** (Standard) | Orders the steps, handles retries and branching, and records each run's history | The whole pipeline can be seen and rerun from the console. Starts the Glue job and each Athena query and waits for them natively (`.sync`), and reads and updates DynamoDB directly. | MWAA (Airflow) needs an always-on environment of about $350/month, far too much for 5 steps. |
| **Glue Python shell job `drive_sync`** | Lists Drive, diffs against the manifest, and for each changed file checks the header, streams it to S3 and verifies its MD5 | Plain Python run by Glue on demand, with **no 15-minute limit**, so one job handles every file with no per-file splitting. Glue is already in the design for its Data Catalog. Costs cents: 1/16 DPU with a 1-minute minimum. | Lambda: instant start, but its 15-minute limit forced a split into two functions plus a Step Functions Map state (used until v0.9). Glue Spark jobs: a Spark cluster isn't needed to copy files. |
| **Secrets Manager** | Stores the Google service-account key | Encrypted and access-controlled through IAM. Keeps credentials out of code, environment variables and Terraform state. | SSM Parameter Store (SecureString) also works. Secrets Manager was chosen for rotation support. |
| **DynamoDB manifest** | One item per Drive file: MD5, modified time, S3 key, status | Makes ingestion incremental and restartable. On-demand billing costs next to nothing at this volume. Step Functions reads and updates it natively. | A JSON manifest file in S3 has no per-item updates and needs custom code to change it. Listing S3 can't detect changed content. |
| **S3** | The data lake: `raw/` (bronze: original files), `builds/` (silver and gold tables), `athena-results/` (query output) | Cheap, durable storage separated from compute. The immutable raw copy is what makes every downstream table rebuildable. | |
| **Glue Data Catalog** | Table definitions for every bronze, silver and gold table and view | Athena's metadata store. Free at this size, and raw tables are defined in Terraform. Glue's only other use here is the retrieval job (above). There are no Glue Spark jobs. | Glue crawlers can guess column types wrongly, so tables are defined explicitly instead. |
| **Amazon Athena** | Runs all SQL: validation views, silver and gold builds, checks, and dashboard queries | Serverless SQL over S3, billed per data scanned ($5/TB), with no infrastructure. Reads CSV in place and writes Parquet-based Iceberg tables. | See "Alternatives rejected" above. |
| **Apache Iceberg** (table format) | Format of the silver and gold tables in `builds/` | Tables that Athena creates and drops cleanly, including their data files. Stored as Parquet, so gold builds and dashboard queries scan very little. | Plain Parquet tables leave their files behind when dropped, which would need a separate cleanup job. |
| **CloudWatch + SNS** | Logs, metrics, alarms, and failure email | Built in for Glue, Athena and Step Functions, with no extra tooling. | |
| **Terraform** | Defines all AWS resources as code, including the raw table definitions and the build SQL | Already the team's infrastructure tool, so there's one workflow (`plan` → `apply`) for everything. | AWS CDK or CloudFormation are AWS-native, but would add a second infrastructure tool alongside the existing Terraform setup. |

## 6. Incremental ingestion (`drive_sync` Glue job)

The expected columns of every dataset are defined once, in `datasets.json` in the repository. Terraform reads it to create the raw tables (§7), and uploads it next to the job script for the header check.

**`drive_sync`** (one Glue Python shell run per pipeline run):
1. Read the service-account key from Secrets Manager. Connect to the Drive API with the read-only scope `drive.readonly`.
2. List every file in `Nursing_Data/` and `Supporting_CSV/` (id, name, MIME type, `md5Checksum`, `modifiedTime`, size).
3. For each file, look up its manifest item:
   - **Not a CSV** (for example, a Google Sheet or PDF) → skip it and log a warning, so an unexpected file is visible rather than silently ignored.
   - **New** (no item) or **changed** (different `md5Checksum`) → copy it (steps 4–7).
   - **Unchanged and `PROCESSED`** → skip.
   - **Unchanged but `LANDED`** (a previous run failed after landing it) → nothing to do. It's already in S3, and this run's build picks it up.
4. **Check the header.** Read the file's first line and compare it with the dataset's columns in `datasets.json`. If they don't match, fail this file before uploading anything. The source layout has changed and a person needs to look (§14 K5).
5. **Stream** the file to `s3://<bucket>/raw/<dataset>/ingest_date=YYYY-MM-DD/<file name>`. The Drive download stream is passed to boto3's managed upload (`upload_fileobj`) through a small wrapper that updates the MD5 as bytes pass. boto3 splits the stream into a multipart upload and retries failed parts itself. Memory use stays constant whatever the file size.
6. Compare the calculated MD5 with Drive's value. If they don't match, delete the uploaded object and fail this file.
7. Write the manifest item with `status = LANDED`.

Steps 4–7 run for up to 4 files at a time, in threads. If one file fails, the job carries on with the others, then **exits with an error** at the end. The run fails and alerts, but every good file is still landed.

**Job settings:** 1/16 DPU (1 GB of memory) to start, raised to 1 DPU if copying turns out slow. A 60-minute timeout. **At most one concurrent run**, so Glue itself refuses to start a second copy job while one is active.

**After the job:** Step Functions scans the manifest for `LANDED` items. The table holds one item per file, so the scan is tiny and needs no index. If there are none, the run ends. Otherwise, after a successful publish, the same list is used to set `status = PROCESSED` (a Map state calling DynamoDB `UpdateItem`).

**Why two statuses:** if the build fails after `drive_sync` has landed a file, the file stays `LANDED` and is picked up again on the next run. A single "ingested" flag would silently skip it forever.

## 7. Storage and raw tables

### S3 layout

| Prefix | Contents | Retention |
|---|---|---|
| `raw/` | Files exactly as downloaded (CSV), in `raw/<dataset>/ingest_date=YYYY-MM-DD/` | Permanent |
| `builds/` | Silver (`builds/silver/`) and gold (`builds/gold/`) tables: Iceberg, with Parquet data files, one set per run | Kept for the three most recent builds (§10) |
| `athena-results/` | Athena query output | Deleted after 7 days (lifecycle rule) |
| `glue-scripts/` | The Glue job's script, the Google client library (a wheel file) and `datasets.json`, uploaded by Terraform | Replaced on each deploy |

A bucket lifecycle rule also aborts unfinished multipart uploads after 7 days, so failed streams don't leave hidden storage charges behind.

### Raw tables (no load step)

Each dataset has one table in the Glue Data Catalog, defined by Terraform from `datasets.json` and pointing at `raw/<dataset>/`:
- **Every column is a string** (OpenCSVSerde, header row skipped), so a malformed value never breaks a query. Values are checked and cast in the validation views, where failures can be quarantined.
- **Partition projection on `ingest_date`** tells Athena how the folders are named, so a newly landed file is queryable immediately, with no partition maintenance or crawler.
- Athena's `"$path"` pseudo-column tells each row which file it came from. The validation views use it to pick the newest file (§8).

Every landed file stays in `raw/` as history. Only the newest one is used downstream. A file in Drive with no dataset in `datasets.json` is still landed in S3 and reported in the run output, but no table reads it.

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
| `raw` | **Bronze.** One table per dataset: all columns strings, partitioned by `ingest_date` | Table over CSV files |
| `staging` | The validation logic: one `base_<dataset>` view per dataset. It reads only the **newest file** of the dataset (for PBJ, the newest file per `CY_Qtr`), renames and casts columns, and sets a `reject_reason` for every invalid row. Read once per run to build silver. | View |
| `builds` | Each run's stored tables, named with the run ID. **Silver:** `silver_<dataset>_<run_id>`, every row of the newest file with its `reject_reason`. **Gold:** `<mart>_<run_id>` (for example `fact_daily_staffing_r20260928_060012`), built from the valid silver rows. | Iceberg table |
| `silver` | **Published silver:** one view per dataset, the valid rows (empty `reject_reason`) of the latest published build | View |
| `quarantine` | **Published rejects:** one view per dataset, the rows of the same silver table where `reject_reason` is set | View |
| `marts` | **Published gold**, what the dashboard reads: one view per mart, pointing at the latest published build | View |
| `audit` | `check_results`: one row per check per run, with severity and failure count | Iceberg table |

| Mart | Grain | Key columns |
|---|---|---|
| `fact_daily_staffing` | Facility × day | `provnum`, `work_date`, `mds_census`, hours for each role (RN, RN DON, RN admin, LPN, LPN admin, CNA, NA trainee, med aide) split into `_emp` and `_ctr` |
| `dim_facility` | Facility | `provnum`, name, city, state, county, county FIPS. Extra attributes (ownership type, certified beds) are added if the supporting files provide them. |
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
| Below-benchmark day rate | % of days with total HPRD < 3.48 or RN HPRD < 0.55 |
| Weekend staffing gap | Weekend HPRD − weekday HPRD |

The 3.48 / 0.55 thresholds come from the CMS minimum staffing rule published in 2024. That rule has since been challenged and its enforcement delayed, so it is used here **as a benchmark, not a legal requirement**. Its current status must be checked before the final report.

**Conditional metrics**, added only if supporting data exists: occupancy (average census / certified beds), and rehospitalization or quality measures correlated with HPRD.

**Why newest file wins:** if a corrected file removes rows, keeping "the newest row per key" across files would leave the removed rows alive. Reading only the newest file makes a correction replace the dataset (or the quarter, for PBJ) exactly.

**Rebuild strategy:** every run builds silver from bronze, then gold from silver, from scratch. That takes seconds to minutes at this volume, guarantees every layer matches `raw`, and means a change to any table's SQL takes effect on the next run with no migration. Gold reads the compact Parquet silver tables rather than re-parsing the CSVs.

## 9. Data quality

Checks happen before upload (header), in the `base_` views, and as one check query that runs before anything is published.

| Check | Where | Action on failure |
|---|---|---|
| Header doesn't match the dataset's columns | `drive_sync` | **The file fails and the run alerts.** The layout changed, so a person needs to look. |
| `PROVNUM` or `WorkDate` missing | `base_` view | `reject_reason = missing_key` → quarantine |
| `WorkDate` not a valid date; census or hours not numeric | `base_` view | `reject_reason = invalid_type` → quarantine |
| Census or any hours value < 0 | `base_` view | `reject_reason = negative_value` → quarantine |
| Same `(PROVNUM, WorkDate)` twice in one file | `base_` view | First row kept. Others get `reject_reason = duplicate_in_file` → quarantine |
| Census = 0 but nursing hours > 0 | `base_` view | Row kept with a flag. Excluded from HPRD so it can't divide by zero. |
| Each mart's key is unique and not null | Check query | **Error:** the build is not published |
| Every fact `provnum` exists in `dim_facility` | Check query | **Error** |
| HPRD within a plausible range (0–24) | Check query | Warning |
| Row count of the newest file within ±20% of the previous file of the same dataset. Passes when there is no previous file. | Check query | Warning |

All check results are written to `audit.check_results`. If any error-level check has failures, Step Functions stops before publishing, the run fails, and the SNS alert names the failing checks. **The dashboard keeps showing the last good build.** Warnings don't stop the run and can be reviewed in the audit table.

The `silver` and `quarantine` views are two filters on the same stored silver table, so every row of the newest file lands in exactly one of them. The validation rules are written once, and nothing can be dropped silently. Anyone can query the quarantine views to see what was rejected and why.

## 10. Orchestration and failure handling

| Step | What happens | Retries | On final failure |
|---|---|---|---|
| 1. `drive_sync` (Glue job) | List Drive and compare with the manifest. For each changed file: header check, stream to `raw/`, MD5 check, mark `LANDED`. | Inside the job: exponential backoff on Drive API 429 and 5xx errors. Plus 1 retry of the whole job. | Run fails and alerts. Files that did land stay `LANDED` and are built on the next run. |
| 2. Anything to build? | Scan the manifest for `LANDED` files. None → end the run. | 3 attempts | Run fails and alerts. |
| 3. Build + audit | Athena queries, in order: refresh the validation views, create this run's silver tables, then its gold tables, in `builds`, then write the check results | 1 retry per query | Run fails and alerts. Nothing has been published. |
| 4. Publish | If no error-level check failed: point the `silver`, `quarantine` and `marts` views at this run's tables, then drop builds older than the three most recent | 1 retry per query | Run fails and alerts. See "Publishing" below. |
| 5. Mark `PROCESSED` | Update the manifest | 3 attempts | Run fails. The files are simply rebuilt next time, which is harmless. |

The Glue job and every Athena query are started with Step Functions' native integrations (`glue:startJobRun.sync` and `athena:startQueryExecution.sync`), which wait for them to finish. There's no polling loop. The build SQL is part of the state machine definition (§13), and the run ID comes from the run's start time, so every table name is unique.

### Write-audit-publish

Athena can't wrap several tables in one transaction, so the build never writes into what the dashboard reads:
1. **Write:** each run creates its own new tables in `builds`.
2. **Audit:** the checks run against those new tables.
3. **Publish:** only if the checks pass are the `silver`, `quarantine` and `marts` views switched to the new tables.

A failed build is never published, and the dashboard keeps using the previous build. The three most recent builds are kept, so going back to an earlier good build is just re-pointing the views.

**Publishing:** the views are switched by a Step Functions Map state, several at a time, so a publish takes seconds. The `silver` and `quarantine` views go first and the `marts` views last. If a publish query fails part-way, the views may briefly point at different builds, and the alert tells someone to rerun the run (§14 K10).

A Step Functions run timeout of 2 hours prevents hung runs. Start a run only after the previous one has finished. If a second run is started while one is active, Glue refuses its job (at most one concurrent run), so the second run stops at step 1.

## 11. Security and monitoring

- **Data sensitivity:** facility-level public CMS data with no PHI, so HIPAA controls don't apply. Baseline AWS controls are still used.
- **S3:** public access blocked, SSE-S3 encryption by default, TLS-only bucket policy, versioning on `raw/`.
- **No network or database to secure:** there's no VPC, no database endpoint and no database password. All access is through IAM-authenticated AWS APIs.
- **Athena workgroups:** `pipeline` for the build and `dashboard` for the app. Each has its own output location under `athena-results/` and a **per-query scan limit** (for example 10 GB), so a runaway query is stopped automatically.
- **IAM:** one least-privilege role per component:
  - `drive_sync` Glue job: read one secret, read `glue-scripts/`, write `raw/`, read and write the manifest table, write its logs.
  - Step Functions: start the `drive_sync` job; run queries in the `pipeline` workgroup; read `raw/`, write `builds/` and its results prefix; create and drop tables in the `staging`, `builds`, `silver`, `quarantine`, `marts` and `audit` databases; scan and update the manifest table.
  - Dashboard: run queries in the `dashboard` workgroup; read the `marts` views and the `builds/` data behind them; write its results prefix.
- **Google access:** the service account has read-only access to the two shared folders only.
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

- All AWS resources are defined in one Terraform configuration and deployed to a single account in `us-west-2` (Oregon): S3 bucket and lifecycle rules, DynamoDB table, the `drive_sync` Glue job, Glue databases and raw tables, Athena workgroups, state machine, failure alert (EventBridge rule and SNS topic) and budget.
- Terraform state is stored remotely (S3, encrypted, with state locking), in line with the existing Terraform setup. The job is an `aws_glue_job` of type `pythonshell`. Its script, the Google client wheel and `datasets.json` are uploaded to `glue-scripts/` with `aws_s3_object` on each `apply`.
- **Raw tables** are `aws_glue_catalog_table` resources generated from `datasets.json`, with column descriptions as comments.
- **Build SQL** lives in the repository's `sql/` folder, one file per view, silver table, gold table and check. Terraform embeds the files into the state machine definition with `templatefile`, so each deploy ships exactly the SQL that runs, and there's no separate SQL deployment step.
- **Secrets stay out of Terraform state:** the Google key secret is *created* by Terraform, but its value is set once outside it (console or CLI).
- **Development vs production:** a Terraform `env` variable (`dev` or `prod`) prefixes every Glue database, S3 prefix and resource name. Changes are deployed and tested in `dev` first. The dashboard reads `prod` only.
- **Data dictionary (Step 7 deliverable):** `docs/data-dictionary.md`, written from the column descriptions in `datasets.json` and the mart SQL files, and checked against the Glue Data Catalog.
- The Streamlit dashboard runs locally using the dashboard role. It queries the `marts` views through Athena (via `awswrangler`) and caches results for 24 hours. If shared hosting is needed later, AWS App Runner or a small EC2 instance keeps it within AWS.

## 14. Risks and open questions

**Q** = question for the SME (both now decided), **K** = risk. (Requirements in §4 use **R**.)

| # | Item | Proposed handling |
|---|---|---|
| Q1 | AWS region | **Decided: `us-west-2` (Oregon).** Chosen for stability: `us-east-1` is AWS's oldest and busiest region and has had the most widely felt outages. Prices for the services in this design are the same in both regions. |
| Q2 | Schedule | **Decided: none.** This is a one-time project, so runs are started by hand from the Step Functions console or the AWS CLI. |
| K1 | Supporting files may lack beds, overtime, length of stay, or readmissions | Core metrics don't depend on them. Conditional metrics are included only if EDA finds the fields. |
| K2 | Athena cost grows (for example, a query over the raw CSVs from the dashboard) | The dashboard role can read only the `marts` views. Per-query scan limits on both workgroups. Budget alert. |
| K3 | Dashboard queries take 1–3 seconds | Acceptable for an internal dashboard. The 24-hour cache and small pre-aggregated tables hide it for repeat views. |
| K4 | Glue Python shell supports fewer Python versions than Lambda, and the Google client library must run on it | Check the supported Python version when building, and pin a compatible version of the Google client library. The job's 60-minute timeout and the failure alert cover a copy that runs unexpectedly long. |
| K5 | Source layout changes (columns added, removed or reordered) | `drive_sync`'s header check fails the file and the run alerts. Update `datasets.json`, apply Terraform, and rerun. |
| K6 | Drive folder structure or file names change | The manifest is keyed on Drive file ID, not name. Unknown files are landed and reported, not read. |
| K7 | Google service-account key leak | Read-only scope on two folders, stored only in Secrets Manager, and rotated after the project. |
| K8 | Staffing benchmark thresholds lose relevance | Presented as benchmarks with their source and date. Current regulatory status checked before the final report. |
| K9 | Plain SQL has no automatic lineage or test framework (which dbt would give) | Checks are explicit queries logged in `audit.check_results`. Dependencies are kept simple (raw → views → builds → marts), and the data dictionary is maintained from `datasets.json` and the SQL. |
| K10 | Publishing switches the `silver`, `quarantine` and `marts` views in batches rather than all at once | For a few seconds, some views can point at a newer build than others. Accepted, because publishes are rare, the dashboard caches, and gold is switched last. A failed publish alerts, and a rerun fixes it. |
| K11 | Source files may not be UTF-8, which would garble text such as facility names | EDA checks the encoding. If needed, the raw table definition declares the file's encoding. |

## 15. Approval

| Role | Name | Decision | Date | Comments |
|---|---|---|---|---|
| Subject Matter Expert | | ☐ Approved ☐ Approved with changes ☐ Rejected | | |
| Author | | Submitted | 2026-09-28 | |
