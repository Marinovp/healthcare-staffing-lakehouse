# Healthcare Metrics Pipeline: Solution Design (Summary)

| | |
|---|---|
| **Status** | Draft for SME review |
| **Version** | 0.13 summary (2026-09-29) |
| **Full design** | [solution-design.md](solution-design.md): component reasoning, data-quality rules, failure handling, security details |
| **Decision requested** | Approve the architecture below so the build (Step 4) can start |

## Purpose

Management needs one view of nursing-facility staffing: nurse hours, contract-staff use and resident census by facility, state and time, and where staffing is out of line with patient load. This pipeline moves the source files from Google Drive into an S3 data lake, transforms them with Athena SQL, and feeds a Streamlit dashboard. **Every component is an AWS service, and all of it is serverless.**

**Source:** CMS PBJ daily nurse staffing, Q2 2024 (about 1.3M rows, one per facility per day), plus 15 supporting CSVs. The data is public and facility-level, with no PHI. It has no beds, overtime, pay, readmission or length-of-stay fields, so metrics needing those are produced only if a supporting file provides them.

## Architecture

![Solution architecture](architecture.drawio.svg)

A run has five steps, orchestrated by **Step Functions** and **started by hand** (Step Functions console or AWS CLI), since this is a one-time project:

1. **Copy:** a Glue Python shell job compares the Drive folders with a DynamoDB manifest. It then checks each new or changed file's header, streams it to S3 `raw/`, and verifies its MD5.
2. **Anything new?** Step Functions checks the manifest. If no file was landed, the run ends here.
3. **Build + audit:** Athena reads the raw CSVs **in place** (no load step), writes this run's validated (silver) and modelled (gold) tables to S3, and runs the data checks.
4. **Publish:** only if the checks pass, the silver, quarantine and dashboard views are switched to the new tables, and old builds are cleaned up.
5. **Mark done:** the files are marked `PROCESSED` in the manifest.

The dashboard queries the published views through **Athena**.

## Medallion layers

| Layer | In this design |
|---|---|
| **Bronze** (raw) | The original CSV files in S3 `raw/`: never changed, versioned, the basis for rebuilding everything |
| **Silver** (clean) | One validated, typed table per dataset, built from the newest bronze file each run. Valid rows are published as `silver` views, and rejected rows as `quarantine` views with a reason. |
| **Gold** (business) | The star schema and metrics, built from the valid silver rows and published as the `marts` views the dashboard reads |

Silver and gold are Iceberg tables in S3 (Parquet), and each is published only after the run's checks pass.

## Services and why

| Service | Why |
|---|---|
| Step Functions | Orchestration with retries, run history and failure alerts. Runs the Glue job and Athena queries and waits for them natively. Started by hand, with no schedule. |
| Glue Python shell job | Copies the files from Drive with plain Python: no servers and no time limit, for a few cents a month. |
| DynamoDB | File manifest that makes ingestion incremental and restartable. |
| S3 | The data lake: original files (bronze), silver and gold tables, and query output. |
| Glue Data Catalog | Table definitions for Athena. (No Glue Spark jobs are used.) |
| Athena | All SQL: validation, building the marts, checks, and dashboard queries. Billed per data scanned, with nothing running between queries. |
| Secrets Manager | Holds the Google key. |
| CloudWatch + SNS | Logs, alarms and failure emails. |
| Terraform | Deploys all AWS resources, the raw table definitions and the build SQL, using the team's existing Terraform setup. |

## Key design choices

- **Lakehouse, not a database.** Data stays in S3, and Athena reads and writes it with SQL. There's no load step, no VPC, and nothing running (or billing) between runs. Rejected alternatives: Glue Spark jobs (built for data 100–1000× this size), Redshift (a full warehouse, VPC and higher cost), and dbt (needs a SaaS outside AWS or a container).
- **Write-audit-publish.** Each run builds new tables and checks them. The dashboard is switched to them only if the checks pass, so a bad build never reaches it, and the last three builds are kept for easy rollback.
- **Incremental and safe to rerun.** The manifest tracks each file as `LANDED` then `PROCESSED`, so a failure part-way through is picked up on the next run.
- **Newest file wins.** Only the newest file per dataset (per quarter for PBJ) is used, so a corrected file replaces the old one exactly. Older files stay in `raw/` as history.
- **Nothing dropped silently.** One validation view per dataset gives every invalid row a reason. Valid rows go on to silver and gold, and rejected rows appear in quarantine views that anyone can query. A file whose columns don't match the expected layout is stopped before upload.

## Data model and metrics

Star schema: `fact_daily_staffing` (facility × day), `dim_facility`, `dim_date`, and `agg_facility_month` (pre-computed metrics for the dashboard). The tables are Iceberg tables in S3, stored as Parquet.

| Metric | Definition |
|---|---|
| Nursing hours per resident day (HPRD): total, RN, LPN, nurse aide | Hours ÷ resident census, using CMS's hour groupings |
| Total nursing hours | By facility, state and month |
| Contract-staff share | Contract hours ÷ total nurse hours |
| Below-benchmark day rate | % of days under 3.48 total HPRD or 0.55 RN HPRD (the 2024 CMS rule, used as a benchmark only because its enforcement has been delayed) |
| Weekend staffing gap | Weekend HPRD − weekday HPRD |

Occupancy and quality metrics are added only if the supporting files contain beds or quality data.

## Security and cost

- **Data:** public CMS data with no PHI. S3 is encrypted, versioned and blocks public access.
- **Nothing to break into:** no VPC, no database endpoint and no database passwords. All access is through IAM.
- **Access:** one least-privilege IAM role per component. The dashboard can read only the published views. The Google access is read-only.
- **Cost:** **under $5 per month**. Athena charges per data scanned, and this data is well under 1 GB. Per-query scan limits and a budget alert guard against surprises.

## Decisions already made

- **Region:** `us-west-2` (Oregon), chosen for stability. Prices for these services are the same as in `us-east-1`.
- **Trigger:** manual. This is a one-time project, so there's no schedule.

## Main risks

| # | Risk | Handling |
|---|---|---|
| K1 | Supporting files may lack beds, overtime or length-of-stay data | Core metrics don't depend on them. Extra metrics only if the data exists. |
| K3 | Dashboard queries take 1–3 seconds | A 24-hour cache and small pre-aggregated tables hide it. |
| K4 | Glue Python shell must support the Google client library | Check the Python version when building, and pin a compatible library version. |
| K5 | The source layout changes | The header check stops the file before upload and alerts. Update the dataset definition and rerun. |

The full risk list (K1–K11) is in the [full design](solution-design.md).

## Approval

| Role | Name | Decision | Date | Comments |
|---|---|---|---|---|
| Subject Matter Expert | | ☐ Approved ☐ Approved with changes ☐ Rejected | | |
| Author | | Submitted | 2026-09-28 | |
