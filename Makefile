# Deploy and run the project for one environment:  make <target> ENV=dev|prod  (PROD works too)
# dev deploys from the dev branch and prod from main. Plans can run from any branch.
# Run "make help" to see the targets.

ENV ?= dev
override ENV := $(shell echo '$(ENV)' | tr '[:upper:]' '[:lower:]')
ifeq ($(filter $(ENV),dev prod),)
$(error ENV must be dev or prod, got "$(ENV)")
endif

# The branch each environment deploys from
DEPLOY_BRANCH_dev  := dev
DEPLOY_BRANCH_prod := main
DEPLOY_BRANCH      := $(DEPLOY_BRANCH_$(ENV))

# CLI profile for this environment's AWS account. Empty = your current credentials (one account
# for now). Once dev and prod are separate accounts, pass it in, e.g. PROFILE=hsl-prod
PROFILE ?=
ifneq ($(PROFILE),)
export AWS_PROFILE := $(PROFILE)
endif

export AWS_REGION := us-west-2
# Each environment keeps its own Terraform working data, so dev can never be planned against prod's state
export TF_DATA_DIR := .terraform/$(ENV)

LIVE      := terraform/live
BOOTSTRAP := terraform/bootstrap
TF        := terraform -chdir=$(LIVE)
tf_output  = $$($(TF) output -raw $(1))

.PHONY: help bootstrap init plan apply output out job run dashboard check-config check-branch

help: ## List the targets
	@echo "Usage: make <target> ENV=dev|prod"
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

bootstrap: ## Create the Terraform state bucket in this environment's account (once per account)
	@mkdir -p $(BOOTSTRAP)/state
	terraform -chdir=$(BOOTSTRAP) init -input=false -backend-config=path=state/$(ENV).tfstate
	terraform -chdir=$(BOOTSTRAP) apply -var-file=config/$(ENV).tfvars
	terraform -chdir=$(BOOTSTRAP) output state_bucket_name

init: check-config ## Connect to this environment's Terraform state
	$(TF) init -input=false -backend-config=config/$(ENV).backend.hcl

plan: init ## Show what would change (saved to <env>.tfplan for apply)
	$(TF) plan -input=false -var env=$(ENV) -var-file=config/$(ENV).tfvars -out=$(ENV).tfplan

apply: check-branch ## Apply the saved plan (dev from the dev branch, prod from main)
	$(TF) apply -input=false $(ENV).tfplan

output: init ## Show this environment's outputs
	@$(TF) output

out: check-config ## Print one output, for scripts: make -s out NAME=lake_bucket_name
	@$(TF) init -input=false -backend-config=config/$(ENV).backend.hcl > /dev/null
	@$(TF) output -raw $(NAME)

job: init ## Start the Glue ingestion job
	aws glue start-job-run --job-name "$(call tf_output,drive_sync_job_name)"

run: init ## Start a full pipeline run (Step Functions)
	aws stepfunctions start-execution --state-machine-arn "$(call tf_output,pipeline_state_machine_arn)"

dashboard: ## Open the dashboard on this environment's data
	ATHENA_WORKGROUP=hsl-$(ENV)-dashboard MARTS_DATABASE=hsl_$(ENV)_marts .venv/bin/streamlit run dashboard/app.py

check-config:
	@for f in $(LIVE)/config/$(ENV).backend.hcl $(LIVE)/config/$(ENV).tfvars; do \
	  [ -f $$f ] || { echo "Missing $$f: copy it from its .example file (see the README's Deployment section)."; exit 1; }; \
	done

check-branch:
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$branch" != "$(DEPLOY_BRANCH)" ]; then \
	  echo "$(ENV) deploys from the $(DEPLOY_BRANCH) branch, and you're on $$branch."; exit 1; \
	fi; \
	if [ -n "$$(git status --porcelain)" ]; then \
	  echo "You have uncommitted changes. Commit them first, so what you deploy is what's in Git."; exit 1; \
	fi
