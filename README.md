# Healthcare Staffing Lakehouse

An AWS lakehouse that turns CMS nursing-home staffing data (Payroll-Based Journal, Q2 2024, ~1.3M daily facility records) into staffing metrics and a dashboard: nurse hours per resident day, contract-staff share, and how often facilities fall below the CMS 2024 staffing benchmark.

![Dashboard overview](docs/images/dashboard-overview.png)

## Key findings

- **Weekends are the biggest staffing gap.** Nursing hours per resident day (HPRD) fall from 3.91 on weekdays to 3.26 on weekends, and RN hours per resident drop 40%. Every weekend of the quarter is below the 3.48 benchmark.
- **Ownership matters more than occupancy.** For-profit facilities staff 3.58 HPRD and spend 44% of days below the benchmark; non-profits staff 4.17 and spend 21%. Staffing per resident is nearly flat across occupancy levels (correlation −0.06).
- **The RN benchmark is the harder one.** 47% of facilities average below 0.55 RN HPRD, against 37% below 3.48 total, so the two are reported separately.
- **Staffing barely predicts rehospitalisation** (correlation −0.06 across 11,817 facilities): a modest signal at most, and correlation, not causation.
- **Biggest state gaps:** Illinois and Missouri (3.25 HPRD) and Texas (3.30) are lowest; Alaska (6.01) and Oregon (5.01) are highest.

The answers to the brief's four questions, including the two the data can't answer (overtime and length of stay) and the closest measure for each, are in **[Findings](docs/findings.md)**.

| By state | By ownership | Patient load and outcomes |
|---|---|---|
| ![Staffing by state](docs/images/staffing-by-state.png) | ![Staffing by ownership](docs/images/staffing-by-ownership.png) | ![Staffing by occupancy and rehospitalisation](docs/images/load-and-outcomes.png) |

## Architecture

![Solution architecture](docs/architecture.drawio.svg)

- **Ingestion:** a Glue Python shell job copies CSVs from Google Drive into S3 incrementally, tracked in a DynamoDB manifest.
- **Medallion layers:** bronze (raw CSV in S3), silver (validated Iceberg tables), gold (star schema and metrics), all queried with Athena.
- **Quality gates:** each run builds new tables, checks them, and publishes only if the checks pass (write-audit-publish).
- **Orchestration:** Step Functions, started manually.
- **Infrastructure:** everything in Terraform, deployed to `us-west-2`.

A full run (copy, build, check, publish) takes about 3 minutes and costs a few cents. A rerun with no new files ends after the copy step.

## Documentation

| Document | What's in it |
|---|---|
| [Solution design](docs/solution-design.md) · [summary](docs/solution-design-summary.md) | Architecture, why each service was chosen, rejected alternatives, data quality, failure handling, security, cost, risks |
| [Data profile](docs/data-profile.md) | What profiling the source data found, and the validation rule each finding became |
| [Data dictionary](docs/data-dictionary.md) | Every table and column, from bronze to gold, with metric definitions and reject reasons |
| [Findings](docs/findings.md) | Answers to the brief's questions, with conclusions and limits |

## What changed during the build

The design was approved before any code was written. These four changes came from evidence found while building, and each one is recorded in the design doc:

1. **The Glue crawler was removed.** It guessed column types from the start of each file and typed facility IDs as numbers, but 235 facilities have IDs like `39A433`, and every query on the main table failed. The ingestion job now registers each table itself, with every column as text, and silver converts the types.
2. **The pipeline went from 23 minutes to under 3.** Step Functions' `.sync` integration for Athena checks for completion only about once a minute, so 23 quick queries took 23 minutes. A 3-second polling loop replaced it.
3. **Files go through a temporary file instead of a pure stream.** A file's encoding is only known after reading all of it (PBJ is Windows-1252), so each file is downloaded to local disk, verified against Drive's MD5 and converted to UTF-8 in one pass.
4. **Validation rules come from profiling.** 2,522 days with residents but no recorded nursing hours, and 75 days with impossible staffing, are quarantined with a reason rather than averaged into the metrics.

## Tech stack

