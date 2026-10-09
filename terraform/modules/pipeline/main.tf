data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  region          = data.aws_region.current.region
  lake_bucket_arn = "arn:aws:s3:::${var.lake_bucket_name}"

  # The SQL files are rendered here at deploy time. The run ID is only known when a run starts,
  # so it stays as a marker that the state machine replaces.
  sql_dir  = "${path.module}/../../../sql"
  sql_vars = { prefix = var.catalog_prefix, bucket = var.lake_bucket_name, run_id = "__RUN_ID__" }

  datasets = ["pbj_daily_staffing", "provider_info", "quality_claims"]
  marts    = ["dim_date", "dim_facility", "fact_daily_staffing", "agg_facility_month"]

  # Build and audit, in order: validation views, silver, gold, then the checks.
  build_sql = concat(
    [templatefile("${local.sql_dir}/checks/create_check_results.sql", local.sql_vars)],
    [for d in local.datasets : templatefile("${local.sql_dir}/staging/base_${d}.sql", local.sql_vars)],
    [for d in local.datasets : templatefile("${local.sql_dir}/silver/build_silver.sql", merge(local.sql_vars, { dataset = d }))],
    [for m in local.marts : templatefile("${local.sql_dir}/gold/${m}.sql", local.sql_vars)],
    [templatefile("${local.sql_dir}/checks/run_checks.sql", local.sql_vars)],
  )

  failed_checks_sql = templatefile("${local.sql_dir}/checks/count_failed_checks.sql", local.sql_vars)

  # Publish, in order: silver and quarantine first, the dashboard's marts last.
  publish_sql = concat(
    [for d in local.datasets : templatefile("${local.sql_dir}/publish/silver_view.sql", merge(local.sql_vars, { dataset = d }))],
    [for d in local.datasets : templatefile("${local.sql_dir}/publish/quarantine_view.sql", merge(local.sql_vars, { dataset = d }))],
    [for m in local.marts : templatefile("${local.sql_dir}/publish/mart_view.sql", merge(local.sql_vars, { mart = m }))],
  )
}
