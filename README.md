# Healthcare Staffing Lakehouse

An AWS lakehouse that turns CMS nursing-home staffing data (Payroll-Based Journal, Q2 2024, ~1.3M daily facility records) into staffing metrics and a dashboard: nurse hours per resident day, contract-staff share, and how often facilities fall below the CMS 2024 staffing benchmark.

> 🚧 **In progress.** Built step by step. See the [roadmap](#roadmap).

## Architecture

![Solution architecture](docs/architecture.drawio.svg)

- **Ingestion:** a Glue Python shell job copies CSVs from Google Drive into S3 incrementally, tracked in a DynamoDB manifest.
- **Medallion layers:** bronze (raw CSV in S3), silver (validated Iceberg tables), gold (star schema and metrics), all queried with Athena.
- **Quality gates:** each run builds new tables, checks them, and publishes only if the checks pass (write-audit-publish).
- **Orchestration:** Step Functions, started manually.
- **Infrastructure:** everything in Terraform, deployed to `us-west-2`.

Full reasoning, trade-offs and rejected alternatives: [solution design](docs/solution-design.md) · [summary](docs/solution-design-summary.md) · [data profile](docs/data-profile.md)

## Tech stack

AWS (S3, Glue, Athena, Step Functions, DynamoDB, Secrets Manager, CloudWatch, SNS) · Apache Iceberg · Terraform · Python · SQL · Streamlit

## Repository layout

| Path | Contents |
|---|---|
| `docs/` | Solution design, summary, architecture diagram and data profile |
| `terraform/` | Infrastructure as code  |
| `glue/drive_sync/` | Ingestion job: copies new or changed CSVs from Google Drive to S3 (Python 3.9, Glue Python shell) |
| `sql/` | Bronze profiling, silver validation views, gold star schema and metrics, data checks, publish views |
| `scripts/` | Local data checks: file inventory and encoding check |
| `dashboard/` | Streamlit dashboard on the published marts |
| `data/` | Local source files (not committed; see `data/README.md`) |

## Development setup

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
pre-commit install
```

Every commit is checked automatically, including secret scanning with gitleaks.

The ingestion job has its own environment, because AWS Glue Python shell runs **Python 3.9**. It's created with [uv](https://docs.astral.sh/uv/):

```bash
cd glue/drive_sync
uv venv --python 3.9
source .venv/bin/activate
uv pip install -r requirements-dev.txt
```

`requirements.txt` pins the Google client libraries. Terraform reads the same file when it deploys the job, so local runs and AWS use the same versions.

## Deployment

All infrastructure is defined in Terraform and deployed to `us-west-2`, in two stacks applied in order: `bootstrap` (the state bucket) and `envs/dev` (the project).

### Prerequisites

- Terraform 1.10 or newer (needed for S3 native state locking)
- AWS CLI v2, signed in to the target account: `aws sts get-caller-identity` should show it
- Permission in that account to create S3 buckets and the project's resources

### 1. Set your AWS account ID and alert email

Each stack refuses to run against any other account (`allowed_account_ids`). Copy the example files and set `account_id` to the number printed by the last command, and set `alert_email` to the address that should receive budget alerts. The real `terraform.tfvars` files are git-ignored.

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
aws sts get-caller-identity --query Account --output text
```

### 2. Bootstrap the state bucket (once)

Creates a versioned, encrypted, TLS-only S3 bucket for Terraform state, protected against deletion. This small stack keeps its own state file locally (git-ignored).

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
terraform -chdir=terraform/bootstrap output state_bucket_name
```

### 3. Deploy the dev environment

Set `bucket` in the `backend "s3"` block of `terraform/envs/dev/versions.tf` to the bucket name from step 2. It has to be typed in literally, because Terraform reads the backend during `init`, before any variables exist.

```bash
terraform -chdir=terraform/envs/dev init
terraform -chdir=terraform/envs/dev plan
terraform -chdir=terraform/envs/dev apply
```

The dev state is stored in the bucket at `envs/dev/terraform.tfstate` and locked during every run, so two applies can't overlap.

### 4. Give the pipeline read access to Google Drive

1. In Google Cloud, create a project, enable the **Google Drive API**, and create a service account with a JSON key.
2. Share the Drive folder that holds the source files with the service account's email, as **Viewer**.
3. Store the key in the secret Terraform created, then delete the local copy. The key never goes into Git or Terraform state.

```bash
aws secretsmanager put-secret-value --region us-west-2 \
  --secret-id "$(terraform -chdir=terraform/envs/dev output -raw google_secret_name)" \
  --secret-string file://path/to/key.json
rm path/to/key.json
```

### 5. Run the ingestion job locally

The job copies every new or changed CSV in the Drive folder to `raw/` in the lake bucket, registers it as a table in the `raw` Glue database, and records it in the DynamoDB manifest. Run it from the job's environment (see [Development setup](#development-setup)). The folder ID is the last part of the folder's Drive URL.

```bash
cd glue/drive_sync
python drive_sync.py \
  --folder_id <drive-folder-id> \
  --bucket "$(terraform -chdir=../../terraform/envs/dev output -raw lake_bucket_name)" \
  --manifest_table "$(terraform -chdir=../../terraform/envs/dev output -raw dynamodb_manifest_table_name)" \
  --secret_name "$(terraform -chdir=../../terraform/envs/dev output -raw google_secret_name)" \
  --raw_database hsl_dev_raw
```

Running it a second time copies nothing: only new or changed files are copied.

### 6. Run the ingestion job in AWS Glue

`terraform apply` (step 3) deploys the same script as the Glue Python shell job `hsl-dev-drive-sync`, with its settings passed as job arguments. Set `drive_folder_id` in `terraform/envs/dev/terraform.tfvars` before applying.

```bash
aws glue start-job-run --job-name hsl-dev-drive-sync --region us-west-2
aws glue get-job-runs --job-name hsl-dev-drive-sync --max-items 1 \
  --query 'JobRuns[0].[JobRunState,ExecutionTime,ErrorMessage]' --region us-west-2
aws logs tail /aws-glue/python-jobs/output --since 15m --region us-west-2
```

Errors and tracebacks are in the `/aws-glue/python-jobs/error` log group.

### 7. Run the whole pipeline

A Step Functions state machine runs everything in order: copy from Drive, build silver and gold, run the data checks, and publish only if every error-level check passes. Confirm the SNS subscription email first, so failure alerts reach you.

```bash
aws stepfunctions start-execution --region us-west-2 \
  --state-machine-arn "$(terraform -chdir=terraform/envs/dev output -raw pipeline_state_machine_arn)"
```

Follow the run in the Step Functions console. Check results are in `hsl_dev_audit.check_results`, and the dashboard reads the `hsl_dev_marts` views. A second run with no new files ends at `NothingToBuild`.

### 8. Open the dashboard

The Streamlit app reads the published `hsl_dev_marts` views through Athena's `dashboard` workgroup, using your AWS credentials, and caches the results for 24 hours.

```bash
source .venv/bin/activate
python -m pip install -r dashboard/requirements.txt
streamlit run dashboard/app.py
```

It covers staffing (nurse hours per resident day, RN hours, contract-staff share), the share of days below the CMS benchmark, trends by day and month, comparisons by state and ownership, staffing against occupancy and rehospitalisation, and facility rankings.

## Roadmap

- [x] Repository foundation: gitignore, pre-commit, secret scanning
- [x] Terraform foundation: remote state, provider, tagging
- [x] Lake storage, Glue Data Catalog, Athena workgroups
- [x] Ingestion job (Google Drive → S3), registering bronze tables with every column as text
- [x] Data profiling on bronze ([findings](docs/data-profile.md))
- [x] Silver layer: validation views, Iceberg silver tables, silver and quarantine views
- [x] Gold layer and data checks: star schema, monthly metrics, checks gating publish
- [x] Orchestration with Step Functions: write-audit-publish, failure alerts, full run in about 3 minutes
- [x] Dashboard: Streamlit on the published marts
