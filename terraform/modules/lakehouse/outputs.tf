output "lake_bucket_name" {
  description = "Name of the data lake S3 bucket."
  value       = aws_s3_bucket.lake.bucket
}

output "catalog_database_names" {
  description = "Glue database name for each medallion layer, keyed by layer."
  value       = { for layer, db in aws_glue_catalog_database.this : layer => db.name }
}

output "athena_workgroup_names" {
  description = "Athena workgroup name for each consumer, keyed by consumer."
  value       = { for key, wg in aws_athena_workgroup.this : key => wg.name }
}
