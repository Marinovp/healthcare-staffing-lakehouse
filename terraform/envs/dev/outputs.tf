output "name_prefix" {
  description = "AWS resources name prefix"
  value       = local.name_prefix
}

output "catalog_prefix" {
  description = "Glue Catalog prefix and Athena database name prefix"
  value       = local.catalog_prefix
}

output "lake_bucket_name" {
  description = "Data lake S3 bucket."
  value       = module.lakehouse.lake_bucket_name
}

output "catalog_database_names" {
  description = "Glue database per medallion layer."
  value       = module.lakehouse.catalog_database_names
}

output "athena_workgroup_names" {
  description = "Athena workgroup per consumer."
  value       = module.lakehouse.athena_workgroup_names
}

output "google_secret_name" {
  description = "The name of the Google Drive service account secret"
  value       = module.ingestion.google_secret_name
}

output "dynamodb_manifest_table_name" {
  description = "The name of the DynamoDB table used for the ingestion manifest"
  value       = module.ingestion.dynamodb_manifest_table_name
}

output "drive_sync_job_name" {
  description = "Name of the Glue job that copies Drive files to raw"
  value       = module.ingestion.drive_sync_job_name
}

output "pipeline_state_machine_arn" {
  description = "ARN of the pipeline state machine, used to start a run"
  value       = module.pipeline.state_machine_arn
}