AWS (S3, Glue, Athena, Step Functions, DynamoDB, Secrets Manager, CloudWatch, SNS) · Apache Iceberg · Terraform · Python · SQL · Streamlit

## Repository layout

| Path | Contents |
|---|---|
| `docs/` | Solution design, data profile, data dictionary, findings, diagram and screenshots |
| `terraform/` | Infrastructure as code: one configuration for every environment (`live/`), shared modules, and the state-bucket bootstrap |
| `Makefile` | Deploy and run any environment: `make <target> ENV=dev\|prod` |
| `glue/drive_sync/` | Ingestion job: copies new or changed CSVs from Google Drive to S3 (Python 3.9, Glue Python shell) |
| `sql/` | Bronze profiling, silver validation views, gold star schema and metrics, data checks, publish views |
| `scripts/` | Local data checks: file inventory and encoding check |
| `dashboard/` | Streamlit dashboard on the published marts |
| `data/` | Local source files (not committed; see `data/README.md`) |

## Development setup

The root environment needs **Python 3.11 or newer** (the scripts and the dashboard use newer standard-library features).

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
pre-commit install
```

### Commit checks (pre-commit)

`pre-commit install` sets up a Git hook, so these checks run on every `git commit` (configured in `.pre-commit-config.yaml`):

| Check | What it does |
|---|---|
| **gitleaks** | Blocks the commit if it finds a secret (keys, tokens, passwords). This is a public repo, so nothing sensitive may be committed. |
| `detect-private-key` | Blocks private keys, such as a Google service-account JSON |
| `check-added-large-files` | Blocks files over 1 MB (the source CSVs stay in `data/`, which is git-ignored) |
| `terraform_fmt` | Formats `.tf` files (needs Terraform installed) |
| `check-yaml`, `check-json`, `check-merge-conflict` | Catch broken config files and leftover merge markers |
| `end-of-file-fixer`, `trailing-whitespace` | Tidy whitespace |

- **Run them by hand** on every file: `pre-commit run --all-files`
- **If a check fixes a file** (formatting or whitespace), the commit stops. Run `git add` on the changed files and commit again.
- **If gitleaks blocks a commit,** remove the secret. Don't bypass it with `--no-verify`. A pushed secret should be treated as leaked and rotated.
- **Update the pinned versions:** `pre-commit autoupdate`, then commit the updated config.
- **macOS `CERTIFICATE_VERIFY_FAILED`** on the first run (Python from python.org): run *Install Certificates.command* from the Python folder in Applications.

### Ingestion job environment

The ingestion job has its own environment, because AWS Glue Python shell runs **Python 3.9**. It's created with [uv](https://docs.astral.sh/uv/):

```bash
cd glue/drive_sync
uv venv --python 3.9
source .venv/bin/activate
uv pip install -r requirements-dev.txt
```

`requirements.txt` pins the Google client libraries. Terraform reads the same file when it deploys the job, so local runs and AWS use the same versions.

## Deployment

All infrastructure is Terraform, deployed to `us-west-2`. **One configuration, `terraform/live`, serves every environment.** You choose the environment with `ENV`, and a Makefile runs the right Terraform commands (`make help` lists them all):

```bash
make plan ENV=dev      # what would change in dev
make apply ENV=dev     # apply exactly that plan
make plan ENV=prod     # the same code with prod's settings (ENV=PROD works too)
```

Each environment has its own Terraform state and its own settings, in `terraform/live/config/`:

| File | What it holds |
|---|---|
| `<env>.backend.hcl` | Where that environment's state is stored (committed) |
| `<env>.tfvars` | Its AWS account ID, alert email and Drive folder (git-ignored; copy it from the `.example` file) |

Resources are named by environment (`hsl-dev-*`, `hsl-prod-*`), so dev and prod can share one AWS account or live in separate ones.

### Prerequisites

- Terraform 1.10 or newer (needed for S3 native state locking) and GNU Make (already installed on macOS and Linux)
- AWS CLI v2, signed in to the target account: `aws sts get-caller-identity` should show it
- Permission in that account to create S3 buckets and the project's resources
- With separate accounts per environment: a CLI profile for each, passed as `PROFILE=`, for example `make plan ENV=prod PROFILE=hsl-prod`

### 1. Fill in your settings

Copy the example files. Set `account_id` to the number printed by the last command, `alert_email` to the address that should receive budget and failure alerts, and `drive_folder_id` to the ID of the Google Drive folder with the source files (the last part of its URL). Terraform refuses to run if your credentials belong to a different account than `account_id` (`allowed_account_ids`).

```bash
cp terraform/bootstrap/config/dev.tfvars.example terraform/bootstrap/config/dev.tfvars
cp terraform/live/config/dev.tfvars.example terraform/live/config/dev.tfvars
aws sts get-caller-identity --query Account --output text
```

### 2. Bootstrap the state bucket (once per AWS account)

Creates a versioned, encrypted, TLS-only S3 bucket for Terraform state, protected against deletion. This small stack keeps its own state locally, in `terraform/bootstrap/state/` (git-ignored).

```bash
make bootstrap ENV=dev
```

Put the bucket name it prints into `terraform/live/config/dev.backend.hcl`.

### 3. Deploy dev

Dev deploys from the `dev` branch and prod from `main` (create the `dev` branch once with `git checkout -b dev`).

```bash
git checkout dev
make plan ENV=dev
make apply ENV=dev
```

`make apply` applies only the plan you just reviewed. It refuses to run from the wrong branch or with uncommitted changes, so what's deployed is always what's in Git. The state is locked during every run, so two applies can't overlap.

### 4. Give the pipeline read access to Google Drive

1. In Google Cloud, create a project, enable the **Google Drive API**, and create a service account with a JSON key.
2. Share the Drive folder that holds the source files with the service account's email, as **Viewer**.
3. Store the key in the secret Terraform created, then delete the local copy. The key never goes into Git or Terraform state.

```bash
aws secretsmanager put-secret-value --region us-west-2 \
  --secret-id "$(make -s out ENV=dev NAME=google_secret_name)" \
  --secret-string file://path/to/key.json
