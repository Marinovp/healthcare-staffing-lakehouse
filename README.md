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

Full reasoning, trade-offs and rejected alternatives: [solution design](docs/solution-design.md) · [summary](docs/solution-design-summary.md)

## Tech stack

AWS (S3, Glue, Athena, Step Functions, DynamoDB, Secrets Manager, CloudWatch, SNS) · Apache Iceberg · Terraform · Python · SQL · Streamlit

## Repository layout

| Path | Contents |
|---|---|
| `docs/` | Solution design, summary and architecture diagram |
| `terraform/` | Infrastructure as code *(planned)* |
| `glue/` | Ingestion job *(planned)* |
| `sql/` | Silver and gold transformations and data checks *(planned)* |
| `datasets/` | Dataset contract (`datasets.json`) *(planned)* |
| `dashboard/` | Streamlit app *(planned)* |
| `data/` | Local source files (not committed; see `data/README.md`) |

## Development setup

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
pre-commit install
```

Every commit is checked automatically, including secret scanning with gitleaks.

## Roadmap

- [x] Repository foundation: gitignore, pre-commit, secret scanning
- [ ] Terraform foundation: remote state, provider, tagging
- [ ] Lake storage, Glue Data Catalog, Athena workgroups
- [ ] Dataset contract and bronze tables
- [ ] Ingestion job (Google Drive → S3)
- [ ] Data profiling on bronze
- [ ] Silver layer
- [ ] Gold layer and data checks
- [ ] Orchestration with Step Functions
- [ ] Dashboard