rm path/to/key.json
```

### 5. Run the ingestion job locally

The job copies every new or changed CSV in the Drive folder to `raw/` in the lake bucket, registers it as a table in the `raw` Glue database, and records it in the DynamoDB manifest. Run it from the job's environment (see [Ingestion job environment](#ingestion-job-environment)).

```bash
cd glue/drive_sync
python drive_sync.py \
  --folder_id <drive-folder-id> \
  --bucket "$(make -s -C ../.. out ENV=dev NAME=lake_bucket_name)" \
  --manifest_table "$(make -s -C ../.. out ENV=dev NAME=dynamodb_manifest_table_name)" \
  --secret_name "$(make -s -C ../.. out ENV=dev NAME=google_secret_name)" \
  --raw_database hsl_dev_raw
```

Running it a second time copies nothing: only new or changed files are copied.

### 6. Run the ingestion job in AWS Glue

`make apply` deploys the same script as the Glue Python shell job `hsl-dev-drive-sync`, with its settings passed as job arguments.

```bash
make job ENV=dev
aws glue get-job-runs --job-name hsl-dev-drive-sync --max-items 1 \
  --query 'JobRuns[0].[JobRunState,ExecutionTime,ErrorMessage]' --region us-west-2
aws logs tail /aws-glue/python-jobs/output --since 15m --region us-west-2
```

Errors and tracebacks are in the `/aws-glue/python-jobs/error` log group.

### 7. Run the whole pipeline

A Step Functions state machine runs everything in order: copy from Drive, build silver and gold, run the data checks, and publish only if every error-level check passes. Confirm the SNS subscription email first, so failure alerts reach you.

```bash
make run ENV=dev
```

Follow the run in the Step Functions console. Check results are in `hsl_dev_audit.check_results`, and the dashboard reads the `hsl_dev_marts` views. A second run with no new files ends at `NothingToBuild`.

### 8. Open the dashboard

The Streamlit app reads the published marts of the chosen environment through its Athena `dashboard` workgroup, using your AWS credentials, and caches the results for 24 hours.

```bash
source .venv/bin/activate
python -m pip install -r dashboard/requirements.txt
make dashboard ENV=dev
```

It covers staffing (nurse hours per resident day, RN hours, contract-staff share), the share of days below the CMS benchmark, trends by day and month, comparisons by state and ownership, staffing against occupancy and rehospitalisation, and facility rankings.

### Releasing to prod

Features are merged into `dev` and tested in the dev environment. When everyone's work for a release is in and tested, a reviewed pull request from `dev` into `main` is the release, and the same code goes to prod:

```bash
# test in dev
git checkout dev && git pull
make plan ENV=dev && make apply ENV=dev
make run ENV=dev               # data checks pass, dashboard looks right

# after the dev -> main pull request is merged
git checkout main && git pull
make plan ENV=prod             # should show the same changes dev got
make apply ENV=prod
make run ENV=prod
```

- **Code is promoted, data isn't.** Prod's pipeline builds its own data from the source, in its own bucket.
- **Hotfixes:** branch from `main`, merge into `main` and deploy prod, then merge `main` back into `dev` so the two don't drift apart.
- **Rollback:** apply the previous commit of `main`. The dashboard keeps showing the last good build until a run's checks pass.

### Adding prod

**In the same AWS account as dev:**

1. Copy `terraform/live/config/prod.backend.hcl.example` to `prod.backend.hcl` (same state bucket as dev, its own key), and `prod.tfvars.example` to `prod.tfvars` (the same account ID).
2. On `main`, run `make plan ENV=prod`, then `make apply ENV=prod`.
3. Copy the Google key from the dev secret, without saving it to disk:
   ```bash
   aws secretsmanager put-secret-value --region us-west-2 \
     --secret-id hsl-prod/google-drive-service-account \
     --secret-string "$(aws secretsmanager get-secret-value --region us-west-2 \
       --secret-id hsl-dev/google-drive-service-account --query SecretString --output text)"
   ```
4. Confirm the alert email, then `make run ENV=prod`. Both environments' budgets watch the whole account, so expect each alert twice.

**In its own AWS account (the usual setup for production):**

1. Create the account (AWS Organizations) and a CLI profile for it, for example `hsl-prod`.
2. Add `terraform/bootstrap/config/prod.tfvars` with the new account ID, and run `make bootstrap ENV=prod PROFILE=hsl-prod`.
3. Put that bucket in `prod.backend.hcl` and the new account ID in `prod.tfvars`. Then run steps 2–4 above with `PROFILE=hsl-prod`, using a prod service account for the Google key.

### Tearing down

The data stores are protected on purpose, so `terraform destroy` stops on them until you remove the protection:

- **Lake bucket and state bucket:** `prevent_destroy` in Terraform. Remove that `lifecycle` block first. Both buckets are versioned, so they must also be emptied, old versions included, before they can be deleted.
- **Manifest table:** DynamoDB deletion protection. Set `deletion_protection_enabled = false` and apply before destroying.

There's deliberately no `make destroy`. Destroy each environment first, then the bootstrap stack of its account, because the environments' state is stored in the bootstrap bucket:

```bash
TF_DATA_DIR=.terraform/dev terraform -chdir=terraform/live destroy -var env=dev -var-file=config/dev.tfvars
```

The tables created by the job and the pipeline are deleted along with their Glue databases.

## Roadmap

- [x] Repository foundation: gitignore, pre-commit, secret scanning
- [x] Terraform foundation: remote state, provider, tagging
- [x] Lake storage, Glue Data Catalog, Athena workgroups
- [x] Ingestion job (Google Drive → S3), registering bronze tables with every column as text
- [x] Data profiling on bronze ([profile](docs/data-profile.md))
- [x] Silver layer: validation views, Iceberg silver tables, silver and quarantine views
- [x] Gold layer and data checks: star schema, monthly metrics, checks gating publish
- [x] Orchestration with Step Functions: write-audit-publish, failure alerts, full run in about 3 minutes
- [x] Dashboard: Streamlit on the published marts
- [x] Findings and data dictionary
